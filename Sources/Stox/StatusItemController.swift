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

    /// 打开面板。后三个参数用于调试和 CI 截图：展开某一行、预填搜索词、打印诊断信息。
    func openPanel(route: PanelRoute = .list, expand: Symbol? = nil, search: String? = nil, printDiagnostics: Bool = false) {
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
        if printDiagnostics {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.printDiagnostics()
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
        panel.onClose = { [weak self] in self?.panelLostFocus() }
        panel.onEscape = { [weak self] in self?.router.handleEscape() ?? false }
        self.panel = panel
    }

    private func panelLostFocus() {
        guard let panel, panel.isVisible else { return }
        lastAutoClose = Date()
        closePanel()
    }

    private func resizePanel() {
        guard let hostingView else { return }
        resizePanel(to: hostingView.fittingSize)
    }

    /// 顶边不动，按内容尺寸调整窗口。屏幕放不下时先把列表压矮，面板永远不盖住菜单栏。
    private func resizePanel(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        var height = ceil(size.height)
        if let available = availableHeight(), height > available {
            let minimum = QuoteRow.rowHeight * 2
            if router.listMaxHeight > minimum {
                let limit = max(minimum, router.listMaxHeight - (height - available))
                // 在 SwiftUI 量尺寸的回调里，放到下一轮再改，避免在视图更新期间发布变化。
                DispatchQueue.main.async { [weak self] in
                    self?.router.listMaxHeight = limit
                }
            }
            height = floor(available)
        }
        let rounded = NSSize(width: ceil(size.width), height: height)
        guard rounded != panel.frame.size else { return }
        let origin = NSPoint(x: panel.frame.origin.x, y: panel.frame.maxY - rounded.height)
        panel.setFrame(NSRect(origin: origin, size: rounded), display: true)
    }

    /// 面板最多能有多高：从菜单栏图标下面到屏幕可见区域的底部。
    private func availableHeight() -> CGFloat? {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main
        else { return nil }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonRect.minY - 2 - (screen.visibleFrame.minY + 6)
    }

    /// 放在菜单栏图标正下方，不超出屏幕。
    private func position(_ panel: PanelWindow) {
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

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let entries = settings.hideTicker
            ? []
            : MenuBarTicker.entries(items: store.items, quotes: store.quotes, options: settings.tickerOptions)

        guard !entries.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = Self.icon
            return
        }

        let shown: [[TickerPart]]
        if settings.rotateTicker, entries.count > 1 {
            shown = [entries[rotationIndex % entries.count]]
        } else {
            shown = entries
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
        let shouldRotate = settings.rotateTicker && !settings.hideTicker && store.items.filter(\.pinned).count > 1
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
        print("STOX_DIAG status_title=\"\(title)\" image=\(statusItem.button?.image != nil) color=\(settings.colorConvention.rawValue)")
        let statusFrame = statusItem.button?.window?.frame
        if let statusFrame {
            print("STOX_DIAG status_frame=\(topLeft(statusFrame))")
        }
        let panelFrame = panel?.isVisible == true ? panel?.frame : nil
        if let panelFrame {
            print("STOX_DIAG panel_frame=\(topLeft(panelFrame))")
        }
        let frames = [statusFrame, panelFrame].compactMap { $0 }
        if let first = frames.first {
            print("STOX_DIAG capture_frame=\(topLeft(frames.dropFirst().reduce(first) { $0.union($1) }))")
        }
        let holdings = store.items.filter { $0.holding != nil }.count
        let intraday = store.intraday.values.map(\.points.count).max() ?? 0
        print("STOX_DIAG items=\(store.items.count) quotes=\(store.quotes.count) holdings=\(holdings) intraday=\(intraday) error=\(store.lastError ?? "none")")
        fflush(stdout)
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
    @Published private(set) var searchResults: [SearchResult] = []
    /// searchResults 对应的查询词；输入后防抖期间两者不一致。
    private var resultsQuery = ""
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
        route = .list
        clearSearch()
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
        resultsQuery = ""
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

    /// 由 `.task(id: searchText)` 调用：输入变化时上一次搜索会被取消，相当于 250ms 防抖。
    func runSearch(using store: QuoteStore) async {
        let query = trimmedQuery
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
