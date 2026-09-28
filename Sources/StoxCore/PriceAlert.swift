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

    public init(priceAbove: Double? = nil, priceBelow: Double? = nil, riseAbove: Double? = nil, fallBelow: Double? = nil) {
        self.priceAbove = priceAbove
        self.priceBelow = priceBelow
        self.riseAbove = riseAbove
        self.fallBelow = fallBelow
    }

    public var isEmpty: Bool {
        priceAbove == nil && priceBelow == nil && riseAbove == nil && fallBelow == nil
    }

    public func threshold(for condition: AlertCondition) -> Double? {
        switch condition {
        case .priceAbove: return priceAbove
        case .priceBelow: return priceBelow
        case .riseAbove: return riseAbove
        case .fallBelow: return fallBelow
        }
    }
}

public enum AlertCondition: String, Codable, CaseIterable, Sendable {
    case priceAbove, priceBelow, riseAbove, fallBelow

    func isMet(by quote: Quote, threshold: Double) -> Bool {
        switch self {
        case .priceAbove: return quote.price >= threshold
        case .priceBelow: return quote.price <= threshold
        case .riseAbove: return quote.changePercent >= abs(threshold)
        case .fallBelow: return quote.changePercent <= -abs(threshold)
        }
    }
}

public struct AlertTrigger: Sendable, Equatable {
    public let symbol: Symbol
    public let name: String
    public let condition: AlertCondition
    public let threshold: Double
    public let quote: Quote

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
        }
    }

    public var body: String {
        "现价 \(QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))，"
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

    public mutating func evaluate(items: [WatchItem], quotes: [Symbol: Quote], now: Date) -> [AlertTrigger] {
        var triggers: [AlertTrigger] = []
        for item in items where !item.alert.isEmpty {
            guard let quote = quotes[item.symbol], quote.price > 0, quote.hasTraded else { continue }
            let day = Self.dayKey(quote.timestamp ?? now, region: item.symbol.market.region)
            for condition in AlertCondition.allCases {
                guard let threshold = item.alert.threshold(for: condition),
                      condition.isMet(by: quote, threshold: threshold)
                else { continue }
                let key = Self.key(item.symbol, condition)
                guard firedDays[key] != day else { continue }
                firedDays[key] = day
                let name = quote.name.isEmpty ? item.displayName : quote.name
                triggers.append(AlertTrigger(symbol: item.symbol, name: name, condition: condition, threshold: threshold, quote: quote))
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
