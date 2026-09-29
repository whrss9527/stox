import Foundation

public enum PriceDirection: Sendable, Equatable {
    case up, down, flat

    public init(_ change: Double) {
        if change > 1e-9 {
            self = .up
        } else if change < -1e-9 {
            self = .down
        } else {
            self = .flat
        }
    }
}

/// 一条实时行情快照。金额统一换算成本币“元”，成交量统一换算成“股”。
public struct Quote: Sendable, Equatable {
    public var symbol: Symbol
    public var name: String
    public var price: Double
    public var previousClose: Double
    public var open: Double
    public var high: Double
    public var low: Double
    public var change: Double
    public var changePercent: Double
    /// 成交量（股）。
    public var volume: Double
    /// 成交额（本币元）。
    public var amount: Double
    /// 换手率（%）。
    public var turnoverRate: Double?
    public var peRatio: Double?
    /// 总市值（本币元）。
    public var marketCap: Double?
    /// 涨停价 / 跌停价（仅 A 股）。
    public var limitUp: Double?
    public var limitDown: Double?
    /// 52 周最高 / 最低价。
    public var high52Week: Double?
    public var low52Week: Double?
    /// 行情时间（交易所当地时间）。
    public var timestamp: Date?
    /// 价格显示的小数位数，沿用交易所的报价精度。
    public var priceDecimals: Int
    /// 数据源里的交易所代码，例如 `600519`、`AAPL.OQ`、`.IXIC`。美股查 K 线时要用到后缀。
    public var exchangeCode: String?
    /// 买卖五档，只有 A 股（不含指数）有；开盘前、停牌时是空的盘口。
    public var orderBook: OrderBook?
    /// 场外基金的累计净值；别的是 nil。场外基金的现价是单位净值，时间是净值日期。
    public var cumulativeNAV: Double?
    /// 期货外汇的买价 / 卖价；别的是 nil（A 股的买一卖一在五档里）。
    public var bid: Double?
    public var ask: Double?

    public init(
        symbol: Symbol,
        name: String,
        price: Double,
        previousClose: Double,
        open: Double = 0,
        high: Double = 0,
        low: Double = 0,
        change: Double? = nil,
        changePercent: Double? = nil,
        volume: Double = 0,
        amount: Double = 0,
        turnoverRate: Double? = nil,
        peRatio: Double? = nil,
        marketCap: Double? = nil,
        limitUp: Double? = nil,
        limitDown: Double? = nil,
        high52Week: Double? = nil,
        low52Week: Double? = nil,
        timestamp: Date? = nil,
        priceDecimals: Int = 2,
        exchangeCode: String? = nil,
        orderBook: OrderBook? = nil,
        cumulativeNAV: Double? = nil,
        bid: Double? = nil,
        ask: Double? = nil
    ) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.previousClose = previousClose
        self.open = open
        self.high = high
        self.low = low
        let computedChange = price > 0 && previousClose > 0 ? price - previousClose : 0
        self.change = change ?? computedChange
        self.changePercent = changePercent ?? (previousClose > 0 ? computedChange / previousClose * 100 : 0)
        self.volume = volume
        self.amount = amount
        self.turnoverRate = turnoverRate
        self.peRatio = peRatio
        self.marketCap = marketCap
        self.limitUp = limitUp
        self.limitDown = limitDown
        self.high52Week = high52Week
        self.low52Week = low52Week
        self.timestamp = timestamp
        self.priceDecimals = priceDecimals
        self.exchangeCode = exchangeCode
        self.orderBook = orderBook
        self.cumulativeNAV = cumulativeNAV
        self.bid = bid
        self.ask = ask
    }

    public var direction: PriceDirection { PriceDirection(change) }

    /// 今天是否有过成交。交易时段内仍为 false 通常意味着停牌。场外基金没有成交，有净值就算；
    /// 期货外汇的接口不给成交量，有价格就算。
    public var hasTraded: Bool { symbol.isFund || symbol.isGlobal ? price > 0 : volume > 0 || open > 0 }

    /// 振幅（%）。
    public var amplitude: Double? {
        guard previousClose > 0, high > 0, low > 0 else { return nil }
        return (high - low) / previousClose * 100
    }

    public var isLimitUp: Bool {
        guard let limitUp, limitUp > 0 else { return false }
        return abs(price - limitUp) < 1e-6
    }

    public var isLimitDown: Bool {
        guard let limitDown, limitDown > 0 else { return false }
        return abs(price - limitDown) < 1e-6
    }
}
