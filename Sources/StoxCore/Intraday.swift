import Foundation

/// 分时走势里的一个点：交易所当地时间（自零点起的分钟数）和价格。
public struct IntradayPoint: Equatable, Sendable {
    public var minute: Int
    public var price: Double

    public init(minute: Int, price: Double) {
        self.minute = minute
        self.price = price
    }
}

/// 一只证券一天的分时走势。
public struct IntradaySeries: Equatable, Sendable {
    public var symbol: Symbol
    /// 交易日，例如 `20260928`；接口没给时为 nil。
    public var date: String?
    public var points: [IntradayPoint]

    public init(symbol: Symbol, date: String?, points: [IntradayPoint]) {
        self.symbol = symbol
        self.date = date
        self.points = points
    }

    public var high: Double? { points.map(\.price).max() }
    public var low: Double? { points.map(\.price).min() }
}

/// 解析腾讯分时接口的返回。
///
/// - A 股、港股：`https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh600519`
/// - 美股（含指数）：`https://web.ifzq.gtimg.cn/appstock/app/UsMinute/query?code=usAAPL`
///
/// 返回 `{"code":0,"data":{"sh600519":{"data":{"data":["0930 1236.00 349 43136400.00", …],"date":"20260928"}}}}`，
/// 每条是“时刻 价格 累计成交量 [累计成交额]”，时刻是交易所当地时间。
public enum TencentMinuteParser {
    public static func parse(_ data: Data, symbol: Symbol) -> IntradaySeries? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = json["data"] as? [String: Any],
              let entry = (all[symbol.rawValue] ?? all.values.first) as? [String: Any],
              let series = entry["data"] as? [String: Any],
              let rows = series["data"] as? [String]
        else { return nil }
        let points = rows.compactMap(point(from:))
        let date = (series["date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return IntradaySeries(symbol: symbol, date: date, points: points)
    }

    static func point(from row: String) -> IntradayPoint? {
        let parts = row.split(separator: " ")
        guard parts.count >= 2, parts[0].count == 4, let hhmm = Int(parts[0]),
              let price = Double(parts[1]), price > 0
        else { return nil }
        let hour = hhmm / 100
        let minute = hhmm % 100
        guard hour < 24, minute < 60 else { return nil }
        return IntradayPoint(minute: hour * 60 + minute, price: price)
    }
}

/// 分时图的横轴：只包含连续交易时段，午休不占位置。
public enum IntradayAxis {
    /// 连续交易时段（交易所当地时间，自零点起的分钟数）。
    public static func sessions(for region: MarketRegion) -> [ClosedRange<Int>] {
        switch region {
        case .cn: return [(9 * 60 + 30)...(11 * 60 + 30), (13 * 60)...(15 * 60)]
        case .hk: return [(9 * 60 + 30)...(12 * 60), (13 * 60)...(16 * 60)]
        case .us: return [(9 * 60 + 30)...(16 * 60)]
        }
    }

    /// 横轴总长度（分钟）：A 股 240、港股 330、美股 390。
    public static func length(for region: MarketRegion) -> Int {
        sessions(for: region).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    /// 某个时刻在横轴上的位置（0 到 length）。开盘前的点放在最左边，午休归到上午收盘处，
    /// 收盘后的点（港股收市竞价、美股盘后）放在最右边。
    public static func offset(of minute: Int, region: MarketRegion) -> Int {
        var elapsed = 0
        for session in sessions(for: region) {
            if minute <= session.lowerBound { return elapsed }
            if minute <= session.upperBound { return elapsed + minute - session.lowerBound }
            elapsed += session.upperBound - session.lowerBound
        }
        return elapsed
    }
}

extension IntradaySeries {
    /// 横轴上离 offset（0 到 IntradayAxis.length）最近的点，鼠标悬停时用。
    public func point(nearest offset: Double, region: MarketRegion) -> IntradayPoint? {
        points.min { lhs, rhs in
            abs(Double(IntradayAxis.offset(of: lhs.minute, region: region)) - offset)
                < abs(Double(IntradayAxis.offset(of: rhs.minute, region: region)) - offset)
        }
    }
}
