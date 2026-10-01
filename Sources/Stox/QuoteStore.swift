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
    /// 看过的五日分时。
    @Published private(set) var fiveDay: [Symbol: MultiDaySeries] = [:]
    /// 看过的资金流向（A 股个股和 ETF）。
    @Published private(set) var fundFlows: [Symbol: FundFlow] = [:]
    /// 列表里每一行的迷你分时，面板打开时取（见 trackSparklines）。
    @Published private(set) var sparklines: [Symbol: Sparkline] = [:]
    /// 每只的迷你分时上次是什么时候取的。
    private var sparklineFetched: [Symbol: Date] = [:]
    /// 取过资金流向的证券，取到了没有都算，用来区分“正在加载”和“没有数据”。
    @Published private(set) var fundFlowLoaded: Set<Symbol> = []
    /// 每个交易日收盘后记下的持仓盈亏，只在这台 Mac 上。
    @Published private(set) var profitHistory: ProfitHistory
    /// 最近发过的提醒，面板里可以翻看。
    @Published private(set) var alertLog: AlertLog
    /// 美股个股盘前盘后的最新成交。美股常规交易时段里是空的。
    @Published private(set) var extendedHours: [Symbol: ExtendedHoursQuote] = [:]
    /// A 股涨跌榜，打开榜单页时才取（见 RankPanel）。
    @Published private(set) var rank: [RankKind: [RankEntry]] = [:]
    /// 行业榜。
    @Published private(set) var industries: [IndustryEntry]?
    @Published private(set) var rankUpdated: [RankKind: Date] = [:]
    /// 最近一次取榜单失败的原因；取到了就清掉。
    @Published private(set) var rankError: String?
    /// 上一次取盘前盘后价的时间和当时取的是哪几只。
    private var extendedHoursFetched: (date: Date, symbols: Set<Symbol>) = (.distantPast, [])

    /// 港币、美元兑人民币的汇率。持仓有两种以上货币时才去取，用来折合成人民币。
    @Published private(set) var rates: ExchangeRates?
    /// 上一次取汇率的时间。
    private var ratesFetched = Date.distantPast

    /// 价格提醒触发时回调（由 AppDelegate 转成系统通知）。
    var onAlert: ((AlertTrigger) -> Void)?
    /// 收盘小结要发的时候回调（由 AppDelegate 转成系统通知）。
    var onCloseSummary: ((CloseSummaryNote) -> Void)?
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
    /// 异动提醒用的最近几分钟的价格。
    private var rapidMoves = RapidMoveDetector()
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
        profitHistory = defaults.data(forKey: Keys.profitHistory)
            .flatMap { try? JSONDecoder().decode(ProfitHistory.self, from: $0) } ?? ProfitHistory()
        alertLog = defaults.data(forKey: Keys.alertLog)
            .flatMap { try? JSONDecoder().decode(AlertLog.self, from: $0) } ?? AlertLog()
        if let data = defaults.data(forKey: Keys.alertState),
           let engine = try? JSONDecoder().decode(AlertEngine.self, from: data) {
            alertEngine = engine
        } else {
            alertEngine = AlertEngine()
        }

        // 刷新相关设置变化后立刻按新节奏重新开始轮询；打开盘前盘后价时马上去取。
        Publishers.Merge3(
            settings.$refreshInterval.removeDuplicates().map { _ in () },
            settings.$slowWhenIdle.removeDuplicates().map { _ in () },
            settings.$showExtendedHours.removeDuplicates().map { _ in () }
        )
        .dropFirst(3)
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
            lastError = result.isEmpty ? L("没有取到行情数据") : nil
            // 名称只从主数据源记：两家的叫法有细微差别，来回改会让 iCloud 同步个不停。
            if source == .primary {
                cacheNames(from: result)
            }
            evaluateAlerts()
            checkRapidMoves(result)
            checkCloseSummaries()
            recordProfitHistory()
            await refreshRatesIfNeeded()
            await refreshExtendedHoursIfNeeded()
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

    /// 美股不在常规交易时取自选里美股个股的盘前盘后价，每只一个请求：盘前盘后至少隔 15 秒取一次，
    /// 美股多时按每只 2 秒放慢；休市时价格不会再变，半小时一次；自选里多了美股个股时马上取。
    /// 常规交易时段里、设置里关掉时清空，也不去取。
    private func refreshExtendedHoursIfNeeded() async {
        let symbols = items.map(\.symbol).filter { $0.market.region == .us && !$0.isIndex }
        let usPhase = self.phase(for: .us)
        guard settings.showExtendedHours, !symbols.isEmpty, usPhase != .trading, usPhase != .lunchBreak else {
            if !extendedHours.isEmpty { extendedHours = [:] }
            extendedHoursFetched = (.distantPast, [])
            return
        }
        let wanted = Set(symbols)
        let interval: TimeInterval = usPhase.isLive ? max(settings.refreshInterval, 15, Double(symbols.count) * 2) : 1800
        guard !wanted.isSubset(of: extendedHoursFetched.symbols)
            || Date().timeIntervalSince(extendedHoursFetched.date) >= interval
        else { return }
        extendedHoursFetched = (Date(), wanted)
        let provider = self.provider
        let requests = symbols.map { ($0, quotes[$0]?.exchangeCode) }
        // 每只的结果：取到了（可能是没有盘前盘后成交）或者请求失败。
        let results = await withTaskGroup(of: (Symbol, ExtendedHoursQuote?, Bool).self) { group in
            for (symbol, code) in requests {
                group.addTask {
                    do {
                        let value = try await provider.fetchExtendedHours(for: symbol, exchangeCode: code)
                        return (symbol, value, true)
                    } catch {
                        return (symbol, nil, false)
                    }
                }
            }
            var all: [(Symbol, ExtendedHoursQuote?, Bool)] = []
            for await result in group { all.append(result) }
            return all
        }
        // 取的时候进了常规交易或者关掉了，就不要这次的结果了。
        let phaseNow = self.phase(for: .us)
        guard settings.showExtendedHours, phaseNow != .trading, phaseNow != .lunchBreak else { return }
        let current = Set(items.map(\.symbol))
        var updated = extendedHours.filter { current.contains($0.key) }
        for (symbol, value, ok) in results where ok && current.contains(symbol) {
            // 请求失败时保留上一次的，下一轮再试。
            updated[symbol] = value
        }
        if updated != extendedHours { extendedHours = updated }
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
                    // 列表里的迷你分时也顺便更新，不用再取一次。
                    updateSparkline(symbol, from: series)
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
                // 比图上显示的多要一些，均线从图的最左边就有。
                let series = try await provider.fetchKline(
                    for: symbol, period: period, count: KlineChartData.fetchCount, exchangeCode: quotes[symbol]?.exchangeCode
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

    /// 面板打开、列表显示着的时候调用：给列表里的这些证券取当天的分时，抽成迷你分时。一次取一只，隔一会儿再取下一只，
    /// 不一下子发一堆请求；交易时段内两分钟一轮，休市时十分钟一轮。场外基金、外汇没有分时，不取。面板关上、列表换了就停（任务被取消）。
    func trackSparklines(_ symbols: [Symbol]) async {
        while !Task.isCancelled {
            for symbol in symbols where symbol.hasIntraday {
                guard !Task.isCancelled else { return }
                let maxAge: TimeInterval = phase(for: symbol.market.region).isLive ? 110 : 600
                if let fetched = sparklineFetched[symbol], Date().timeIntervalSince(fetched) < maxAge { continue }
                do {
                    if let series = try await provider.fetchIntraday(for: symbol), !Task.isCancelled {
                        updateSparkline(symbol, from: series)
                    }
                } catch {
                    // 取不到就先不画，下一轮再试。
                }
                sparklineFetched[symbol] = Date()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
        }
    }

    private func updateSparkline(_ symbol: Symbol, from series: IntradaySeries) {
        sparklineFetched[symbol] = Date()
        if let sparkline = Sparkline(series: series, region: symbol.market.region), sparklines[symbol] != sparkline {
            sparklines[symbol] = sparkline
        }
    }

    /// 切到“资金”时调用：先取一次，之后交易时段内每分钟刷新，休市时十分钟一次，直到收起或换页（任务被取消）。
    func trackFundFlow(_ symbol: Symbol) async {
        while !Task.isCancelled {
            do {
                let flow = try await provider.fetchFundFlow(for: symbol)
                if !Task.isCancelled {
                    // 取不到（开盘前、这只没有）时清掉旧的，免得把昨天的当成今天的。
                    fundFlows[symbol] = flow
                    fundFlowLoaded.insert(symbol)
                }
            } catch {
                // 和分时一样，失败时保留上一次的，下一轮再试。
                fundFlowLoaded.insert(symbol)
            }
            let live = phase(for: symbol.market.region).isLive
            try? await Task.sleep(nanoseconds: (live ? 60 : 600) * 1_000_000_000)
        }
    }

    /// 取一次涨跌榜的前 count 只（行业榜是前 count 个行业）。
    func loadRank(_ kind: RankKind, count: Int) async {
        do {
            if kind == .industries {
                if let entries = try await provider.fetchIndustries(count: count) {
                    industries = entries
                    rankUpdated[kind] = Date()
                    rankError = nil
                }
            } else if let entries = try await provider.fetchRank(kind, count: count) {
                rank[kind] = entries
                rankUpdated[kind] = Date()
                rankError = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            rankError = error.localizedDescription
        }
    }

    /// 切到五日时调用：和分时一样，交易时段内每分钟刷新，休市时半小时一次。
    func trackFiveDay(_ symbol: Symbol) async {
        while !Task.isCancelled {
            do {
                if let series = try await provider.fetchFiveDay(for: symbol, exchangeCode: quotes[symbol]?.exchangeCode),
                   !Task.isCancelled {
                    fiveDay[symbol] = series
                }
            } catch {
                // 失败时保留上一次的，下一轮再试。
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
        // 节假日靠盘中行情的时间认出来。只有场外基金时没有盘中行情，净值日期总是前一个交易日，
        // 拿它来认会把每个交易日都当成休市，所以这时只按时间表。
        let live = quotes.values.filter { $0.symbol.market.region == region && !$0.symbol.isFund }.compactMap(\.timestamp).max()
        return MarketClock.effectivePhase(for: region, at: date, latestQuoteTime: live)
    }

    /// 这个市场所有行情里最新的时间，收盘小结、盈亏记录和记一笔的交易日用它。场外基金的时间是净值日期，
    /// 比盘中的行情晚一天，有盘中行情时不算基金。
    func latestQuoteTime(for region: MarketRegion) -> Date? {
        let inRegion = quotes.values.filter { $0.symbol.market.region == region }
        let live = inRegion.filter { !$0.symbol.isFund }.compactMap(\.timestamp).max()
        // 只有基金时只能看净值日期。
        return live ?? inRegion.compactMap(\.timestamp).max()
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
        items.append(WatchItem(symbol: symbol, name: name, group: groupForNewItems))
        revealNewItems([symbol])
        save()
        restart()
    }

    /// 按市场或持仓筛选着、新加的看不到时回到“全部”，免得加完以为没加上。分组的会自动放进正在看的分组，不用管。
    private func revealNewItems(_ symbols: [Symbol]) {
        let visible = WatchlistFilter.effective(settings.listFilter, items: items).apply(items)
        if symbols.contains(where: { symbol in !visible.contains { $0.symbol == symbol } }) {
            settings.listFilter = .all
        }
    }

    /// 正在看某个分组时，新加的放进这个分组，免得加完在列表里看不到。
    private var groupForNewItems: String? {
        if case .group(let name) = WatchlistFilter.effective(settings.listFilter, items: items) { return name }
        return nil
    }

    /// 把一只放进分组；nil 是移出分组。
    func setGroup(_ group: String?, for symbol: Symbol) {
        guard let index = items.firstIndex(where: { $0.symbol == symbol }) else { return }
        var updated = items
        updated[index].group = group
        guard updated != items else { return }
        items = updated
        save()
    }

    /// 保存分组编辑页：members 放进 name 这个分组，old 分组里没勾上的移出；改了名时列表上方的筛选跟着换过去。
    /// name 为空相当于解散 old。
    func saveGroup(_ name: String, members: Set<Symbol>, replacing old: String?) {
        let updated = Watchlist.settingGroup(name, members: members, replacing: old, in: items)
        if let old, settings.listFilter == .group(old) {
            settings.listFilter = WatchItem.normalizedGroup(name).map { WatchlistFilter.group($0) } ?? .all
        }
        guard updated != items else { return }
        items = updated
        save()
    }

    /// 解散分组：这个分组里的都变成不分组。
    func dissolveGroup(_ name: String) {
        var updated = items
        for index in updated.indices where updated[index].group == name {
            updated[index].group = nil
        }
        guard updated != items else { return }
        items = updated
        save()
    }

    /// 一次加几只已知的（比如常用指数），已经在自选里的跳过。
    func add(_ newItems: [WatchItem]) {
        let fresh = newItems.filter { !contains($0.symbol) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        save()
        restart()
    }

    /// 批量添加：先查一次行情，只添加查得到的代码，名称也一并取回。返回查不到（不存在）的代码。
    func addMany(_ symbols: [Symbol]) async throws -> [Symbol] {
        let wanted = symbols.filter { !contains($0) }
        guard !wanted.isEmpty else { return [] }
        let result = try await fetchQuotes(wanted).quotes
        var added = false
        let group = groupForNewItems
        for symbol in wanted where result[symbol] != nil && !contains(symbol) {
            items.append(WatchItem(symbol: symbol, name: result[symbol]?.name ?? "", group: group))
            quotes[symbol] = result[symbol]
            added = true
        }
        if added {
            revealNewItems(wanted.filter { result[$0] != nil })
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
        fiveDay[symbol] = nil
        fundFlows[symbol] = nil
        fundFlowLoaded.remove(symbol)
        sparklines[symbol] = nil
        sparklineFetched[symbol] = nil
        extendedHours[symbol] = nil
        rapidMoves.forget(symbol)
        alertLog.forget(symbol)
        saveAlertLog()
        alertEngine.reset(symbol)
        save()
        saveAlertState()
    }

    /// 拖动排序。visible 是列表里看得见的那几只，筛选着的时候只在它们之间换位置，看不见的原地不动。
    func move(visible: [Symbol], fromOffsets source: IndexSet, toOffset destination: Int) {
        let updated = Watchlist.moving(items, visible: visible, fromOffsets: source, toOffset: destination)
        guard updated != items else { return }
        items = updated
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
        // 改了成本也算：止盈止损的比例是按成本算的。
        let costChanged = items[index].holding != updated.holding
            && (updated.alert.profitAbove != nil || updated.alert.lossBelow != nil)
        let alertChanged = items[index].alert != updated.alert || costChanged
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
        extendedHours = extendedHours.filter { symbols.contains($0.key) }
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

    /// 收盘后把各市场的持仓盈亏记下来，同一天再记就更新。和收盘小结不同，不管开没开通知都记。
    private func recordProfitHistory() {
        var history = profitHistory
        for summary in Portfolio.summaries(items: items, quotes: quotes) {
            let region = summary.region
            let latest = latestQuoteTime(for: region)
            guard let day = CloseSummary.closedDay(region: region, phase: phase(for: region), latestQuoteTime: latest, now: Date())
            else { continue }
            history.record(summary, day: day)
        }
        guard history != profitHistory else { return }
        profitHistory = history
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Keys.profitHistory)
        }
    }

    /// 记进最近的提醒。
    private func log(_ trigger: AlertTrigger) {
        alertLog.append(trigger, at: Date())
        saveAlertLog()
    }

    func clearAlertLog() {
        alertLog.removeAll()
        saveAlertLog()
    }

    private func saveAlertLog() {
        if let data = try? JSONEncoder().encode(alertLog) {
            defaults.set(data, forKey: Keys.alertLog)
        }
    }

    /// 这次运行发出的提醒条数和收盘小结条数，CI 的诊断信息里用。
    private(set) var firedAlertCount = 0
    private(set) var closeSummaryCount = 0

    /// 有持仓的市场收盘后发一条今日盈亏小结，每个市场每个交易日一次。
    private func checkCloseSummaries() {
        guard settings.closeSummary else { return }
        for summary in Portfolio.summaries(items: items, quotes: quotes) {
            let region = summary.region
            let latest = latestQuoteTime(for: region)
            let key = Keys.closeSummaryPrefix + region.rawValue
            guard let note = CloseSummary.due(
                region: region, phase: phase(for: region), summary: summary,
                latestQuoteTime: latest, now: Date(), lastSentDay: defaults.string(forKey: key),
                movers: CloseSummary.movers(items: items, quotes: quotes, region: region),
                hidingAmounts: settings.hideAmounts
            ) else { continue }
            defaults.set(note.day, forKey: key)
            closeSummaryCount += 1
            alertLog.append(note, at: Date())
            saveAlertLog()
            onCloseSummary?(note)
        }
    }

    /// 异动提醒：交易时段里每次刷新把新行情记一笔，几分钟内涨跌超过设置的幅度时提醒（见 RapidMoveDetector）。
    private func checkRapidMoves(_ fresh: [Symbol: Quote]) {
        let threshold = settings.rapidMoveThreshold
        guard settings.alertsEnabled, threshold > 0 else { return }
        let now = Date()
        for item in items {
            guard let quote = fresh[item.symbol], quote.hasTraded,
                  phase(for: item.symbol.market.region) == .trading,
                  let move = rapidMoves.record(quote, at: now, threshold: threshold)
            else { continue }
            firedAlertCount += 1
            let name = item.displayName(with: quote)
            let trigger = AlertTrigger(
                symbol: item.symbol, name: name, condition: move.direction == .up ? .rapidRise : .rapidFall,
                threshold: move.percent, quote: quote
            )
            log(trigger)
            onAlert?(trigger)
        }
    }

    private func evaluateAlerts() {
        guard settings.alertsEnabled else { return }
        let triggers = alertEngine.evaluate(
            items: items, quotes: quotes, now: Date(), limitAlerts: settings.limitAlerts, yearAlerts: settings.yearHighLowAlerts
        )
        guard !triggers.isEmpty else { return }
        firedAlertCount += triggers.count
        saveAlertState()
        for fired in triggers {
            // 隐藏金额时，止盈止损提醒的正文里只写比例。
            var trigger = fired
            trigger.hidesAmounts = settings.hideAmounts
            log(trigger)
            onAlert?(trigger)
        }
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
        static let closeSummaryPrefix = "alerts.closeSummary.sent."
        static let profitHistory = "holdings.history.v1"
        static let alertLog = "alerts.log.v1"
    }
}

/// K 线缓存的键：哪只证券、哪个周期。
struct KlineKey: Hashable {
    var symbol: Symbol
    var period: KlinePeriod
}
