import Foundation
import StoxCore

enum ColorConvention: String, CaseIterable, Identifiable {
    case redUp, greenUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .redUp: return "红涨绿跌"
        case .greenUp: return "绿涨红跌"
        }
    }
}

/// 用户偏好，全部保存在 UserDefaults。
@MainActor
final class SettingsStore: ObservableObject {
    static let intervalOptions: [Double] = [3, 5, 10, 30, 60]

    private let defaults: UserDefaults

    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }
    @Published var slowWhenIdle: Bool {
        didSet { defaults.set(slowWhenIdle, forKey: Keys.slowWhenIdle) }
    }
    @Published var colorConvention: ColorConvention {
        didSet { defaults.set(colorConvention.rawValue, forKey: Keys.colorConvention) }
    }
    @Published var showName: Bool {
        didSet { defaults.set(showName, forKey: Keys.showName) }
    }
    @Published var showPrice: Bool {
        didSet { defaults.set(showPrice, forKey: Keys.showPrice) }
    }
    @Published var showPercent: Bool {
        didSet { defaults.set(showPercent, forKey: Keys.showPercent) }
    }
    /// 固定了多只证券时，菜单栏每 5 秒轮流显示一只，节省刘海屏的空间。
    @Published var rotateTicker: Bool {
        didSet { defaults.set(rotateTicker, forKey: Keys.rotateTicker) }
    }
    /// 临时隐藏菜单栏行情，只显示图标。
    @Published var hideTicker: Bool {
        didSet { defaults.set(hideTicker, forKey: Keys.hideTicker) }
    }
    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Keys.alertsEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.object(forKey: Keys.refreshInterval) as? Double ?? 5
        refreshInterval = Self.intervalOptions.contains(interval) ? interval : 5
        slowWhenIdle = defaults.object(forKey: Keys.slowWhenIdle) as? Bool ?? true
        colorConvention = (defaults.string(forKey: Keys.colorConvention)).flatMap(ColorConvention.init(rawValue:)) ?? .redUp
        showName = defaults.object(forKey: Keys.showName) as? Bool ?? true
        showPrice = defaults.object(forKey: Keys.showPrice) as? Bool ?? true
        showPercent = defaults.object(forKey: Keys.showPercent) as? Bool ?? true
        rotateTicker = defaults.object(forKey: Keys.rotateTicker) as? Bool ?? false
        hideTicker = defaults.object(forKey: Keys.hideTicker) as? Bool ?? false
        hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? true
    }

    var tickerOptions: TickerOptions {
        TickerOptions(showName: showName, showPrice: showPrice, showPercent: showPercent)
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
        static let alertsEnabled = "alertsEnabled"
    }
}
