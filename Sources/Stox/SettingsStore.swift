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
        hideTicker = defaults.object(forKey: Keys.hideTicker) as? Bool ?? false
        hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        toggleHotkey = defaults.data(forKey: Keys.toggleHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) } ?? .defaultToggle
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        syncEnabled = defaults.object(forKey: Keys.syncEnabled) as? Bool ?? false
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
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
        static let autoCheckUpdates = "update.autoCheck"
        static let syncEnabled = "sync.enabled"
        static let appearance = "appearance"
    }
}
