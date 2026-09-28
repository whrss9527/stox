import Foundation

public enum MarketPhase: Sendable, Equatable {
    case preMarket, trading, lunchBreak, afterHours, closed

    public var displayName: String {
        switch self {
        case .preMarket: return "盘前"
        case .trading: return "交易中"
        case .lunchBreak: return "午休"
        case .afterHours: return "盘后"
        case .closed: return "休市"
        }
    }

    /// 价格还可能变动的时段，按设置的间隔刷新。
    public var isLive: Bool {
        switch self {
        case .preMarket, .trading, .afterHours: return true
        case .lunchBreak, .closed: return false
        }
    }
}

/// 按交易所当地时间判断交易时段。不含节假日日历，节假日由 `effectivePhase` 借助行情时间识别。
public enum MarketClock {
    struct Session {
        let start: Int  // 当地时间，自零点起的分钟数
        let end: Int
        let phase: MarketPhase
    }

    static func sessions(for region: MarketRegion) -> [Session] {
        switch region {
        case .cn:
            return [
                Session(start: 9 * 60 + 15, end: 9 * 60 + 30, phase: .preMarket),  // 集合竞价
                Session(start: 9 * 60 + 30, end: 11 * 60 + 30, phase: .trading),
                Session(start: 11 * 60 + 30, end: 13 * 60, phase: .lunchBreak),
                Session(start: 13 * 60, end: 15 * 60, phase: .trading),
            ]
        case .hk:
            return [
                Session(start: 9 * 60, end: 9 * 60 + 30, phase: .preMarket),  // 开市前时段
                Session(start: 9 * 60 + 30, end: 12 * 60, phase: .trading),
                Session(start: 12 * 60, end: 13 * 60, phase: .lunchBreak),
                Session(start: 13 * 60, end: 16 * 60 + 10, phase: .trading),  // 含收市竞价
            ]
        case .us:
            return [
                Session(start: 4 * 60, end: 9 * 60 + 30, phase: .preMarket),
                Session(start: 9 * 60 + 30, end: 16 * 60, phase: .trading),
                Session(start: 16 * 60, end: 20 * 60, phase: .afterHours),
            ]
        }
    }

    /// 首个连续交易时段开始的时间（分钟）。
    static func regularOpen(for region: MarketRegion) -> Int {
        sessions(for: region).first(where: { $0.phase == .trading })?.start ?? 0
    }

    /// 仅按时间表判断的交易时段。
    public static func phase(for region: MarketRegion, at date: Date) -> MarketPhase {
        let calendar = region.calendar
        let weekday = calendar.component(.weekday, from: date)
        guard weekday != 1, weekday != 7 else { return .closed }  // 周日、周六
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return sessions(for: region).first(where: { minutes >= $0.start && minutes < $0.end })?.phase ?? .closed
    }

    /// 结合最新行情时间修正交易时段：按时间表应在交易，但当天还没有任何行情，说明是节假日休市。
    ///
    /// - Parameter latestQuoteTime: 该市场所有行情里最新的时间戳。
    public static func effectivePhase(for region: MarketRegion, at date: Date, latestQuoteTime: Date?) -> MarketPhase {
        let scheduled = phase(for: region, at: date)
        guard scheduled == .trading || scheduled == .lunchBreak, let latest = latestQuoteTime else { return scheduled }
        let calendar = region.calendar
        if calendar.isDate(latest, inSameDayAs: date) { return scheduled }
        // 开盘后留一段宽限期，港股行情本身有约 15 分钟延时。
        let grace = region == .hk ? 20 : 5
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minutes >= regularOpen(for: region) + grace ? .closed : scheduled
    }
}

public enum RefreshPolicy {
    /// 所有关注的市场都不在交易时，刷新间隔放宽到至少这么多秒。
    public static let idleInterval: TimeInterval = 60

    public static func interval(base: TimeInterval, phases: [MarketPhase], slowWhenIdle: Bool) -> TimeInterval {
        let base = max(base, 1)
        guard slowWhenIdle else { return base }
        return phases.contains(where: \.isLive) ? base : max(base, idleInterval)
    }
}
