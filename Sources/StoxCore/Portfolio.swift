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

    /// 买入一笔：数量相加，成本价按加权平均重新算（摊薄或摊高）。
    public func buying(shares extra: Double, at price: Double) -> Holding? {
        guard isValid, extra > 0, price >= 0, extra.isFinite, price.isFinite else { return nil }
        let total = shares + extra
        return Holding(shares: total, cost: (costValue + extra * price) / total)
    }

    /// 卖出一笔：成本价不变，数量减少。卖得比持有的还多时返回 nil；全部卖出时数量为 0，由调用方清掉持仓。
    public func selling(shares sold: Double) -> Holding? {
        guard isValid, sold > 0, sold.isFinite, sold <= shares + 1e-9 else { return nil }
        return Holding(shares: max(shares - sold, 0), cost: cost)
    }
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

/// 持仓分布里的一只：市值和占总市值的比例。
public struct AllocationEntry: Equatable, Sendable {
    public var symbol: Symbol
    public var name: String
    /// 原来币种的市值。
    public var marketValue: Double
    /// 用来比较的市值：几种货币都有时折成人民币，只有一种货币时就是原来的。
    public var value: Double
    /// 占总市值的比例（%）。
    public var share: Double
    /// 持仓盈亏比例（%）；成本为 0 时为 nil。
    public var profitPercent: Double?

    public init(symbol: Symbol, name: String, marketValue: Double, value: Double, share: Double, profitPercent: Double?) {
        self.symbol = symbol
        self.name = name
        self.marketValue = marketValue
        self.value = value
        self.share = share
        self.profitPercent = profitPercent
    }
}

extension Portfolio {
    /// 持仓分布：每只占总市值的比例，按市值从大到小。几种货币都有时按汇率折成人民币再比，
    /// 没有汇率时比不了，返回空数组。
    public static func allocation(items: [WatchItem], quotes: [Symbol: Quote], rates: ExchangeRates?) -> [AllocationEntry] {
        var positions: [(item: WatchItem, quote: Quote, position: PositionValue)] = []
        for item in items {
            guard let holding = item.holding, let quote = quotes[item.symbol],
                  let position = position(holding, quote: quote), position.marketValue > 0
            else { continue }
            positions.append((item, quote, position))
        }
        let mixed = Set(positions.map { $0.item.symbol.market.region }).count > 1
        if mixed, rates == nil { return [] }
        let values = positions.map { entry -> Double in
            let rate = mixed ? rates?.toCNY(entry.item.symbol.market.region) ?? 1 : 1
            return entry.position.marketValue * rate
        }
        let total = values.reduce(0, +)
        guard total > 0 else { return [] }
        return zip(positions, values)
            .map { entry, value in
                AllocationEntry(
                    symbol: entry.item.symbol,
                    name: entry.quote.name.isEmpty ? entry.item.displayName : entry.quote.name,
                    marketValue: entry.position.marketValue,
                    value: value,
                    share: value / total * 100,
                    profitPercent: entry.position.totalProfitPercent
                )
            }
            .sorted { $0.value > $1.value }
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

    /// 菜单栏上用的货币符号。
    public var currencySymbol: String {
        switch self {
        case .cn: return "¥"
        case .hk: return "HK$"
        case .us: return "$"
        }
    }
}

extension Portfolio {
    /// 持仓表格，制表符分隔，粘贴到 Numbers、Excel 就是一张表。金额不用万、亿，保留两位小数，方便再计算。
    public static func tableText(items: [WatchItem], quotes: [Symbol: Quote]) -> String {
        var lines = ["名称\t代码\t币种\t持有\t成本价\t现价\t市值\t持仓盈亏\t盈亏比例\t今日盈亏"]
        for item in items {
            guard let holding = item.holding, let quote = quotes[item.symbol],
                  let position = position(holding, quote: quote)
            else { continue }
            let name = quote.name.isEmpty ? item.displayName : quote.name
            lines.append([
                name,
                item.symbol.displayCode,
                item.symbol.market.region.currency,
                QuoteFormatter.plain(holding.shares),
                QuoteFormatter.plain(holding.cost),
                QuoteFormatter.fixed(quote.price, decimals: quote.priceDecimals),
                QuoteFormatter.fixed(position.marketValue, decimals: 2),
                QuoteFormatter.fixed(position.totalProfit, decimals: 2),
                position.totalProfitPercent.map { QuoteFormatter.fixed($0, decimals: 2) + "%" } ?? "",
                QuoteFormatter.fixed(position.dayProfit, decimals: 2),
            ].joined(separator: "\t"))
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }
}

/// 收盘后发的今日盈亏小结。
public struct CloseSummaryNote: Equatable, Sendable {
    public var region: MarketRegion
    /// 交易日，`2026-09-28`，用来记住今天发过了。
    public var day: String
    public var title: String
    public var body: String
}

public enum CloseSummary {
    /// 收盘后多久以内还补发：晚上才打开 Mac 也能收到，但第二天早上开盘前就不再发前一天的了。
    public static let window: TimeInterval = 16 * 3600

    /// 这个市场已经收盘（休市，或者美股进入盘后）、有持仓，最近一个交易日的收盘还不到 16 小时，
    /// 并且这个交易日还没发过时，返回要发的小结。开盘前、午休不发；节假日最新行情是好几天前的，也不发。
    public static func due(
        region: MarketRegion,
        phase: MarketPhase,
        summary: PortfolioSummary?,
        latestQuoteTime: Date?,
        now: Date,
        lastSentDay: String?
    ) -> CloseSummaryNote? {
        guard phase == .closed || phase == .afterHours, let summary, let latestQuoteTime,
              now.timeIntervalSince(latestQuoteTime) < window
        else { return nil }
        let today = AlertEngine.dayKey(latestQuoteTime, region: region)
        guard lastSentDay != today else { return nil }
        let title = "\(region.displayName)收盘 今日盈亏 \(QuoteFormatter.signedMoney(summary.dayProfit))"
        var body = ""
        if let percent = summary.dayProfitPercent {
            body += "今日 \(QuoteFormatter.percent(percent))，"
        }
        body += "持仓盈亏 \(QuoteFormatter.signedMoney(summary.totalProfit))"
        if let percent = summary.totalProfitPercent {
            body += "（\(QuoteFormatter.percent(percent))）"
        }
        body += "，市值 \(QuoteFormatter.money(summary.marketValue))\(region.currencyName)"
        return CloseSummaryNote(region: region, day: today, title: title, body: body)
    }
}
