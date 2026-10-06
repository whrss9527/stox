import Foundation

/// 系统给 Stox 的通知权限，App 从 UNUserNotificationCenter 读出来。
public enum NotificationPermission: String, Sendable, CaseIterable {
    /// 还没读到：刚启动，或者不是从 .app 运行。
    case unknown
    /// 还没问过：打开提醒时系统会弹出询问。
    case notDetermined
    /// 第一次问时点了不允许，或者后来在系统设置里关掉了“允许通知”：提醒都发不出来。
    case denied
    /// 允许（含临时授权）。
    case authorized
}

/// 哪些要发通知的功能开着，对应设置里的几个开关。
public struct NotificationNeeds: Sendable, Equatable {
    /// “到价时发送系统通知”：每只单独设的价格提醒、止盈止损，以及涨跌停、52 周新高新低和异动提醒都靠它。
    public var alertsEnabled: Bool
    public var limitAlerts: Bool
    public var yearAlerts: Bool
    public var rapidMoves: Bool
    /// 收盘小结不受“到价时发送系统通知”管。
    public var closeSummary: Bool

    public init(
        alertsEnabled: Bool = true, limitAlerts: Bool = false, yearAlerts: Bool = false, rapidMoves: Bool = false,
        closeSummary: Bool = false
    ) {
        self.alertsEnabled = alertsEnabled
        self.limitAlerts = limitAlerts
        self.yearAlerts = yearAlerts
        self.rapidMoves = rapidMoves
        self.closeSummary = closeSummary
    }

    /// 自选里有没有开着、到时候要发通知的提醒。和真正发通知的条件一样（见 AlertEngine.evaluate、QuoteStore）：
    /// 价格提醒要有一只设了条件，涨跌停要有 A 股个股，52 周新高新低和异动要自选不是空的，收盘小结要有持仓。
    public func hasActiveAlerts(in items: [WatchItem]) -> Bool {
        if closeSummary, items.contains(where: { $0.symbol.canHold && $0.holding?.isValid == true }) {
            return true
        }
        guard alertsEnabled, !items.isEmpty else { return false }
        if items.contains(where: { !$0.alert.isEmpty }) { return true }
        if limitAlerts, items.contains(where: { [.sh, .sz, .bj].contains($0.symbol.market) && !$0.symbol.isIndex }) { return true }
        return yearAlerts || rapidMoves
    }

    /// 面板里要不要提示“通知已关闭”：系统拒绝了，而且有开着的提醒。没开提醒的人不打扰。
    public func shouldWarn(_ permission: NotificationPermission, items: [WatchItem]) -> Bool {
        permission == .denied && hasActiveAlerts(in: items)
    }
}
