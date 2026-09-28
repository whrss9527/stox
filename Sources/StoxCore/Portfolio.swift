import Foundation

/// 一只证券的持仓：股数和每股成本价（本币）。
public struct Holding: Codable, Hashable, Sendable {
    public var shares: Double
    public var cost: Double

    public init(shares: Double, cost: Double) {
        self.shares = shares
        self.cost = cost
    }

    /// 股数为正、成本价不为负才算有效；成本价可以是 0（比如送股）。
    public var isValid: Bool {
        shares > 0 && cost >= 0 && shares.isFinite && cost.isFinite
    }

    public var costValue: Double { shares * cost }
}

/// 按现价算出的持仓盈亏。
public struct PositionValue: Equatable, Sendable {
    /// 市值：股数 × 现价。
    public var marketValue: Double
    /// 成本：股数 × 成本价。
    public var costValue: Double
    /// 今日盈亏：股数 × 今天的涨跌额。
    public var dayProfit: Double

    /// 持仓盈亏：市值 − 成本。
    public var totalProfit: Double { marketValue - costValue }

    /// 持仓盈亏比例（%）；成本为 0 时没有意义，返回 nil。
    public var totalProfitPercent: Double? {
        costValue > 0 ? totalProfit / costValue * 100 : nil
    }
}

/// 同一种货币的持仓合计。不同货币不换算、不相加。
public struct PortfolioSummary: Equatable, Sendable {
    public var region: MarketRegion
    public var marketValue: Double
    public var costValue: Double
    public var dayProfit: Double
    /// 计入合计的持仓数。
    public var count: Int

    public var totalProfit: Double { marketValue - costValue }

    public var totalProfitPercent: Double? {
        costValue > 0 ? totalProfit / costValue * 100 : nil
    }

    /// 今日盈亏相对昨日市值的比例（%）。
    public var dayProfitPercent: Double? {
        let previous = marketValue - dayProfit
        return previous > 0 ? dayProfit / previous * 100 : nil
    }
}

public enum Portfolio {
    /// 一只证券的持仓盈亏；没有现价时返回 nil。
    public static func position(_ holding: Holding, quote: Quote) -> PositionValue? {
        guard holding.isValid, quote.price > 0 else { return nil }
        return PositionValue(
            marketValue: holding.shares * quote.price,
            costValue: holding.costValue,
            dayProfit: holding.shares * quote.change
        )
    }

    /// 按市场所用的货币（人民币、港币、美元）分别合计，按 A 股、港股、美股排序；没有持仓的货币不出现。
    public static func summaries(items: [WatchItem], quotes: [Symbol: Quote]) -> [PortfolioSummary] {
        var totals: [MarketRegion: PortfolioSummary] = [:]
        for item in items {
            guard let holding = item.holding, let quote = quotes[item.symbol],
                  let position = position(holding, quote: quote)
            else { continue }
            let region = item.symbol.market.region
            var summary = totals[region] ?? PortfolioSummary(region: region, marketValue: 0, costValue: 0, dayProfit: 0, count: 0)
            summary.marketValue += position.marketValue
            summary.costValue += position.costValue
            summary.dayProfit += position.dayProfit
            summary.count += 1
            totals[region] = summary
        }
        return MarketRegion.allCases.compactMap { totals[$0] }
    }
}

extension MarketRegion {
    /// 界面上显示的货币名称。
    public var currencyName: String {
        switch self {
        case .cn: return "人民币"
        case .hk: return "港币"
        case .us: return "美元"
        }
    }
}
