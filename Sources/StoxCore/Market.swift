import Foundation

/// 交易所。rawValue 与腾讯行情接口的代码前缀一致（sh600519、hk00700、usAAPL）。
/// jj 是场外基金（jj161725），不在交易所交易，每个交易日晚上公布一次净值，算在 A 股里（人民币）。
/// hf 是国际期货和贵金属现货（hf_XAU 伦敦金、hf_CL 纽约原油），wh 是外汇（whUSDCNY），
/// zn 是环球股指（znb_NKY 日经225、znb_UKX 英国富时100，腾讯没有，用新浪的代码和行情），都算在“环球”里。
public enum Market: String, Codable, CaseIterable, Sendable {
    case sh, sz, bj, hk, us, jj, hf, wh, zn

    public var region: MarketRegion {
        switch self {
        case .sh, .sz, .bj, .jj: return .cn
        case .hk: return .hk
        case .us: return .us
        case .hf, .wh, .zn: return .global
        }
    }

    /// 列表里显示的单字市场标签。
    public var label: String {
        switch self {
        case .sh: return L("沪")
        case .sz: return L("深")
        case .bj: return L("北")
        case .hk: return L("港")
        case .us: return L("美")
        case .jj: return L("基")
        case .hf: return L("期")
        case .wh: return L("汇")
        case .zn: return L("指")
        }
    }
}

/// 交易时段相同的一组市场：A 股（沪深北）、港股、美股，以及环球（期货外汇和环球股指）。
/// 环球工作日几乎全天都在交易，不能填持仓，时间按北京时间算（行情接口给的就是北京时间）。
public enum MarketRegion: String, Codable, CaseIterable, Sendable {
    case cn, hk, us, global

    public var displayName: String {
        switch self {
        case .cn: return L("A股")
        case .hk: return L("港股")
        case .us: return L("美股")
        case .global: return L("环球")
        }
    }

    public var timeZone: TimeZone {
        switch self {
        case .cn: return TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        case .hk: return TimeZone(identifier: "Asia/Hong_Kong") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        case .us: return TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!
        case .global: return TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        }
    }

    public var currency: String {
        switch self {
        case .cn: return "CNY"
        case .hk: return "HKD"
        // 期货外汇不能填持仓，用不到；报价大多是美元。
        case .us, .global: return "USD"
        }
    }

    /// 以该市场当地时区计算日期的公历。
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
