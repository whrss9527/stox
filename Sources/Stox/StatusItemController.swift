import AppKit
import Combine
import SwiftUI
import StoxCore

/// 菜单栏图标 + 弹出面板。
///
/// - 左键单击：打开 / 关闭面板（再点一次、点面板外、按 Esc 都会关闭）
/// - 右键或 Control+单击：快捷菜单（刷新、隐藏行情、设置、退出）
@MainActor
final class StatusItemController: NSObject {
    private let store: QuoteStore
    private let settings: SettingsStore
    private let router = PanelRouter()
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    /// 打开面板前处于前台的 App，关闭面板后把焦点还给它。
    private var previousApp: NSRunningApplication?
    private var rotationTimer: Timer?
    private var rotationIndex = 0
    private var cancellables = Set<AnyCancellable>()

    init(store: QuoteStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.autosaveName = "StoxStatusItem"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            // 和系统菜单一样在按下鼠标时响应，打开更跟手。
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
            button.toolTip = "Stox 行情（⌃⌥S）"
        }

        // 面板的开关完全由自己控制：transient 行为下点击菜单栏图标会先关闭再立刻重新打开。
        popover.behavior = .applicationDefined
        // 不要淡入淡出：一键开关要干脆，也避免快速连点时开关动画交错。
        popover.animates = false
        let rootView = PanelView()
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(router)
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        NotificationCenter.default.addObserver(
            self, selector: #selector(popoverDidClose(_:)), name: NSPopover.didCloseNotification, object: popover
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive(_:)), name: NSApplication.didResignActiveNotification, object: nil
        )

        Publishers.Merge(store.objectWillChange, settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateRotationTimer()
                self?.updateButton()
            }
            .store(in: &cancellables)

        updateRotationTimer()
        updateButton()
    }

    // MARK: - 面板开关

    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        store.panelWillOpen()
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startMonitors()
    }

    /// - Parameter restoreFocus: 用快捷键、Esc 或菜单栏图标关闭时，把焦点还给之前的 App；
    ///   因为点击了别的 App 而关闭时不需要。
    func closePopover(restoreFocus: Bool = true) {
        let wasShown = popover.isShown
        if wasShown {
            popover.performClose(nil)
        }
        stopMonitors()
        if wasShown, restoreFocus, NSApp.isActive, let app = previousApp, !app.isTerminated {
            app.activate(options: [])
        }
        previousApp = nil
    }

    private func startMonitors() {
        stopMonitors()
        // 点击其他 App 或桌面时关闭。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover(restoreFocus: false)
            }
        }
        // Esc：先清空搜索 / 返回列表，再关闭面板。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                self?.handleEscape()
            }
            return nil
        }
    }

    private func stopMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleEscape() {
        if !router.handleEscape() {
            closePopover()
        }
    }

    @objc private func popoverDidClose(_ notification: Notification) {
        // 快速连点时，上一次关闭的通知可能在面板重新打开之后才到。
        guard !popover.isShown else { return }
        stopMonitors()
        router.panelDidClose()
    }

    @objc private func appDidResignActive(_ notification: Notification) {
        closePopover(restoreFocus: false)
    }

    // MARK: - 点击与右键菜单

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        closePopover(restoreFocus: false)
        let menu = NSMenu()
        menu.addItem(menuItem("打开面板", #selector(openPanel), key: ""))
        menu.addItem(menuItem("立即刷新", #selector(refreshNow), key: "r"))
        menu.addItem(menuItem(settings.hideTicker ? "显示菜单栏行情" : "隐藏菜单栏行情", #selector(toggleTicker), key: "h"))
        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 Stox", #selector(quit), key: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openPanel() {
        router.route = .list
        showPopover()
    }

    @objc private func refreshNow() {
        store.restart()
    }

    @objc private func toggleTicker() {
        settings.hideTicker.toggle()
    }

    @objc private func openSettings() {
        router.route = .settings
        showPopover()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
                    : Theme.nsColor(for: part.direction, convention: settings.colorConvention)
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
}

enum PanelRoute: Equatable {
    case list
    case settings
    case edit(Symbol)
}

/// 面板内的页面切换与搜索状态。放在一个对象里，方便 Esc 键统一处理。
@MainActor
final class PanelRouter: ObservableObject {
    @Published var route: PanelRoute = .list
    @Published var searchText = ""
    @Published var expanded: Symbol?
    @Published private(set) var searchResults: [SearchResult] = []
    /// searchResults 对应的查询词；输入后防抖期间两者不一致。
    private var resultsQuery = ""
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?

    var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    func toggleExpanded(_ symbol: Symbol) {
        expanded = expanded == symbol ? nil : symbol
    }

    /// 由 `.task(id: searchText)` 调用：输入变化时上一次搜索会被取消，相当于 250ms 防抖。
    func runSearch(using store: QuoteStore) async {
        let query = trimmedQuery
        guard !query.isEmpty else {
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
    /// 还在防抖或请求中时，只有明确是代码的输入（含数字，或带 us/hk 前缀）才直接添加，
    /// 纯字母可能是拼音缩写，要等搜索结果。
    func submissionCandidate(excluding contains: (Symbol) -> Bool) -> SearchResult? {
        let query = trimmedQuery
        guard !query.isEmpty else { return nil }
        if resultsQuery == query {
            return searchResults.first { !contains($0.symbol) }
        }
        let isExplicitCode = query.contains(where: \.isNumber) || query.hasPrefix("us") || query.hasPrefix("hk")
        guard isExplicitCode else { return nil }
        return directCandidate(for: query).first { !contains($0.symbol) }
    }

    private func directCandidate(for query: String) -> [SearchResult] {
        guard let symbol = SymbolInput.parse(query) else { return [] }
        return [SearchResult(symbol: symbol, name: symbol.displayCode, typeCode: SearchResult.directTypeCode)]
    }
}
