import Foundation

/// 异动：几分钟之内价格快速拉升或下跌。
public struct RapidMove: Equatable, Sendable {
    public var symbol: Symbol
    /// 拉升是 .up，下跌是 .down。
    public var direction: PriceDirection
    /// 相对这几分钟里的最低点（拉升）或最高点（下跌）的涨跌幅（%），下跌是负数。
    public var percent: Double

    public init(symbol: Symbol, direction: PriceDirection, percent: Double) {
        self.symbol = symbol
        self.direction = direction
        self.percent = percent
    }
}

/// 发现异动。每次刷新行情时记一笔，现价相对最近几分钟里的最低点涨了超过阈值算拉升，相对最高点跌了超过阈值算下跌。
/// 同一只同一个方向提醒过以后，冷却一段时间再提醒，免得一路上涨时每次刷新都响。
public struct RapidMoveDetector: Sendable {
    /// 看最近多长时间。
    public static let window: TimeInterval = 5 * 60
    /// 提醒过以后多久之内不再提醒同一只同一个方向。
    public static let cooldown: TimeInterval = 15 * 60

    struct Sample: Sendable {
        var time: Date
        var price: Double
    }

    private var samples: [Symbol: [Sample]] = [:]
    private var lastFired: [String: Date] = [:]

    public init() {}

    /// 记下这一只的最新价格，刚出现异动时返回它。threshold 是涨跌幅的阈值（%，正数）。
    public mutating func record(_ quote: Quote, at time: Date, threshold: Double) -> RapidMove? {
        guard quote.price > 0, threshold > 0 else { return nil }
        var list = samples[quote.symbol, default: []].filter { $0.time <= time && time.timeIntervalSince($0.time) <= Self.window }
        list.append(Sample(time: time, price: quote.price))
        samples[quote.symbol] = list
        guard let low = list.map(\.price).min(), let high = list.map(\.price).max(), low > 0, high > 0 else { return nil }
        let rise = (quote.price - low) / low * 100
        let fall = (quote.price - high) / high * 100
        let move: RapidMove
        if rise >= threshold {
            move = RapidMove(symbol: quote.symbol, direction: .up, percent: rise)
        } else if fall <= -threshold {
            move = RapidMove(symbol: quote.symbol, direction: .down, percent: fall)
        } else {
            return nil
        }
        let key = "\(quote.symbol.rawValue)|\(move.direction)"
        if let last = lastFired[key], time.timeIntervalSince(last) < Self.cooldown { return nil }
        lastFired[key] = time
        return move
    }

    /// 不再关注的证券（删掉了）清掉记录。
    public mutating func forget(_ symbol: Symbol) {
        samples[symbol] = nil
        lastFired = lastFired.filter { !$0.key.hasPrefix(symbol.rawValue + "|") }
    }
}
