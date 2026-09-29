import Foundation

/// 买卖盘口：买一到买五、卖一到卖五的挂单价和挂单量，以及外盘、内盘。
///
/// 只有 A 股（不含指数）有五档。腾讯接口里港股的“买一”“卖一”只是现价，美股只有买一卖一，都不解析。
public struct OrderBook: Sendable, Equatable {
    public struct Level: Sendable, Equatable {
        public var price: Double
        /// 挂单量（股）。
        public var volume: Double

        public init(price: Double, volume: Double) {
            self.price = price
            self.volume = volume
        }
    }

    /// 每边最多几档。
    public static let depth = 5

    /// 买一在前。没有挂单的档不在里面，比如跌停时买盘是空的。
    public var bids: [Level]
    /// 卖一在前。涨停时卖盘是空的。
    public var asks: [Level]
    /// 外盘（股）：按卖出价成交的量，也就是主动买入的。
    public var outerVolume: Double?
    /// 内盘（股）：按买入价成交的量，也就是主动卖出的。
    public var innerVolume: Double?

    public init(bids: [Level], asks: [Level], outerVolume: Double? = nil, innerVolume: Double? = nil) {
        self.bids = Array(bids.prefix(Self.depth))
        self.asks = Array(asks.prefix(Self.depth))
        self.outerVolume = outerVolume
        self.innerVolume = innerVolume
    }

    /// 两边都没有挂单：开盘前、停牌。
    public var isEmpty: Bool { bids.isEmpty && asks.isEmpty }

    /// 委买：买盘各档挂单量之和（股）。
    public var bidVolume: Double { bids.reduce(0) { $0 + $1.volume } }

    /// 委卖：卖盘各档挂单量之和（股）。
    public var askVolume: Double { asks.reduce(0) { $0 + $1.volume } }

    /// 委比（%）：(委买 − 委卖) ÷ (委买 + 委卖) × 100，在 −100 到 100 之间；涨停时是 100。两边都没有挂单量时为 nil。
    public var imbalance: Double? {
        let total = bidVolume + askVolume
        guard total > 0 else { return nil }
        return (bidVolume - askVolume) / total * 100
    }

    /// 各档里最大的挂单量，画量条时用来比。
    public var maxVolume: Double {
        (bids + asks).map(\.volume).max() ?? 0
    }

    /// 从一串“价、量”里取出有挂单的档：价格是 0 的档没有挂单（集合竞价时第二档放的是未匹配量，价格也是 0）。
    static func levels(_ pairs: [(price: Double?, volume: Double?)], volumeScale: Double) -> [Level] {
        var levels: [Level] = []
        for pair in pairs {
            guard let price = pair.price, price > 0, price.isFinite else { break }
            let volume = max(pair.volume ?? 0, 0) * volumeScale
            levels.append(Level(price: price, volume: volume.isFinite ? volume : 0))
        }
        return levels
    }
}
