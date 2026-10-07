import Foundation

public enum MarketPhase: Sendable, Equatable {
    case preMarket, trading, lunchBreak, afterHours, closed

    public var displayName: String {
        switch self {
        case .preMarket: return L("盘前")
        case .trading: return L("交易中")
        case .lunchBreak: return L("午休")
        case .afterHours: return L("盘后")
        case .closed: return L("休市")
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
        case .global:
            // 工作日全天，哪天开哪天收见 globalPhase。
            return [Session(start: 0, end: 24 * 60, phase: .trading)]
        }
    }

    /// 首个连续交易时段开始的时间（分钟）。
    static func regularOpen(for region: MarketRegion) -> Int {
        sessions(for: region).first(where: { $0.phase == .trading })?.start ?? 0
    }

    /// 仅按时间表判断的交易时段。
    public static func phase(for region: MarketRegion, at date: Date) -> MarketPhase {
        if region == .global { return globalPhase(at: date) }
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
        if region == .global {
            // 期货外汇只在圣诞、元旦这样的节日休市：该开着的时候最新的行情已经是几个小时以前的，就是休市
            // （每天纽约时间 17 点期货有一小时休息，不算）。
            guard scheduled == .trading, let latest = latestQuoteTime else { return scheduled }
            return date.timeIntervalSince(latest) > globalStaleInterval ? .closed : scheduled
        }
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

extension MarketClock {
    /// 期货外汇的行情停了这么久（秒），按时间表该开着也当休市。
    static let globalStaleInterval: TimeInterval = 3 * 3600

    /// 期货外汇的交易时段：纽约时间周日 18:00 开盘，一直到周五 17:00 收盘，中间不分时段。
    /// 外汇早一个小时开盘，期货每天 17:00 到 18:00 休息一小时，这些都不细分。
    static func globalPhase(at date: Date) -> MarketPhase {
        let calendar = MarketRegion.us.calendar
        let hour = calendar.component(.hour, from: date)
        switch calendar.component(.weekday, from: date) {
        case 7: return .closed  // 周六
        case 1: return hour >= 18 ? .trading : .closed  // 周日晚上开盘
        case 6: return hour < 17 ? .trading : .closed  // 周五下午收盘
        default: return .trading
        }
    }
}

public enum RefreshPolicy {
    /// 所有关注的市场都不在交易时，刷新间隔放宽到至少这么多秒。
    public static let idleInterval: TimeInterval = 60

    /// 连续失败后翻倍，最多一分钟；成功时回到正常轮询间隔。
    public static func failureInterval(base: TimeInterval, failures: Int) -> TimeInterval {
        guard failures > 0 else { return max(base, 1) }
        return min(60, max(base, 1) * pow(2, Double(min(failures, 6))))
    }

    public static func interval(base: TimeInterval, phases: [MarketPhase], slowWhenIdle: Bool) -> TimeInterval {
        let base = max(base, 1)
        guard slowWhenIdle else { return base }
        return phases.contains(where: \.isLive) ? base : max(base, idleInterval)
    }
}

/// 两个行情源都失败后的退避；成功或网络恢复后归零。
public struct QuoteRetryBackoff: Equatable, Sendable {
    public private(set) var failures = 0
    public init() {}
    public mutating func failed() { failures = min(failures + 1, 6) }
    public mutating func reset() { failures = 0 }

    public func interval(base: TimeInterval) -> TimeInterval {
        RefreshPolicy.failureInterval(base: base, failures: failures)
    }
}
