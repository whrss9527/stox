import Foundation

/// 单只证券的价格提醒。每个条件每个交易日最多提醒一次，避免价格在阈值附近来回波动时反复打扰。
public struct PriceAlert: Codable, Hashable, Sendable {
    /// 价格高于或等于。
    public var priceAbove: Double?
    /// 价格低于或等于。
    public var priceBelow: Double?
    /// 涨幅达到（%，正数）。
    public var riseAbove: Double?
    /// 跌幅达到（%，正数）。
    public var fallBelow: Double?
    /// 持仓盈利达到（%，相对成本，正数），用来止盈。没有持仓或成本为 0 时不提醒。
    public var profitAbove: Double?
    /// 持仓亏损达到（%，相对成本，正数），用来止损。
    public var lossBelow: Double?

    public init(
        priceAbove: Double? = nil, priceBelow: Double? = nil, riseAbove: Double? = nil, fallBelow: Double? = nil,
        profitAbove: Double? = nil, lossBelow: Double? = nil
    ) {
        self.priceAbove = priceAbove
        self.priceBelow = priceBelow
        self.riseAbove = riseAbove
        self.fallBelow = fallBelow
        self.profitAbove = profitAbove
        self.lossBelow = lossBelow
    }

    public var isEmpty: Bool {
        AlertCondition.allCases.allSatisfy { threshold(for: $0) == nil }
    }

    public func threshold(for condition: AlertCondition) -> Double? {
        switch condition {
        case .priceAbove: return priceAbove
        case .priceBelow: return priceBelow
        case .riseAbove: return riseAbove
        case .fallBelow: return fallBelow
        case .profitAbove: return profitAbove
        case .lossBelow: return lossBelow
        // 涨停跌停、52 周新高新低、异动不是每只单独设的，由设置里的总开关管（见 AlertEngine.evaluate、RapidMoveDetector）。
        case .limitUp, .limitDown, .yearHigh, .yearLow, .rapidRise, .rapidFall: return nil
        }
    }
}

public enum AlertCondition: String, Codable, CaseIterable, Sendable {
    case priceAbove, priceBelow, riseAbove, fallBelow, profitAbove, lossBelow
    /// A 股封涨停、跌停。
    case limitUp, limitDown
    /// 几分钟内快速拉升、下跌（异动），由 RapidMoveDetector 判断。
    case rapidRise, rapidFall
    /// 当天的最高价达到 52 周最高、最低价达到 52 周最低。
    case yearHigh, yearLow

    func isMet(by quote: Quote, holding: Holding?, threshold: Double) -> Bool {
        switch self {
        case .priceAbove: return quote.price >= threshold
        case .priceBelow: return quote.price <= threshold
        case .riseAbove: return quote.changePercent >= abs(threshold)
        case .fallBelow: return quote.changePercent <= -abs(threshold)
        case .profitAbove, .lossBelow:
            guard let percent = holding.flatMap({ Portfolio.position($0, quote: quote)?.totalProfitPercent }) else { return false }
            return self == .profitAbove ? percent >= abs(threshold) : percent <= -abs(threshold)
        case .limitUp: return quote.isLimitUp
        case .limitDown: return quote.isLimitDown
        // 接口的 52 周最高最低可能已经算上了今天，所以用“达到”：今天的最高价不低于它就是创了新高。
        case .yearHigh:
            guard let high = quote.high52Week, high > 0, quote.high > 0 else { return false }
            return quote.high >= high - 1e-9
        case .yearLow:
            guard let low = quote.low52Week, low > 0, quote.low > 0 else { return false }
            return quote.low <= low + 1e-9
        case .rapidRise, .rapidFall: return false
        }
    }
}

public struct AlertTrigger: Sendable, Equatable {
    public let symbol: Symbol
    public let name: String
    public let condition: AlertCondition
    public let threshold: Double
    public let quote: Quote
    /// 触发时的持仓，止盈止损提醒的正文里用。
    public var holding: Holding?
    /// 打开了“隐藏金额”：止盈止损提醒的正文里不写盈亏金额，只写比例。
    public var hidesAmounts = false

    public init(symbol: Symbol, name: String, condition: AlertCondition, threshold: Double, quote: Quote, holding: Holding? = nil) {
        self.symbol = symbol
        self.name = name
        self.condition = condition
        self.threshold = threshold
        self.quote = quote
        self.holding = holding
    }

    public var title: String {
        switch condition {
        case .priceAbove:
            return "\(name) 价格涨到 \(QuoteFormatter.price(threshold, decimals: quote.priceDecimals))"
        case .priceBelow:
            return "\(name) 价格跌到 \(QuoteFormatter.price(threshold, decimals: quote.priceDecimals))"
        case .riseAbove:
            return "\(name) 涨幅达到 \(QuoteFormatter.fixed(abs(threshold), decimals: 2))%"
        case .fallBelow:
            return "\(name) 跌幅达到 \(QuoteFormatter.fixed(abs(threshold), decimals: 2))%"
        case .profitAbove:
            return "\(name) 持仓盈利达到 \(QuoteFormatter.fixed(abs(threshold), decimals: 2))%"
        case .lossBelow:
            return "\(name) 持仓亏损达到 \(QuoteFormatter.fixed(abs(threshold), decimals: 2))%"
        case .limitUp:
            return "\(name) 涨停"
        case .limitDown:
            return "\(name) 跌停"
        case .yearHigh:
            return "\(name) 创 52 周新高"
        case .yearLow:
            return "\(name) 创 52 周新低"
        case .rapidRise:
            return "\(name) \(Int(RapidMoveDetector.window / 60)) 分钟内拉升 \(QuoteFormatter.fixed(abs(threshold), decimals: 2))%"
        case .rapidFall:
            return "\(name) \(Int(RapidMoveDetector.window / 60)) 分钟内下跌 \(QuoteFormatter.fixed(abs(threshold), decimals: 2))%"
        }
    }

    public var body: String {
        let price = "现价 \(QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))，"
        if condition == .profitAbove || condition == .lossBelow, let holding,
           let position = Portfolio.position(holding, quote: quote) {
            var text = price + "成本 \(QuoteFormatter.fixed(holding.cost, decimals: max(quote.priceDecimals, 2)))，"
            if hidesAmounts {
                return text + "持仓盈亏 \(position.totalProfitPercent.map(QuoteFormatter.percent) ?? QuoteFormatter.hiddenAmount)"
            }
            text += "持仓盈亏 \(QuoteFormatter.signedMoney(position.totalProfit))"
            if let percent = position.totalProfitPercent {
                text += "（\(QuoteFormatter.percent(percent))）"
            }
            return text
        }
        var text = price
        switch condition {
        case .yearHigh:
            text += "今天最高 \(QuoteFormatter.price(quote.high, decimals: quote.priceDecimals))，"
        case .yearLow:
            text += "今天最低 \(QuoteFormatter.price(quote.low, decimals: quote.priceDecimals))，"
        default:
            break
        }
        return text
            + "涨跌 \(QuoteFormatter.change(quote.change, decimals: quote.priceDecimals))"
            + "（\(QuoteFormatter.percent(quote.changePercent))）"
    }
}

/// 判断哪些提醒需要发出，并记住每个条件最近一次提醒的交易日。
public struct AlertEngine: Codable, Sendable, Equatable {
    /// key 为 `sh600519|priceAbove`，value 为行情所在交易日 `2026-09-28`。
    public private(set) var firedDays: [String: String]

    public init(firedDays: [String: String] = [:]) {
        self.firedDays = firedDays
    }

    /// - Parameters:
    ///   - limitAlerts: 设置里打开了“涨停、跌停时提醒”：自选里的 A 股个股封板时也提醒。
    ///   - yearAlerts: 设置里打开了“创 52 周新高、新低时提醒”：自选里的证券（含指数）都看。
    public mutating func evaluate(
        items: [WatchItem], quotes: [Symbol: Quote], now: Date, limitAlerts: Bool = false, yearAlerts: Bool = false
    ) -> [AlertTrigger] {
        var triggers: [AlertTrigger] = []
        for item in items where !item.alert.isEmpty || limitAlerts || yearAlerts {
            guard let quote = quotes[item.symbol], quote.price > 0, quote.hasTraded else { continue }
            let day = Self.dayKey(quote.timestamp ?? now, region: item.symbol.market.region)
            for condition in AlertCondition.allCases {
                let threshold: Double?
                switch condition {
                case .limitUp, .limitDown:
                    threshold = limitAlerts && !item.symbol.isIndex ? 0 : nil
                case .yearHigh, .yearLow:
                    threshold = yearAlerts ? 0 : nil
                default:
                    threshold = item.alert.threshold(for: condition)
                }
                guard let threshold, condition.isMet(by: quote, holding: item.holding, threshold: threshold) else { continue }
                let key = Self.key(item.symbol, condition)
                guard firedDays[key] != day else { continue }
                firedDays[key] = day
                let name = quote.name.isEmpty ? item.displayName : quote.name
                triggers.append(AlertTrigger(
                    symbol: item.symbol, name: name, condition: condition, threshold: threshold, quote: quote, holding: item.holding
                ))
            }
        }
        return triggers
    }

    /// 修改提醒阈值后调用，让新的阈值当天也能触发。
    public mutating func reset(_ symbol: Symbol) {
        for condition in AlertCondition.allCases {
            firedDays.removeValue(forKey: Self.key(symbol, condition))
        }
    }

    public func hasFiredToday(_ symbol: Symbol, _ condition: AlertCondition, now: Date) -> Bool {
        firedDays[Self.key(symbol, condition)] == Self.dayKey(now, region: symbol.market.region)
    }

    static func key(_ symbol: Symbol, _ condition: AlertCondition) -> String {
        "\(symbol.rawValue)|\(condition.rawValue)"
    }

    static func dayKey(_ date: Date, region: MarketRegion) -> String {
        let c = region.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
