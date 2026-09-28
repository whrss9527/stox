import AppKit
import Combine
import SwiftUI
import StoxCore

/// 菜单栏图标 + 玻璃面板。
///
/// - 左键单击：打开 / 关闭行情面板（再点一次、点到别处、按 Esc 都会关闭）
/// - 右键或 Control+单击：在“菜单栏显示行情”和“只显示图标”之间切换
@MainActor
final class StatusItemController: NSObject {
    private let store: QuoteStore
    private let settings: SettingsStore
    private let updater: Updater
    private let sync: SyncManager
    private let router = PanelRouter()
    private let statusItem: NSStatusItem
    private var panel: PanelWindow?
    private var hostingView: NSHostingView<AnyView>?
    /// SwiftUI 最近一次量出的面板内容尺寸。
    private var contentSize = CGSize.zero
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// 面板因为点到别处而关闭的时间：点菜单栏图标关闭面板时，不要紧接着又把它打开。
    private var lastAutoClose = Date.distantPast
    private var rotationTimer: Timer?
    private var rotationIndex = 0
    private var cancellables = Set<AnyCancellable>()

    init(store: QuoteStore, settings: SettingsStore, updater: Updater, sync: SyncManager) {
        self.store = store
        self.settings = settings
        self.updater = updater
        self.sync = sync
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.autosaveName = "StoxStatusItem"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            // 和系统菜单一样在按下鼠标时响应。
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
            button.toolTip = "Stox 行情\n左键：打开 / 关闭行情面板\n右键：隐藏 / 显示菜单栏行情"
        }

        Publishers.Merge(store.objectWillChange, settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateRotationTimer()
                self?.updateButton()
                self?.panel?.appearance = self?.settings.appearance.nsAppearance
            }
            .store(in: &cancellables)

        settings.$panelPinned
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] pinned in self?.pinnedChanged(pinned) }
            .store(in: &cancellables)

        updateRotationTimer()
        updateButton()
    }

    // MARK: - 点击

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            settings.hideTicker.toggle()
            Log.info(settings.hideTicker ? "菜单栏改为只显示图标" : "菜单栏恢复显示行情")
        } else {
            togglePanel()
        }
    }

    // MARK: - 面板

    func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(lastAutoClose) > 0.3 {
            openPanel()
        }
    }

    /// 打开面板。后几个参数用于调试和 CI 截图：展开某一行、预填搜索词、模拟按键、打印诊断信息。
    func openPanel(
        route: PanelRoute = .list, expand: Symbol? = nil, search: String? = nil, keys: [PanelKey] = [],
        printDiagnostics: Bool = false
    ) {
        if panel == nil {
            makePanel()
        }
        guard let panel else { return }
        router.route = route
        router.listMaxHeight = WatchlistView.defaultMaxHeight
        if let expand { router.expanded = expand }
        if let search { router.searchText = search }
        store.panelWillOpen()
        sync.panelWillOpen()
        resizePanel()
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(true)
        if printDiagnostics || !keys.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // 预填了搜索词时，等搜索结果回来再按键。
                for _ in 0..<50 where search != nil {
                    guard let router = self?.router, router.searchResults.isEmpty || router.isSearching else { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if !keys.isEmpty {
                    await self?.simulate(keys)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                if printDiagnostics {
                    self?.printDiagnostics()
                    // 盘前盘后价在行情之后才取，过几秒再报一次。
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if let self {
                        print("STOX_DIAG late \(self.extendedHoursDiagnostics)")
                        fflush(stdout)
                    }
                }
            }
        }
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        router.panelDidClose()
    }

    func openSettings(_ page: SettingsPage?) {
        closePanel()
        SettingsWindowController.shared.show(page: page)
    }

    private func makePanel() {
        let actions = PanelActions(
            openSettings: { [weak self] page in self?.openSettings(page) },
            quit: { NSApp.terminate(nil) },
            sizeChanged: { [weak self] size in self?.resizePanel(to: size) }
        )
        let root = PanelView(actions: actions)
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(router)
            .environmentObject(updater)
            .environmentObject(sync)
        let hosting = NSHostingView(rootView: AnyView(root))
        hostingView = hosting
        let panel = PanelWindow(contentView: hosting)
        panel.appearance = settings.appearance.nsAppearance
        panel.pinned = settings.panelPinned
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keepBelowMenuBar() }
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelMoved() }
        }
        panel.onResignKey = { [weak self] in self?.panelLostFocus() }
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.onEscape = { [weak self] in self?.router.handleEscape() ?? false }
        panel.onNavigate = { [weak self] key in self?.handleNavigation(key) ?? false }
        self.panel = panel
    }

    /// 键盘操作：搜索时上下选择搜索结果、回车添加；没在搜索时上下选择自选、回车展开或收起，
    /// 展开着的时候左右切换分时、五日和日 K、周 K、月 K。返回 false 的键照常交给搜索框。
    private func handleNavigation(_ key: PanelKey) -> Bool {
        guard router.route == .list else { return false }
        if !router.trimmedQuery.isEmpty {
            guard router.batch == nil else { return false }
            // 已经添加过的跳过，选中的总是回车能添加的。
            let symbols = router.searchResults.map(\.symbol).filter { !store.contains($0) }
            switch key {
            case .up, .down:
                guard !symbols.isEmpty else { return false }
                let start = router.defaultSearchHighlight(excluding: { store.contains($0) })
                router.moveHighlight(by: key == .down ? 1 : -1, in: symbols, from: start)
                return true
            case .enter:
                // 还没用方向键选过：交给搜索框，照旧添加第一条。
                guard let symbol = router.highlighted, !store.contains(symbol),
                      let result = router.searchResults.first(where: { $0.symbol == symbol })
                else { return false }
                store.add(symbol, name: result.isDirect ? "" : result.name)
                router.clearSearch()
                return true
            case .left, .right:
                return false
            }
        }
        let symbols = WatchlistView.visibleItems(store: store, settings: settings).map(\.symbol)
        switch key {
        case .up, .down:
            guard !symbols.isEmpty else { return false }
            router.moveHighlight(by: key == .down ? 1 : -1, in: symbols, from: router.expanded)
            return true
        case .enter:
            guard let symbol = router.highlighted, symbols.contains(symbol) else { return false }
            withAnimation(.easeInOut(duration: 0.15)) {
                router.toggleExpanded(symbol)
            }
            return true
        case .left, .right:
            guard router.expanded != nil else { return false }
            settings.chartPeriod = settings.chartPeriod.moved(by: key == .right ? 1 : -1)
            return true
        }
    }

    /// CI 用：把一串按键依次发给面板，和真的按键走同一条路。
    private func simulate(_ keys: [PanelKey]) async {
        for key in keys {
            guard let panel, let event = key.event(for: panel) else { continue }
            panel.sendEvent(event)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func panelLostFocus() {
        guard let panel, panel.isVisible, !settings.panelPinned else { return }
        lastAutoClose = Date()
        closePanel()
    }

    /// 钉住或取消钉住。取消时面板回到菜单栏图标下面。
    private func pinnedChanged(_ pinned: Bool) {
        guard let panel else { return }
        panel.pinned = pinned
        if pinned {
            settings.pinnedTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        } else if panel.isVisible {
            position(panel)
            panel.makeKey()
        }
        Log.info(pinned ? "面板已钉住" : "面板取消钉住")
    }

    /// 钉住时拖动了面板：记下位置。
    private func panelMoved() {
        guard let panel, panel.isVisible, settings.panelPinned else { return }
        settings.pinnedTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    /// 按最近一次量到的内容尺寸调整；还没量过时用 fittingSize 估一下。
    private func resizePanel() {
        if contentSize.width > 0, contentSize.height > 0 {
            resizePanel(to: contentSize)
        } else if let hostingView {
            resizePanel(to: hostingView.fittingSize)
        }
    }

    /// 顶边不动，按内容尺寸调整窗口。屏幕放不下时先把列表压矮，面板永远不盖住菜单栏。
    private func resizePanel(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // 先记下来：第一次量到尺寸时面板窗口可能还没建好，打开面板时要用到。
        contentSize = size
        guard let panel else { return }
        var height = ceil(size.height)
        if let available = availableHeight(), height > available {
            // 超出多少，列表就矮多少，一步算到位。列表是面板里唯一能伸缩的部分。
            let minimum = QuoteRow.rowHeight * 2
            let current = min(
                WatchlistView.naturalHeight(store: store, settings: settings, expanded: router.expanded), router.listMaxHeight
            )
            let limit = max(minimum, floor(current - (height - available)))
            if limit < router.listMaxHeight {
                // 在 SwiftUI 量尺寸的回调里，放到下一轮再改，避免在视图更新期间发布变化；
                // 改完再等一轮让 SwiftUI 重新布局，然后主动量一次，不指望它再回调。
                DispatchQueue.main.async { [weak self] in
                    self?.router.listMaxHeight = limit
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let hostingView = self.hostingView else { return }
                        hostingView.layoutSubtreeIfNeeded()
                        self.resizePanel(to: hostingView.fittingSize)
                    }
                }
            }
            height = floor(available)
        }
        let rounded = NSSize(width: ceil(size.width), height: height)
        guard rounded != panel.frame.size else { return }
        let origin = NSPoint(x: panel.frame.origin.x, y: panel.frame.maxY - rounded.height)
        panel.setFrame(NSRect(origin: origin, size: rounded), display: true)
        keepBelowMenuBar()
    }

    /// SwiftUI 的最小尺寸可能让窗口比我们设的高，这时它会往上长。把顶边挪回菜单栏下面。
    private func keepBelowMenuBar() {
        guard let panel, let limit = topLimit(), panel.frame.maxY > limit + 0.5 else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: limit - panel.frame.height))
    }

    /// 面板顶边最高能到哪：没钉住时是菜单栏图标下面 2 个点；钉住时是所在屏幕可见区域的顶边。
    private func topLimit() -> CGFloat? {
        if settings.panelPinned, let screen = panel?.screen ?? NSScreen.main {
            return screen.visibleFrame.maxY
        }
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)).minY - 2
    }

    /// 面板最多能有多高：从顶边（菜单栏图标下面，钉住时是面板现在的顶边）到屏幕可见区域的底部。
    private func availableHeight() -> CGFloat? {
        if settings.panelPinned, let panel, let screen = panel.screen ?? NSScreen.main {
            return min(panel.frame.maxY, screen.visibleFrame.maxY) - (screen.visibleFrame.minY + 6)
        }
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main
        else { return nil }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonRect.minY - 2 - (screen.visibleFrame.minY + 6)
    }

    /// 放在菜单栏图标正下方，不超出屏幕。
    private func position(_ panel: PanelWindow) {
        if settings.panelPinned, let topLeft = settings.pinnedTopLeft {
            // 钉住时放回上次拖到的位置；那块屏幕不在了就放到主屏幕里。
            let size = panel.frame.size
            let screen = NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(topLeft) } ?? NSScreen.main
            var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
            if let visible = screen?.visibleFrame {
                origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
                origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
            }
            panel.setFrameOrigin(origin)
            return
        }
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(x: buttonRect.midX - size.width / 2, y: buttonRect.minY - size.height - 2)
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
            origin.y = max(origin.y, visible.minY + 6)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - 菜单栏文字

    /// 菜单栏上显示的行情涉及的市场：固定到菜单栏的证券，以及显示今日盈亏时有持仓的市场。
    private var tickerRegions: Set<MarketRegion> {
        var regions = Set(store.items.filter(\.pinned).map { $0.symbol.market.region })
        if settings.showDayProfit {
            regions.formUnion(store.items.filter { $0.holding != nil }.map { $0.symbol.market.region })
        }
        return regions
    }

    /// 这些市场里有没有正在交易（含盘前盘后）的。
    private var tickerMarketsLive: Bool {
        tickerRegions.contains { store.phase(for: $0).isLive }
    }

    /// 只显示图标：手动隐藏了，或者选了“休市时只显示图标”并且菜单栏上的市场都休市了。
    private var tickerHidden: Bool {
        if settings.hideTicker { return true }
        guard settings.hideTickerWhenClosed, !tickerRegions.isEmpty else { return false }
        return !tickerMarketsLive
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let hidden = tickerHidden
        let entries = hidden
            ? []
            : MenuBarTicker.entries(items: store.items, quotes: store.quotes, options: settings.tickerOptions)
        // 今日盈亏总是跟在最后，轮流显示时也不参与轮换。
        let profit = hidden || !settings.showDayProfit
            ? []
            : MenuBarTicker.dayProfitParts(Portfolio.summaries(items: store.items, quotes: store.quotes), rates: store.rates)

        guard !entries.isEmpty || !profit.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = Self.icon
            return
        }

        var shown: [[TickerPart]]
        if settings.rotateTicker, entries.count > 1 {
            shown = [entries[rotationIndex % entries.count]]
        } else {
            shown = entries
        }
        if !profit.isEmpty {
            shown.append(profit)
        }
        button.image = nil
        button.attributedTitle = attributedTitle(for: shown)
    }

    private func attributedTitle(for entries: [[TickerPart]]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        let title = NSMutableAttributedString()
        for (index, parts) in entries.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
            for (partIndex, part) in parts.enumerated() {
                if partIndex > 0 {
                    title.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                let color: NSColor = part.role == .name
                    ? .labelColor
                    : Theme.tickerColor(for: part.direction, convention: settings.colorConvention)
                title.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: color]))
            }
        }
        return title
    }

    private func updateRotationTimer() {
        let shouldRotate = settings.rotateTicker && !tickerHidden && store.items.filter(\.pinned).count > 1
        if shouldRotate, rotationTimer == nil {
            rotationTimer = Timer.scheduledTimer(
                timeInterval: 5, target: self, selector: #selector(rotateTicker), userInfo: nil, repeats: true
            )
        } else if !shouldRotate, let timer = rotationTimer {
            timer.invalidate()
            rotationTimer = nil
        }
    }

    @objc private func rotateTicker() {
        rotationIndex += 1
        updateButton()
    }

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "Stox")
        image?.isTemplate = true
        return image
    }()

    // MARK: - 诊断

    /// CI 用：打印菜单栏文字和面板位置，方便检查和截图裁剪。
    func printDiagnostics() {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        func topLeft(_ rect: NSRect) -> String {
            "\(Int(rect.minX)) \(Int(screenHeight - rect.maxY)) \(Int(rect.width)) \(Int(rect.height))"
        }
        let title = statusItem.button?.attributedTitle.string ?? ""
        print("STOX_DIAG status_title=\"\(title)\" image=\(statusItem.button?.image != nil) color=\(settings.colorConvention.rawValue) pinned=\(settings.panelPinned)")
        print("STOX_DIAG ticker_hidden=\(tickerHidden) ticker_live=\(tickerMarketsLive) when_closed=\(settings.hideTickerWhenClosed)")
        let statusFrame = statusItem.button?.window?.frame
        if let statusFrame {
            print("STOX_DIAG status_frame=\(topLeft(statusFrame))")
        }
        let panelFrame = panel?.isVisible == true ? panel?.frame : nil
        if let panelFrame {
            let fitting = hostingView?.fittingSize ?? .zero
            print("STOX_DIAG panel_frame=\(topLeft(panelFrame)) content=\(Int(contentSize.width))x\(Int(contentSize.height)) fitting=\(Int(fitting.height)) list_max=\(Int(router.listMaxHeight)) available=\(Int(availableHeight() ?? -1))")
        }
        let frames = [statusFrame, panelFrame].compactMap { $0 }
        if let first = frames.first {
            print("STOX_DIAG capture_frame=\(topLeft(frames.dropFirst().reduce(first) { $0.union($1) }))")
        }
        let holdings = store.items.filter { $0.holding != nil }.count
        let intraday = store.intraday.values.map(\.points.count).max() ?? 0
        let kline = store.klines.values.map(\.candles.count).max() ?? 0
        let fiveDay = store.fiveDay.values.map(\.pointCount).max() ?? 0
        print("STOX_DIAG items=\(store.items.count) quotes=\(store.quotes.count) holdings=\(holdings) intraday=\(intraday) kline=\(kline) fiveday=\(fiveDay) error=\(store.lastError ?? "none")")
        let rates = store.rates.map { "USDCNY:\($0.usdCNY),HKDCNY:\($0.hkdCNY)" } ?? "none"
        print("STOX_DIAG rates=\(rates) pill=\(settings.changeDisplay.rawValue) source=\(store.usingBackup ? "backup" : "primary") alerts=\(store.firedAlertCount) summaries=\(store.closeSummaryCount)")
        print("STOX_DIAG \(extendedHoursDiagnostics)")
        let filter = WatchlistFilter.effective(settings.listFilter, items: store.items)
        print("STOX_DIAG filter=\(filter.rawValue) visible=\(WatchlistView.visibleItems(store: store, settings: settings).count)")
        // 展开的那只在 K 线图上有几根有 MA20。
        let ma20 = router.expanded
            .flatMap { symbol in settings.chartPeriod.klinePeriod.flatMap { store.klines[KlineKey(symbol: symbol, period: $0)] } }
            .map { KlineChartData(series: $0).averages.last?.compactMap { $0 }.count ?? 0 } ?? 0
        print("STOX_DIAG chart=\(settings.chartPeriod.rawValue) ma20=\(ma20) highlight=\(router.highlighted?.rawValue ?? "none") expanded=\(router.expanded?.rawValue ?? "none") search=\"\(router.searchText)\"")
        fflush(stdout)
    }

    /// 美股现在的时段和取到的盘前盘后价，CI 用来检查。
    var extendedHoursDiagnostics: String {
        let sample = store.extendedHours
            .min { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value.session):\($0.value.price)" } ?? "none"
        return "us_phase=\(store.phase(for: .us)) extended=\(store.extendedHours.count) extended_sample=\(sample)"
    }
}

enum PanelRoute: Equatable {
    case list
    case edit(Symbol)
}

/// 面板内的页面切换与搜索状态。放在一个对象里，方便 Esc 键统一处理。
@MainActor
final class PanelRouter: ObservableObject {
    @Published var route: PanelRoute = .list
    @Published var searchText = ""
    /// 自选列表的最大高度。屏幕矮、放不下整个面板时由 StatusItemController 调低，每次打开面板时恢复。
    @Published var listMaxHeight = WatchlistView.defaultMaxHeight
    @Published var expanded: Symbol?
    /// 键盘上下方向键选中的那一只：搜索时是搜索结果里的，否则是自选列表里的。
    @Published var highlighted: Symbol?
    @Published private(set) var searchResults: [SearchResult] = []
    /// searchResults 对应的查询词；输入后防抖期间两者不一致。
    private var resultsQuery = ""
    /// 搜索结果的行情，只用来显示，不存进自选。
    @Published private(set) var searchQuotes: [Symbol: Quote] = [:]
    /// searchQuotes 对应的查询词。
    private var searchQuotesQuery = ""
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    /// 批量添加时查过行情、确认不存在的代码。
    @Published private(set) var batchMissing: Set<Symbol> = []
    @Published private(set) var isAddingBatch = false
    @Published private(set) var batchError: String?

    var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 粘贴了多个代码时的批量添加内容；普通搜索时为 nil。
    var batch: (symbols: [Symbol], rejected: [String])? {
        SymbolInput.parseList(trimmedQuery)
    }

    /// 返回 true 表示 Esc 已被面板内部消化，不需要关闭面板。
    func handleEscape() -> Bool {
        if route != .list {
            route = .list
            return true
        }
        if !searchText.isEmpty {
            clearSearch()
            return true
        }
        return false
    }

    /// 每次关闭都回到干净的列表页，下次一键打开看到的就是行情。
    func panelDidClose() {
        expanded = nil
        highlighted = nil
        route = .list
        clearSearch()
    }

    func clearSearch() {
        highlighted = nil
        searchText = ""
        searchResults = []
        resultsQuery = ""
        searchQuotes = [:]
        searchQuotesQuery = ""
        searchError = nil
        isSearching = false
        batchMissing = []
        batchError = nil
    }

    /// 批量添加：先查一次行情确认代码存在，查到的全部加进自选。全部成功时清空搜索框，否则留着让用户看哪些没找到。
    func addBatch(using store: QuoteStore) async {
        guard let batch, !isAddingBatch else { return }
        let pending = batch.symbols.filter { !store.contains($0) && !batchMissing.contains($0) }
        guard !pending.isEmpty else { return }
        isAddingBatch = true
        batchError = nil
        defer { isAddingBatch = false }
        do {
            let missing = try await store.addMany(pending)
            batchMissing.formUnion(missing)
            if missing.isEmpty, batch.rejected.isEmpty {
                clearSearch()
            }
        } catch {
            batchError = "查询行情失败：\(error.localizedDescription)"
        }
    }

    func toggleExpanded(_ symbol: Symbol) {
        expanded = expanded == symbol ? nil : symbol
    }

    /// 搜索结果里回车会添加的那一条：第一条还没添加的。键盘还没选时高亮它。
    func defaultSearchHighlight(excluding contains: (Symbol) -> Bool) -> Symbol? {
        guard resultsQuery == trimmedQuery else { return nil }
        return searchResults.first { !contains($0.symbol) }?.symbol
    }

    /// 上下方向键：在 symbols 里移动选中的那一只，到头了停住。还没选时从 start 算起，start 也没有就从头或尾开始。
    func moveHighlight(by step: Int, in symbols: [Symbol], from start: Symbol?) {
        guard !symbols.isEmpty else { return }
        if let current = (highlighted ?? start).flatMap({ symbols.firstIndex(of: $0) }) {
            highlighted = symbols[min(max(current + step, 0), symbols.count - 1)]
        } else {
            highlighted = step > 0 ? symbols[0] : symbols[symbols.count - 1]
        }
    }

    /// 由 `.task(id: searchText)` 调用：输入变化时上一次搜索会被取消，相当于 250ms 防抖。
    func runSearch(using store: QuoteStore) async {
        let query = trimmedQuery
        highlighted = nil
        batchMissing = []
        batchError = nil
        // 粘贴了多个代码：不用搜索接口，由批量添加处理。
        guard !query.isEmpty, batch == nil else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            let results = try await store.search(query)
            guard !Task.isCancelled, query == trimmedQuery else { return }
            searchResults = results.isEmpty ? directCandidate(for: query) : results
            resultsQuery = query
            searchError = nil
        } catch {
            guard !Task.isCancelled, query == trimmedQuery else { return }
            // 搜索接口失败时，仍然允许按代码直接添加。
            searchResults = directCandidate(for: query)
            resultsQuery = query
            searchError = error.localizedDescription
        }
        isSearching = false
        await loadSearchQuotes(for: query, using: store)
    }

    /// 搜索结果出来后查一次它们的行情，每一条后面显示现价和涨跌幅；按代码直接添加的那条也能看出代码存不存在。
    private func loadSearchQuotes(for query: String, using store: QuoteStore) async {
        let symbols = searchResults.map(\.symbol)
        guard !symbols.isEmpty else { return }
        let quotes = try? await store.previewQuotes(for: symbols)
        guard !Task.isCancelled, query == trimmedQuery else { return }
        searchQuotes = quotes ?? [:]
        searchQuotesQuery = quotes == nil ? "" : query
    }

    /// 这条搜索结果查过行情但是查不到：多半是不存在的代码。
    func searchResultMissing(_ symbol: Symbol) -> Bool {
        searchQuotesQuery == trimmedQuery && !searchQuotesQuery.isEmpty && searchQuotes[symbol] == nil
    }

    /// 回车要添加的证券：搜索结果已就绪时取第一条未添加的结果；
    /// 还在防抖或请求中时，只有明确是代码的输入才直接添加，纯字母可能是拼音缩写，要等搜索结果。
    func submissionCandidate(excluding contains: (Symbol) -> Bool) -> SearchResult? {
        let query = trimmedQuery
        guard !query.isEmpty else { return nil }
        if resultsQuery == query {
            return searchResults.first { !contains($0.symbol) }
        }
        guard SymbolInput.isExplicitCode(query) else { return nil }
        return directCandidate(for: query).first { !contains($0.symbol) }
    }

    private func directCandidate(for query: String) -> [SearchResult] {
        guard let symbol = SymbolInput.parse(query) else { return [] }
        return [SearchResult(symbol: symbol, name: symbol.displayCode, typeCode: SearchResult.directTypeCode)]
    }
}
