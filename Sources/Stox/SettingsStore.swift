import AppKit
import StoxCore

enum ColorConvention: String, CaseIterable, Identifiable {
    case redUp, greenUp, neutral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .redUp: return "红涨绿跌"
        case .greenUp: return "绿涨红跌"
        case .neutral: return "不显示红绿"
        }
    }

    var detail: String {
        switch self {
        case .redUp: return "A 股、港股的习惯"
        case .greenUp: return "美股的习惯"
        case .neutral: return "全部使用系统默认颜色，不显眼"
        }
    }
}

extension WatchlistSort {
    var title: String {
        switch self {
        case .custom: return "自定义顺序"
        case .gainers: return "涨幅从高到低"
        case .losers: return "跌幅从高到低"
        case .holdingProfit: return "持仓盈亏从高到低"
        }
    }
}

extension WatchlistFilter {
    var title: String {
        switch self {
        case .all: return "全部"
        case .cn: return "A股"
        case .hk: return "港股"
        case .us: return "美股"
        case .global: return "期货外汇"
        case .holdings: return "持仓"
        case .group(let name): return name
        }
    }
}

/// 列表每一行右边色块里显示什么，点一下色块依次切换。
enum ChangeDisplay: String, CaseIterable, Identifiable {
    case percent, change, marketCap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percent: return "涨跌幅"
        case .change: return "涨跌额"
        case .marketCap: return "总市值"
        }
    }

    var next: ChangeDisplay {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

/// 展开详情里走势图的周期。
enum ChartPeriod: String, CaseIterable, Identifiable {
    case intraday, fiveDay, day, week, month
    /// 买卖五档，只有 A 股有。
    case orderBook
    /// 资金流向，只有 A 股个股和 ETF 有。
    case fundFlow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .intraday: return "分时"
        case .fiveDay: return "五日"
        case .day: return "日K"
        case .week: return "周K"
        case .month: return "月K"
        case .orderBook: return "五档"
        case .fundFlow: return "资金"
        }
    }

    /// K 线的周期；分时图、五档、资金为 nil。
    var klinePeriod: KlinePeriod? {
        switch self {
        case .intraday, .fiveDay, .orderBook, .fundFlow: return nil
        case .day: return .day
        case .week: return .week
        case .month: return .month
        }
    }

    /// 这只能看的几项：没有五档的（港股、美股、指数）不列五档，只有 A 股个股和 ETF 列资金。
    static func available(for quote: Quote?) -> [ChartPeriod] {
        allCases.filter { period in
            switch period {
            case .orderBook: return quote?.orderBook != nil
            case .fundFlow: return quote.map { TencentFundFlow.supports($0.symbol) } ?? false
            default: return true
            }
        }
    }

    /// 实际显示的一项：选了五档、资金而这只没有时看分时。
    func effective(for quote: Quote?) -> ChartPeriod {
        Self.available(for: quote).contains(self) ? self : .intraday
    }

    /// 左右方向键切换：到头了不循环，跳过这只没有的。
    func moved(by step: Int, for quote: Quote?) -> ChartPeriod {
        let all = Self.available(for: quote)
        let index = all.firstIndex(of: effective(for: quote)) ?? 0
        return all[min(max(index + step, 0), all.count - 1)]
    }
}

/// 面板和设置窗口的深浅色。菜单栏始终跟随系统。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 用户偏好，全部保存在 UserDefaults。标注“同步”的会通过 iCloud 同步到其他 Mac。
@MainActor
final class SettingsStore: ObservableObject {
    static let intervalOptions: [Double] = [3, 5, 10, 30, 60]

    private let defaults: UserDefaults

    /// 需要同步的设置变了（由 SyncManager 设置）。
    var onSyncedSettingChange: (() -> Void)?

    // 同步
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval); onSyncedSettingChange?() }
    }
    @Published var slowWhenIdle: Bool {
        didSet { defaults.set(slowWhenIdle, forKey: Keys.slowWhenIdle); onSyncedSettingChange?() }
    }
    @Published var colorConvention: ColorConvention {
        didSet { defaults.set(colorConvention.rawValue, forKey: Keys.colorConvention); onSyncedSettingChange?() }
    }
    @Published var showName: Bool {
        didSet { defaults.set(showName, forKey: Keys.showName); onSyncedSettingChange?() }
    }
    @Published var showPrice: Bool {
        didSet { defaults.set(showPrice, forKey: Keys.showPrice); onSyncedSettingChange?() }
    }
    @Published var showPercent: Bool {
        didSet { defaults.set(showPercent, forKey: Keys.showPercent); onSyncedSettingChange?() }
    }
    /// 固定了多只证券时，菜单栏每 5 秒轮流显示一只，节省刘海屏的空间。
    @Published var rotateTicker: Bool {
        didSet { defaults.set(rotateTicker, forKey: Keys.rotateTicker); onSyncedSettingChange?() }
    }
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Keys.alertsEnabled); onSyncedSettingChange?() }
    }

    // 只和这台 Mac 有关，不同步
    /// 有持仓的市场收盘后发一条今日盈亏小结。不同步，免得几台 Mac 各发一遍。
    @Published var closeSummary: Bool {
        didSet { defaults.set(closeSummary, forKey: Keys.closeSummary) }
    }
    /// 自选里的 A 股个股封涨停、跌停时提醒。只在本机，不同步。
    @Published var limitAlerts: Bool {
        didSet { defaults.set(limitAlerts, forKey: Keys.limitAlerts) }
    }
    /// 自选里的证券创 52 周新高、新低时提醒。只在本机，不同步。
    @Published var yearHighLowAlerts: Bool {
        didSet { defaults.set(yearHighLowAlerts, forKey: Keys.yearHighLowAlerts) }
    }
    /// 异动提醒：几分钟内涨跌超过这个幅度（%）时提醒；0 是关闭。只在本机。
    @Published var rapidMoveThreshold: Double {
        didSet { defaults.set(rapidMoveThreshold, forKey: Keys.rapidMoveThreshold) }
    }
    static let rapidMoveOptions: [Double] = [0, 1, 2, 3, 5]
    /// 菜单栏只显示图标（右键单击菜单栏图标切换）。
    @Published var hideTicker: Bool {
        didSet { defaults.set(hideTicker, forKey: Keys.hideTicker) }
    }
    /// 菜单栏上的市场都休市时只显示图标，开盘后自动恢复。
    @Published var hideTickerWhenClosed: Bool {
        didSet { defaults.set(hideTickerWhenClosed, forKey: Keys.hideTickerWhenClosed) }
    }
    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }
    /// 打开或关闭面板的全局快捷键，默认 ⌃⌥S。
    @Published var toggleHotkey: HotkeyBinding {
        didSet {
            if let data = try? JSONEncoder().encode(toggleHotkey) {
                defaults.set(data, forKey: Keys.toggleHotkey)
            }
        }
    }
    /// 快捷键已经被其他程序占用、没注册上。不保存，由 AppDelegate 在注册后设置。
    @Published var hotkeyUnavailable = false
    @Published var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }
    @Published var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: Keys.syncEnabled) }
    }
    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    /// 列表的排序方式。
    @Published var sortMode: WatchlistSort {
        didSet { defaults.set(sortMode.rawValue, forKey: Keys.sortMode) }
    }
    /// 列表上方选的筛选：全部、某个市场、持仓或某个分组。
    @Published var listFilter: WatchlistFilter {
        didSet { defaults.set(listFilter.id, forKey: Keys.listFilter) }
    }
    /// 列表右边色块里显示涨跌幅、涨跌额还是总市值。
    @Published var changeDisplay: ChangeDisplay {
        didSet { defaults.set(changeDisplay.rawValue, forKey: Keys.changeDisplay) }
    }
    /// 价格变动时让价格闪一下。
    @Published var flashOnChange: Bool {
        didSet { defaults.set(flashOnChange, forKey: Keys.flashOnChange) }
    }
    /// 持仓合计下面展开了盈亏记录。
    @Published var showProfitHistory: Bool {
        didSet { defaults.set(showProfitHistory, forKey: Keys.showProfitHistory) }
    }
    /// 持仓合计下面展开了持仓分布。
    @Published var showAllocation: Bool {
        didSet { defaults.set(showAllocation, forKey: Keys.showAllocation) }
    }
    /// 隐藏金额：面板、菜单栏和通知里的市值、盈亏金额、持有数量换成 ****，比例照常显示。只在这台 Mac 上，不同步。
    @Published var hideAmounts: Bool {
        didSet { defaults.set(hideAmounts, forKey: Keys.hideAmounts) }
    }
    /// 紧凑列表：每只一行，名称、代码、现价和色块排在一起，一屏能看到更多。
    @Published var compactRows: Bool {
        didSet { defaults.set(compactRows, forKey: Keys.compactRows) }
    }
    /// 列表里每一行画一条当天的迷你分时（紧凑列表不画）。
    @Published var showSparklines: Bool {
        didSet { defaults.set(showSparklines, forKey: Keys.showSparklines) }
    }
    /// K 线上画 5、10、20 根的收盘价均线，分时图上画成交均价。
    @Published var showMovingAverages: Bool {
        didSet { defaults.set(showMovingAverages, forKey: Keys.showMovingAverages) }
    }
    /// 有持仓的在分时图、K 线上画成本线，K 线上标出记过买卖的那几根。
    @Published var showCostAndTrades: Bool {
        didSet { defaults.set(showCostAndTrades, forKey: Keys.showCostAndTrades) }
    }
    /// 涨跌榜上次看的是哪个榜。
    @Published var rankKind: RankKind {
        didSet { defaults.set(rankKind.rawValue, forKey: Keys.rankKind) }
    }
    /// 涨跌榜上不列新股（N、C 开头的）。
    @Published var rankHidesNewListings: Bool {
        didSet { defaults.set(rankHidesNewListings, forKey: Keys.rankHidesNewListings) }
    }
    /// 美股个股不在常规交易时段时显示盘前盘后价。
    @Published var showExtendedHours: Bool {
        didSet { defaults.set(showExtendedHours, forKey: Keys.showExtendedHours) }
    }
    /// 菜单栏里显示今日盈亏（按货币分别显示，只算填了持仓的）。
    @Published var showDayProfit: Bool {
        didSet { defaults.set(showDayProfit, forKey: Keys.showDayProfit) }
    }
    /// 菜单栏上显示今日盈亏还是持仓盈亏（打开了 showDayProfit 时）。
    @Published var menuBarProfit: MenuBarProfit {
        didSet { defaults.set(menuBarProfit.rawValue, forKey: Keys.menuBarProfit) }
    }
    /// 面板钉住：点别处时不关闭，可以拖到任何位置。
    @Published var panelPinned: Bool {
        didSet { defaults.set(panelPinned, forKey: Keys.panelPinned) }
    }
    /// 钉住时面板左上角的位置（屏幕坐标），下次打开放回这里。
    var pinnedTopLeft: CGPoint? {
        get {
            guard defaults.object(forKey: Keys.pinnedX) != nil, defaults.object(forKey: Keys.pinnedY) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: Keys.pinnedX), y: defaults.double(forKey: Keys.pinnedY))
        }
        set {
            if let newValue {
                defaults.set(Double(newValue.x), forKey: Keys.pinnedX)
                defaults.set(Double(newValue.y), forKey: Keys.pinnedY)
            } else {
                defaults.removeObject(forKey: Keys.pinnedX)
                defaults.removeObject(forKey: Keys.pinnedY)
            }
        }
    }
    /// 展开详情时显示分时还是 K 线，记住上次选的。
    @Published var chartPeriod: ChartPeriod {
        didSet { defaults.set(chartPeriod.rawValue, forKey: Keys.chartPeriod) }
    }
    /// 第一次打开面板时的使用提示，看过就不再显示。
    @Published var tipsDismissed: Bool {
        didSet { defaults.set(tipsDismissed, forKey: Keys.tipsDismissed) }
    }
    /// 刚更新到的版本，面板里显示“已更新到 x.y.z”，关掉后清空。
    @Published var whatsNewVersion: String? {
        didSet { defaults.set(whatsNewVersion, forKey: Keys.whatsNewVersion) }
    }
    /// 是从哪个版本更新到 whatsNewVersion 的：隔了几个版本时，“已更新”里列出中间每个版本的更新内容。
    @Published var whatsNewSince: String? {
        didSet { defaults.set(whatsNewSince, forKey: Keys.whatsNewSince) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.object(forKey: Keys.refreshInterval) as? Double ?? 5
        refreshInterval = Self.intervalOptions.contains(interval) ? interval : 5
        slowWhenIdle = defaults.object(forKey: Keys.slowWhenIdle) as? Bool ?? true
        colorConvention = defaults.string(forKey: Keys.colorConvention).flatMap(ColorConvention.init(rawValue:)) ?? .redUp
        showName = defaults.object(forKey: Keys.showName) as? Bool ?? true
        showPrice = defaults.object(forKey: Keys.showPrice) as? Bool ?? true
        showPercent = defaults.object(forKey: Keys.showPercent) as? Bool ?? true
        rotateTicker = defaults.object(forKey: Keys.rotateTicker) as? Bool ?? false
        alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? true
        closeSummary = defaults.object(forKey: Keys.closeSummary) as? Bool ?? false
        limitAlerts = defaults.object(forKey: Keys.limitAlerts) as? Bool ?? false
        yearHighLowAlerts = defaults.object(forKey: Keys.yearHighLowAlerts) as? Bool ?? false
        let rapid = defaults.object(forKey: Keys.rapidMoveThreshold) as? Double ?? 0
        rapidMoveThreshold = Self.rapidMoveOptions.contains(rapid) ? rapid : 0
        hideTicker = defaults.object(forKey: Keys.hideTicker) as? Bool ?? false
        hideTickerWhenClosed = defaults.object(forKey: Keys.hideTickerWhenClosed) as? Bool ?? false
        hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        toggleHotkey = defaults.data(forKey: Keys.toggleHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) } ?? .defaultToggle
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        syncEnabled = defaults.object(forKey: Keys.syncEnabled) as? Bool ?? false
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        sortMode = defaults.string(forKey: Keys.sortMode).flatMap(WatchlistSort.init(rawValue:)) ?? .custom
        listFilter = defaults.string(forKey: Keys.listFilter).flatMap(WatchlistFilter.init(id:)) ?? .all
        changeDisplay = defaults.string(forKey: Keys.changeDisplay).flatMap(ChangeDisplay.init(rawValue:)) ?? .percent
        flashOnChange = defaults.object(forKey: Keys.flashOnChange) as? Bool ?? true
        showMovingAverages = defaults.object(forKey: Keys.showMovingAverages) as? Bool ?? true
        showCostAndTrades = defaults.object(forKey: Keys.showCostAndTrades) as? Bool ?? true
        rankKind = defaults.string(forKey: Keys.rankKind).flatMap(RankKind.init(rawValue:)) ?? .gainers
        rankHidesNewListings = defaults.object(forKey: Keys.rankHidesNewListings) as? Bool ?? true
        compactRows = defaults.object(forKey: Keys.compactRows) as? Bool ?? false
        showSparklines = defaults.object(forKey: Keys.showSparklines) as? Bool ?? true
        showAllocation = defaults.object(forKey: Keys.showAllocation) as? Bool ?? false
        hideAmounts = defaults.object(forKey: Keys.hideAmounts) as? Bool ?? false
        showProfitHistory = defaults.object(forKey: Keys.showProfitHistory) as? Bool ?? false
        showExtendedHours = defaults.object(forKey: Keys.showExtendedHours) as? Bool ?? true
        showDayProfit = defaults.object(forKey: Keys.showDayProfit) as? Bool ?? false
        menuBarProfit = defaults.string(forKey: Keys.menuBarProfit).flatMap(MenuBarProfit.init(rawValue:)) ?? .day
        panelPinned = defaults.object(forKey: Keys.panelPinned) as? Bool ?? false
        chartPeriod = defaults.string(forKey: Keys.chartPeriod).flatMap(ChartPeriod.init(rawValue:)) ?? .intraday
        tipsDismissed = defaults.object(forKey: Keys.tipsDismissed) as? Bool ?? false
        whatsNewVersion = defaults.string(forKey: Keys.whatsNewVersion)
        whatsNewSince = defaults.string(forKey: Keys.whatsNewSince)
    }

    /// 启动时记下这次运行的版本；比上次运行的新，就在面板里提示一次“已更新”。
    func recordLaunch(version: String) {
        if let last = defaults.string(forKey: Keys.lastRunVersion), UpdateCheck.isNewer(version, than: last) {
            // 上一次的提示还没关就又更新了：从更早的那个版本算起。
            if whatsNewVersion == nil || whatsNewSince == nil {
                whatsNewSince = last
            }
            whatsNewVersion = version
        }
        defaults.set(version, forKey: Keys.lastRunVersion)
    }

    var tickerOptions: TickerOptions {
        TickerOptions(showName: showName, showPrice: showPrice, showPercent: showPercent)
    }

    /// 需要同步的设置。
    var syncedSettings: SyncedSettings {
        SyncedSettings(
            refreshInterval: refreshInterval,
            slowWhenIdle: slowWhenIdle,
            colorScheme: colorConvention.rawValue,
            showName: showName,
            showPrice: showPrice,
            showPercent: showPercent,
            rotateTicker: rotateTicker,
            alertsEnabled: alertsEnabled
        )
    }

    /// 应用从 iCloud 来的设置；缺少或不认识的值保留本机的。
    func apply(_ synced: SyncedSettings) {
        if let value = synced.refreshInterval, Self.intervalOptions.contains(value), value != refreshInterval {
            refreshInterval = value
        }
        if let value = synced.slowWhenIdle, value != slowWhenIdle { slowWhenIdle = value }
        if let value = synced.colorScheme.flatMap(ColorConvention.init(rawValue:)), value != colorConvention {
            colorConvention = value
        }
        if let value = synced.showName, value != showName { showName = value }
        if let value = synced.showPrice, value != showPrice { showPrice = value }
        if let value = synced.showPercent, value != showPercent { showPercent = value }
        if let value = synced.rotateTicker, value != rotateTicker { rotateTicker = value }
        if let value = synced.alertsEnabled, value != alertsEnabled { alertsEnabled = value }
    }

    private enum Keys {
        static let refreshInterval = "refreshInterval"
        static let slowWhenIdle = "slowWhenIdle"
        static let colorConvention = "colorConvention"
        static let showName = "ticker.showName"
        static let showPrice = "ticker.showPrice"
        static let showPercent = "ticker.showPercent"
        static let rotateTicker = "ticker.rotate"
        static let hideTicker = "ticker.hidden"
        static let hideTickerWhenClosed = "ticker.hideWhenClosed"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let toggleHotkey = "hotkey.toggle"
        static let alertsEnabled = "alertsEnabled"
        static let closeSummary = "alerts.closeSummary"
        static let limitAlerts = "alerts.limit"
        static let yearHighLowAlerts = "alerts.yearHighLow"
        static let rapidMoveThreshold = "alerts.rapid"
        static let autoCheckUpdates = "update.autoCheck"
        static let syncEnabled = "sync.enabled"
        static let appearance = "appearance"
        static let sortMode = "list.sort"
        static let listFilter = "list.filter"
        static let changeDisplay = "list.pill"
        static let flashOnChange = "list.flash"
        static let showMovingAverages = "chart.movingAverages"
        static let showCostAndTrades = "chart.costAndTrades"
        static let rankKind = "rank.kind"
        static let rankHidesNewListings = "rank.hideNew"
        static let compactRows = "list.compact"
        static let showSparklines = "list.sparklines"
        static let showAllocation = "holdings.allocation"
        static let hideAmounts = "holdings.hideAmounts"
        static let showProfitHistory = "holdings.history"
        static let showExtendedHours = "list.extendedHours"
        static let showDayProfit = "ticker.dayProfit"
        static let menuBarProfit = "ticker.profitKind"
        static let panelPinned = "panel.pinned"
        static let pinnedX = "panel.pinnedX"
        static let pinnedY = "panel.pinnedY"
        static let chartPeriod = "chart.period"
        static let tipsDismissed = "tips.dismissed"
        static let whatsNewVersion = "update.whatsNew"
        static let whatsNewSince = "update.whatsNewSince"
        static let lastRunVersion = "app.lastVersion"
    }
}
