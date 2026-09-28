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
    /// 展开过的证券的分时走势。
    @Published private(set) var intraday: [Symbol: IntradaySeries] = [:]
    /// 看过的 K 线，按证券和周期存。
    @Published private(set) var klines: [KlineKey: KlineSeries] = [:]

    /// 港币、美元兑人民币的汇率。持仓有两种以上货币时才去取，用来折合成人民币。
    @Published private(set) var rates: ExchangeRates?
    /// 上一次取汇率的时间。
    private var ratesFetched = Date.distantPast

    /// 每张 K 线图最多显示多少根。
    static let klineCount = 60

    /// 价格提醒触发时回调（由 AppDelegate 转成系统通知）。
    var onAlert: ((AlertTrigger) -> Void)?
    /// 自选列表保存之后调用（由 SyncManager 设置，用来同步到 iCloud）。
    var onLocalEdit: (() -> Void)?

    let provider: QuoteProvider
    /// 腾讯的行情接口取不到时改用的备用数据源（新浪），只用来取实时行情。
    private let backup: QuoteProvider?
    /// 最近一次行情来自备用数据源。
    @Published private(set) var usingBackup = false
    /// 主数据源刚失败过：这个时间之前直接用备用的，免得每次刷新都先等主数据源超时。
    private var primaryRetryAfter = Date.distantPast
    private let settings: SettingsStore
    private let defaults: UserDefaults
    private var alertEngine: AlertEngine
    private var loopTask: Task<Void, Never>?
    /// 每次刷新递增；较早发出、较晚返回的请求结果会被丢弃。
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: SettingsStore,
        provider: QuoteProvider = TencentProvider(),
        backup: QuoteProvider? = SinaProvider(),
        defaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.provider = provider
        self.backup = backup
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
            let (result, source) = try await fetchQuotes(symbols)
            guard current == generation else { return }
            var merged = quotes.filter { symbols.contains($0.key) }
            merged.merge(result) { _, new in new }
            quotes = merged
            lastUpdated = Date()
            lastError = result.isEmpty ? "没有取到行情数据" : nil
            // 名称只从主数据源记：两家的叫法有细微差别，来回改会让 iCloud 同步个不停。
            if source == .primary {
                cacheNames(from: result)
            }
            evaluateAlerts()
            await refreshRatesIfNeeded()
        } catch {
            guard current == generation else { return }
            lastError = error.localizedDescription
        }
    }

    /// 持仓涉及两种以上货币时，每 10 分钟取一次汇率；取不到时一分钟后再试，这期间照旧按货币分开显示。
    private func refreshRatesIfNeeded() async {
        let currencies = Set(items.filter { $0.holding != nil }.map { $0.symbol.market.region })
        guard currencies.count > 1, Date().timeIntervalSince(ratesFetched) > 600 else { return }
        ratesFetched = Date()
        do {
            if let value = try await provider.fetchExchangeRates() {
                rates = value
            }
        } catch {
            ratesFetched = Date().addingTimeInterval(-540)
        }
    }

    /// 当前实际的刷新间隔：所有关注的市场都休市时会放宽到每分钟一次。
    var effectiveInterval: TimeInterval {
        let phases = activeRegions.map { phase(for: $0) }
        return RefreshPolicy.interval(base: settings.refreshInterval, phases: phases, slowWhenIdle: settings.slowWhenIdle)
    }

    /// 展开某只证券时调用：先取一次分时，之后交易时段内每分钟刷新，休市时十分钟一次，直到收起（任务被取消）。
    func trackIntraday(_ symbol: Symbol) async {
        while !Task.isCancelled {
            do {
                if let series = try await provider.fetchIntraday(for: symbol) {
                    intraday[symbol] = series
                }
            } catch {
                // 分时只是锦上添花，失败时保留上一次的，下一轮再试。
            }
            let live = phase(for: symbol.market.region).isLive
            try? await Task.sleep(nanoseconds: (live ? 60 : 600) * 1_000_000_000)
        }
    }

    /// 切到 K 线时调用：先取一次，之后交易时段内每分钟刷新，休市时半小时一次，直到收起或换周期（任务被取消）。
    /// 两次请求之间最后一根 K 线由实时行情更新（见 KlineSeries.merging）。
    func trackKline(_ symbol: Symbol, period: KlinePeriod) async {
        let key = KlineKey(symbol: symbol, period: period)
        while !Task.isCancelled {
            do {
                let series = try await provider.fetchKline(
                    for: symbol, period: period, count: Self.klineCount, exchangeCode: quotes[symbol]?.exchangeCode
                )
                if let series, !Task.isCancelled {
                    klines[key] = series
                }
            } catch {
                // 和分时一样，失败时保留上一次的，下一轮再试。
            }
            let live = phase(for: symbol.market.region).isLive
            try? await Task.sleep(nanoseconds: (live ? 60 : 1800) * 1_000_000_000)
        }
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

    /// 批量添加：先查一次行情，只添加查得到的代码，名称也一并取回。返回查不到（不存在）的代码。
    func addMany(_ symbols: [Symbol]) async throws -> [Symbol] {
        let wanted = symbols.filter { !contains($0) }
        guard !wanted.isEmpty else { return [] }
        let result = try await fetchQuotes(wanted).quotes
        var added = false
        for symbol in wanted where result[symbol] != nil && !contains(symbol) {
            items.append(WatchItem(symbol: symbol, name: result[symbol]?.name ?? ""))
            quotes[symbol] = result[symbol]
            added = true
        }
        if added {
            save()
            restart()
        }
        return wanted.filter { result[$0] == nil }
    }

    func remove(_ symbol: Symbol) {
        items.removeAll { $0.symbol == symbol }
        quotes[symbol] = nil
        intraday[symbol] = nil
        klines = klines.filter { $0.key.symbol != symbol }
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

    /// 用 iCloud 同步来的自选替换本机的。提醒条件变了的证券清掉当天的提醒记录。
    func replaceWatchlist(_ newItems: [WatchItem]) {
        guard newItems != items else { return }
        let oldAlerts = Dictionary(items.map { ($0.symbol, $0.alert) }, uniquingKeysWith: { first, _ in first })
        let symbols = Set(newItems.map(\.symbol))
        items = newItems
        quotes = quotes.filter { symbols.contains($0.key) }
        for item in newItems where oldAlerts[item.symbol] != item.alert {
            alertEngine.reset(item.symbol)
        }
        save()
        saveAlertState()
        restart()
    }

    func search(_ query: String) async throws -> [SearchResult] {
        try await provider.search(query)
    }

    /// 搜索结果的行情：只查不存，不影响自选。
    func previewQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        try await fetchQuotes(Array(symbols.prefix(30))).quotes
    }

    /// 取实时行情：先用腾讯，取不到时改用新浪。主数据源失败后两分钟内直接用备用的，之后再试主数据源。
    private func fetchQuotes(_ symbols: [Symbol]) async throws -> (quotes: [Symbol: Quote], source: QuoteSource) {
        let skipPrimary = Date() < primaryRetryAfter
        let result = try await QuoteFailover.fetchQuotes(symbols, primary: provider, backup: backup, skipPrimary: skipPrimary)
        let backupNow = result.source == .backup
        if backupNow, !skipPrimary {
            primaryRetryAfter = Date().addingTimeInterval(120)
        } else if !backupNow {
            primaryRetryAfter = .distantPast
        }
        if backupNow != usingBackup {
            usingBackup = backupNow
            Log.info(backupNow ? "腾讯行情取不到，改用新浪行情" : "腾讯行情恢复了")
        }
        return result
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
        onLocalEdit?()
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

/// K 线缓存的键：哪只证券、哪个周期。
struct KlineKey: Hashable {
    var symbol: Symbol
    var period: KlinePeriod
}
