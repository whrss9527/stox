import Foundation

/// 在编辑页“记一笔”记下的一笔买卖或分红送转。持仓已经按它改过了，这里留个记录：看最近买卖过什么、
/// 卖出和分红赚了多少，以及把今天的买卖算进今日盈亏。
public struct Trade: Codable, Hashable, Sendable {
    public enum Side: String, Codable, Sendable {
        case buy, sell
        /// 分红送转：现金分红摊薄成本，送转的股加到数量里。
        case dividend

        public var title: String {
            switch self {
            case .buy: return "买入"
            case .sell: return "卖出"
            case .dividend: return "分红"
            }
        }
    }

    public var side: Side
    /// 买卖的股数；分红送转时是登记时持有的股数。
    public var shares: Double
    /// 成交价；分红送转时是每股派的现金。
    public var price: Double
    /// 哪个交易日的，交易所当地的 `2026-09-29`。
    public var day: String
    /// 已实现盈亏（本币）：卖出是按当时的成本价算的 (卖出价 − 成本价) × 股数，分红是到手的现金。买入是 nil。
    public var profit: Double?
    /// 分红送转时每股送转几股（10 送 4 是 0.4）；没有送转、或者不是分红时为 nil。
    public var bonus: Double?

    public init(side: Side, shares: Double, price: Double, day: String, profit: Double? = nil, bonus: Double? = nil) {
        self.side = side
        self.shares = shares
        self.price = price
        self.day = day
        self.profit = profit
        self.bonus = bonus
    }

    /// 每只最多留这么多笔，旧的丢掉。
    public static let limit = 100

    /// 这一笔算哪个交易日：这个市场今天已经开始交易（盘前、盘中、午休、盘后）时是今天，否则是最新行情所在的
    /// 那个交易日，这样第二天开盘前补记的买卖算在前一个交易日。没有行情时按现在的日期。
    public static func day(for region: MarketRegion, now: Date, latestQuoteTime: Date?) -> String {
        let phase = MarketClock.effectivePhase(for: region, at: now, latestQuoteTime: latestQuoteTime)
        let reference = phase == .closed ? (latestQuoteTime ?? now) : now
        return ProfitHistory.day(of: reference, region: region)
    }

    /// 卖出一笔的记录，已实现盈亏按卖出前的成本价算。
    public static func sell(_ shares: Double, at price: Double, from holding: Holding, day: String) -> Trade {
        Trade(side: .sell, shares: shares, price: price, day: day, profit: (price - holding.cost) * shares)
    }

    /// 分红送转的记录：每股派 cash、送转 bonus 股，到手的现金算已实现盈亏。
    public static func dividend(cash: Double, bonus: Double, holding: Holding, day: String) -> Trade {
        Trade(side: .dividend, shares: holding.shares, price: cash, day: day, profit: holding.shares * cash, bonus: bonus > 0 ? bonus : nil)
    }
}

/// 读数组时用：这一项读不懂就是 nil，不让整个数组读失败。
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension Array where Element == Trade {
    /// 新记的几笔接在后面，只留最近的 `Trade.limit` 笔。
    public func appending(_ trades: [Trade]) -> [Trade] {
        Array((self + trades).suffix(Trade.limit))
    }

    /// 这一天（含）以来卖出和分红的已实现盈亏之和。
    public func realizedProfit(since day: String) -> Double {
        filter { $0.day >= day }.reduce(0) { $0 + ($1.profit ?? 0) }
    }
}

extension Portfolio {
    /// 今日盈亏，算上今天记的买卖：昨天就有、今天没卖的按涨跌额算，今天买的按现价减买入价，今天卖的按卖出价减昨收。
    /// 加起来正好是“现在的市值 − 昨收时的市值 − 今天净投入的钱”。今天没记买卖时就是股数 × 涨跌额。
    /// “今天”是行情所在的交易日。
    public static func dayProfit(shares: Double, quote: Quote, trades: [Trade]) -> Double {
        guard !trades.isEmpty, let time = quote.timestamp else { return shares * quote.change }
        let today = ProfitHistory.day(of: time, region: quote.symbol.market.region)
        var bought = 0.0
        var traded = 0.0
        for trade in trades where trade.day == today {
            switch trade.side {
            case .buy:
                bought += trade.shares
                traded += (quote.price - trade.price) * trade.shares
            case .sell:
                traded += (trade.price - quote.previousClose) * trade.shares
            case .dividend:
                break  // 除权除息那天昨收已经调过，送转的股也按涨跌额算就对了
            }
        }
        return (shares - bought) * quote.change + traded
    }

    /// 今天全部卖掉、已经没有持仓的一只，今天卖出的那部分盈亏；今天没卖过时为 nil。
    static func soldOutDayProfit(_ item: WatchItem, quote: Quote) -> Double? {
        guard item.holding == nil, quote.price > 0, let time = quote.timestamp else { return nil }
        let today = ProfitHistory.day(of: time, region: quote.symbol.market.region)
        guard item.trades.contains(where: { $0.day == today }) else { return nil }
        return dayProfit(shares: 0, quote: quote, trades: item.trades)
    }

    /// 某一天（含）以来卖出和分红的已实现盈亏，按 A 股、港股、美股的货币分开；没有卖出、分红过的货币不出现。
    /// since 按各个市场当地的日期比，比如今年是 `2026-01-01`。
    public static func realizedProfit(items: [WatchItem], since day: String) -> [(region: MarketRegion, profit: Double)] {
        var totals: [MarketRegion: Double] = [:]
        for item in items where item.trades.contains(where: { $0.profit != nil && $0.day >= day }) {
            totals[item.symbol.market.region, default: 0] += item.trades.realizedProfit(since: day)
        }
        return MarketRegion.allCases.compactMap { region in totals[region].map { (region, $0) } }
    }

    /// 今年 1 月 1 日，按这个时刻在北京的日期算（三个市场的年份只在元旦前后几个小时不一样）。
    public static func yearStart(now: Date) -> String {
        String(ProfitHistory.day(of: now, region: .cn).prefix(4)) + "-01-01"
    }
}

/// K 线上的买卖点：第几根上记过买入、卖出。
public struct KlineTradeMark: Equatable, Sendable {
    public var index: Int
    public var bought: Bool
    public var sold: Bool

    public init(index: Int, bought: Bool, sold: Bool) {
        self.index = index
        self.bought = bought
        self.sold = sold
    }
}

extension KlineChartData {
    /// 记下的买卖落在图上的哪几根：日 K 按日期，周 K、月 K 按同一周、同一个月。落在图外面的不要。
    public func tradeMarks(_ trades: [Trade], region: MarketRegion) -> [KlineTradeMark] {
        var marks: [Int: KlineTradeMark] = [:]
        for trade in trades {
            guard let index = candleIndex(of: trade.day, region: region) else { continue }
            var mark = marks[index] ?? KlineTradeMark(index: index, bought: false, sold: false)
            switch trade.side {
            case .buy: mark.bought = true
            case .sell: mark.sold = true
            case .dividend: continue
            }
            marks[index] = mark
        }
        return marks.values.sorted { $0.index < $1.index }
    }

    /// 这一天落在哪一根上；K 线的日期是那一周、那个月的最后一个交易日。
    func candleIndex(of day: String, region: MarketRegion) -> Int? {
        guard let first = candles.first, let last = candles.last else { return nil }
        switch period {
        case .day:
            guard day >= first.date, day <= last.date else { return nil }
            return candles.firstIndex { $0.date == day }
        case .week, .month:
            let unit: Calendar.Component = period == .week ? .weekOfYear : .month
            return candles.firstIndex { KlineCalendar.isSame(unit, $0.date, day, region: region) }
        }
    }
}
