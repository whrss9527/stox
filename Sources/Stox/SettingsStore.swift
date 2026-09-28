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
        case .holdings: return "持仓"
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .intraday: return "分时"
        case .fiveDay: return "五日"
        case .day: return "日K"
        case .week: return "周K"
        case .month: return "月K"
        }
    }

    /// K 线的周期；分时图为 nil。
    var klinePeriod: KlinePeriod? {
        switch self {
        case .intraday, .fiveDay: return nil
        case .day: return .day
        case .week: return .week
        case .month: return .month
        }
    }

    /// 左右方向键切换：到头了不循环。
    func moved(by step: Int) -> ChartPeriod {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
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
    /// 菜单栏只显示图标（右键单击菜单栏图标切换）。
    @Published var hideTicker: Bool {
        didSet { defaults.set(hideTicker, forKey: Keys.hideTicker) }
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
    /// 列表上方选的筛选：全部、某个市场或持仓。
    @Published var listFilter: WatchlistFilter {
        didSet { defaults.set(listFilter.rawValue, forKey: Keys.listFilter) }
    }
    /// 列表右边色块里显示涨跌幅、涨跌额还是总市值。
    @Published var changeDisplay: ChangeDisplay {
        didSet { defaults.set(changeDisplay.rawValue, forKey: Keys.changeDisplay) }
    }
    /// 价格变动时让价格闪一下。
    @Published var flashOnChange: Bool {
        didSet { defaults.set(flashOnChange, forKey: Keys.flashOnChange) }
    }
    /// 菜单栏里显示今日盈亏（按货币分别显示，只算填了持仓的）。
    @Published var showDayProfit: Bool {
        didSet { defaults.set(showDayProfit, forKey: Keys.showDayProfit) }
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
        hideTicker = defaults.object(forKey: Keys.hideTicker) as? Bool ?? false
        hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        toggleHotkey = defaults.data(forKey: Keys.toggleHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) } ?? .defaultToggle
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        syncEnabled = defaults.object(forKey: Keys.syncEnabled) as? Bool ?? false
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        sortMode = defaults.string(forKey: Keys.sortMode).flatMap(WatchlistSort.init(rawValue:)) ?? .custom
        listFilter = defaults.string(forKey: Keys.listFilter).flatMap(WatchlistFilter.init(rawValue:)) ?? .all
        changeDisplay = defaults.string(forKey: Keys.changeDisplay).flatMap(ChangeDisplay.init(rawValue:)) ?? .percent
        flashOnChange = defaults.object(forKey: Keys.flashOnChange) as? Bool ?? true
        showDayProfit = defaults.object(forKey: Keys.showDayProfit) as? Bool ?? false
        panelPinned = defaults.object(forKey: Keys.panelPinned) as? Bool ?? false
        chartPeriod = defaults.string(forKey: Keys.chartPeriod).flatMap(ChartPeriod.init(rawValue:)) ?? .intraday
        tipsDismissed = defaults.object(forKey: Keys.tipsDismissed) as? Bool ?? false
        whatsNewVersion = defaults.string(forKey: Keys.whatsNewVersion)
    }

    /// 启动时记下这次运行的版本；比上次运行的新，就在面板里提示一次“已更新”。
    func recordLaunch(version: String) {
        if let last = defaults.string(forKey: Keys.lastRunVersion), UpdateCheck.isNewer(version, than: last) {
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
        static let hotKeyEnabled = "hotKeyEnabled"
        static let toggleHotkey = "hotkey.toggle"
        static let alertsEnabled = "alertsEnabled"
        static let closeSummary = "alerts.closeSummary"
        static let autoCheckUpdates = "update.autoCheck"
        static let syncEnabled = "sync.enabled"
        static let appearance = "appearance"
        static let sortMode = "list.sort"
        static let listFilter = "list.filter"
        static let changeDisplay = "list.pill"
        static let flashOnChange = "list.flash"
        static let showDayProfit = "ticker.dayProfit"
        static let panelPinned = "panel.pinned"
        static let pinnedX = "panel.pinnedX"
        static let pinnedY = "panel.pinnedY"
        static let chartPeriod = "chart.period"
        static let tipsDismissed = "tips.dismissed"
        static let whatsNewVersion = "update.whatsNew"
        static let lastRunVersion = "app.lastVersion"
    }
}
