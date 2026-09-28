import Foundation

/// 交易所。rawValue 与腾讯行情接口的代码前缀一致（sh600519、hk00700、usAAPL）。
public enum Market: String, Codable, CaseIterable, Sendable {
    case sh, sz, bj, hk, us

    public var region: MarketRegion {
        switch self {
        case .sh, .sz, .bj: return .cn
        case .hk: return .hk
        case .us: return .us
        }
    }

    /// 列表里显示的单字市场标签。
    public var label: String {
        switch self {
        case .sh: return "沪"
        case .sz: return "深"
        case .bj: return "北"
        case .hk: return "港"
        case .us: return "美"
        }
    }
}

/// 交易时段相同的一组市场：A 股（沪深北）、港股、美股。
public enum MarketRegion: String, Codable, CaseIterable, Sendable {
    case cn, hk, us

    public var displayName: String {
        switch self {
        case .cn: return "A股"
        case .hk: return "港股"
        case .us: return "美股"
        }
    }

    public var timeZone: TimeZone {
        switch self {
        case .cn: return TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        case .hk: return TimeZone(identifier: "Asia/Hong_Kong") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        case .us: return TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!
        }
    }

    public var currency: String {
        switch self {
        case .cn: return "CNY"
        case .hk: return "HKD"
        case .us: return "USD"
        }
    }

    /// 以该市场当地时区计算日期的公历。
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
