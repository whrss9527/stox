import Combine
import Foundation
import SwiftUI
import StoxCore

/// 自选列表 + 行情轮询 + 价格提醒。所有状态都在主线程上更新。
@MainActor
final class QuoteStore: ObservableObject {
    @Published private(set) var items: [WatchItem]
    @Published private(set) var quotes: [Symbol: Quote] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    /// 价格提醒触发时回调（由 AppDelegate 转成系统通知）。
    var onAlert: ((AlertTrigger) -> Void)?

    let provider: QuoteProvider
    private let settings: SettingsStore
    private let defaults: UserDefaults
    private var alertEngine: AlertEngine
    private var loopTask: Task<Void, Never>?
    /// 每次刷新递增；较早发出、较晚返回的请求结果会被丢弃。
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore, provider: QuoteProvider = TencentProvider(), defaults: UserDefaults = .standard) {
        self.settings = settings
        self.provider = provider
        self.defaults = defaults

        if let data = defaults.data(forKey: Keys.watchlist), let saved = Watchlist.decode(data) {
            items = saved
        } else {
            items = Watchlist.defaults
        }
        if let data = defaults.data(forKey: Keys.alertState),
           let engine = try? JSONDecoder().decode(AlertEngine.self, from: data) {
            alertEngine = engine
        } else {
            alertEngine = AlertEngine()
        }

        // 刷新相关设置变化后立刻按新节奏重新开始轮询。
        Publishers.Merge(
            settings.$refreshInterval.removeDuplicates().map { _ in () },
            settings.$slowWhenIdle.removeDuplicates().map { _ in () }
        )
        .dropFirst(2)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.restart() }
        .store(in: &cancellables)
    }

    // MARK: - 轮询

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let delay = self.effectiveInterval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 立即刷新并重置计时。
    func restart() {
        stop()
        start()
    }

    /// 打开面板时，如果数据已经不新鲜就马上刷新。
    func panelWillOpen() {
        guard let lastUpdated else {
            restart()
            return
        }
        if Date().timeIntervalSince(lastUpdated) > min(settings.refreshInterval, 3) {
            restart()
        }
    }

    func refresh() async {
        let symbols = items.map(\.symbol)
        guard !symbols.isEmpty else {
            quotes = [:]
            lastError = nil
            return
        }
        generation += 1
        let current = generation
        isRefreshing = true
        defer {
            if current == generation { isRefreshing = false }
        }
        do {
            let result = try await provider.fetchQuotes(for: symbols)
            guard current == generation else { return }
            var merged = quotes.filter { symbols.contains($0.key) }
            merged.merge(result) { _, new in new }
            quotes = merged
            lastUpdated = Date()
            lastError = result.isEmpty ? "没有取到行情数据" : nil
            cacheNames(from: result)
            evaluateAlerts()
        } catch {
            guard current == generation else { return }
            lastError = error.localizedDescription
        }
    }

    /// 当前实际的刷新间隔：所有关注的市场都休市时会放宽到每分钟一次。
    var effectiveInterval: TimeInterval {
        let phases = activeRegions.map { phase(for: $0) }
        return RefreshPolicy.interval(base: settings.refreshInterval, phases: phases, slowWhenIdle: settings.slowWhenIdle)
    }

    // MARK: - 市场状态

    /// 自选里出现过的市场，按 A 股、港股、美股排序。
    var activeRegions: [MarketRegion] {
        MarketRegion.allCases.filter { region in items.contains { $0.symbol.market.region == region } }
    }

    func phase(for region: MarketRegion, at date: Date = Date()) -> MarketPhase {
        let latest = quotes.values
            .filter { $0.symbol.market.region == region }
            .compactMap(\.timestamp)
            .max()
        return MarketClock.effectivePhase(for: region, at: date, latestQuoteTime: latest)
    }

    // MARK: - 自选管理

    func contains(_ symbol: Symbol) -> Bool {
        items.contains { $0.symbol == symbol }
    }

    func item(for symbol: Symbol) -> WatchItem? {
        items.first { $0.symbol == symbol }
    }

    func add(_ symbol: Symbol, name: String = "") {
        guard !contains(symbol) else { return }
        items.append(WatchItem(symbol: symbol, name: name))
        save()
        restart()
    }

    func remove(_ symbol: Symbol) {
        items.removeAll { $0.symbol == symbol }
        quotes[symbol] = nil
        alertEngine.reset(symbol)
        save()
        saveAlertState()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func moveToTop(_ symbol: Symbol) {
        guard let index = items.firstIndex(where: { $0.symbol == symbol }), index > 0 else { return }
        items.insert(items.remove(at: index), at: 0)
        save()
    }

    func togglePinned(_ symbol: Symbol) {
        guard let index = items.firstIndex(where: { $0.symbol == symbol }) else { return }
        items[index].pinned.toggle()
        save()
    }

    /// 保存编辑页的修改。提醒条件变化时清掉当天的提醒记录，让新阈值立刻生效。
    func update(_ updated: WatchItem) {
        guard let index = items.firstIndex(where: { $0.symbol == updated.symbol }) else { return }
        let alertChanged = items[index].alert != updated.alert
        items[index] = updated
        save()
        if alertChanged {
            alertEngine.reset(updated.symbol)
            saveAlertState()
            evaluateAlerts()
        }
    }

    func search(_ query: String) async throws -> [SearchResult] {
        try await provider.search(query)
    }

    // MARK: - 内部

    private func cacheNames(from result: [Symbol: Quote]) {
        var updated = items
        var changed = false
        for index in updated.indices {
            if let name = result[updated[index].symbol]?.name, !name.isEmpty, updated[index].name != name {
                updated[index].name = name
                changed = true
            }
        }
        if changed {
            items = updated
            save()
        }
    }

    private func evaluateAlerts() {
        guard settings.alertsEnabled else { return }
        let triggers = alertEngine.evaluate(items: items, quotes: quotes, now: Date())
        guard !triggers.isEmpty else { return }
        saveAlertState()
        triggers.forEach { onAlert?($0) }
    }

    private func save() {
        if let data = Watchlist.encode(items) {
            defaults.set(data, forKey: Keys.watchlist)
        }
    }

    private func saveAlertState() {
        if let data = try? JSONEncoder().encode(alertEngine) {
            defaults.set(data, forKey: Keys.alertState)
        }
    }

    private enum Keys {
        static let watchlist = "watchlist.v1"
        static let alertState = "alerts.fired.v1"
    }
}
