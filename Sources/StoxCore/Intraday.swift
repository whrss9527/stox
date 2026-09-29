import Foundation

/// 分时走势里的一个点：交易所当地时间（自零点起的分钟数）、价格和到这一分钟为止的成交均价。
public struct IntradayPoint: Equatable, Sendable {
    public var minute: Int
    public var price: Double
    /// 当天到这一分钟为止的成交均价；指数、算不出来时为 nil。
    public var average: Double?
    /// 这一分钟的成交量，单位和接口一样（A 股是手，科创板、港股、美股是股）；接口没给时为 nil。
    public var volume: Double?

    public init(minute: Int, price: Double, average: Double? = nil, volume: Double? = nil) {
        self.minute = minute
        self.price = price
        self.average = average
        self.volume = volume
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
    /// 最新的成交均价。
    public var latestAverage: Double? { points.last(where: { $0.average != nil })?.average }
}

/// 解析腾讯分时接口的返回。
///
/// - A 股、港股：`https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh600519`
/// - 美股（含指数）：`https://web.ifzq.gtimg.cn/appstock/app/UsMinute/query?code=usAAPL`
///
/// 返回 `{"code":0,"data":{"sh600519":{"data":{"data":["0930 1236.00 349 43136400.00", …],"date":"20260928"}}}}`，
/// 每条是“时刻 价格 累计成交量 [累计成交额]”，时刻是交易所当地时间。A 股的成交量是手，港股是股，
/// 美股只有累计成交量。
public enum TencentMinuteParser {
    public static func parse(_ data: Data, symbol: Symbol) -> IntradaySeries? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = json["data"] as? [String: Any],
              let entry = (all[symbol.rawValue] ?? all.values.first) as? [String: Any],
              let series = entry["data"] as? [String: Any],
              let rows = series["data"] as? [String]
        else { return nil }
        let points = points(rows.compactMap(row(from:)), isIndex: symbol.isIndex)
        let date = (series["date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return IntradaySeries(symbol: symbol, date: date, points: points)
    }

    /// 一天的分时点：个股带着均价（指数的成交量、成交额是成分股加起来的，没有均价），都带着每分钟的成交量。
    static func points(_ rows: [Row], isIndex: Bool) -> [IntradayPoint] {
        var points = isIndex ? rows.map(\.point) : addingAverages(rows)
        guard points.count == rows.count else { return points }
        for (index, volume) in minuteVolumes(rows).enumerated() {
            points[index].volume = volume
        }
        return points
    }

    /// 每一分钟新增的成交量：累计成交量减去前面最大的那个，数据往回跳时当作 0。
    static func minuteVolumes(_ rows: [Row]) -> [Double?] {
        var previous = 0.0
        return rows.map { row in
            guard let volume = row.volume, volume.isFinite else { return nil }
            defer { previous = max(previous, volume) }
            return max(volume - previous, 0)
        }
    }

    /// 一条分时：点，以及到这一分钟为止的累计成交量和累计成交额（美股没有成交额）。
    struct Row {
        var point: IntradayPoint
        var volume: Double?
        var amount: Double?
    }

    static func row(from text: String) -> Row? {
        guard let point = point(from: text) else { return nil }
        let parts = text.split(separator: " ")
        return Row(
            point: point,
            volume: parts.count > 2 ? Double(parts[2]) : nil,
            amount: parts.count > 3 ? Double(parts[3]) : nil
        )
    }

    /// 算每一分钟的成交均价：
    /// - 有累计成交额时（A 股、港股）是成交额除以成交量。A 股的成交量是手、港股是股，
    ///   看最后一条算出来的比值是价格的一百倍左右还是差不多，就知道要不要乘 100。
    /// - 只有累计成交量时（美股）按每分钟新增的成交量给那一分钟的价格加权，是个近似。
    /// 算出来明显不在当天价格范围里的（接口数据有问题）不要。
    static func addingAverages(_ rows: [Row]) -> [IntradayPoint] {
        let prices = rows.map(\.point.price)
        guard let low = prices.min(), let high = prices.max() else { return [] }
        func plausible(_ value: Double) -> Double? {
            value.isFinite && value >= low * 0.9 && value <= high * 1.1 ? value : nil
        }
        if let reference = rows.last(where: { ($0.volume ?? 0) > 0 && ($0.amount ?? 0) > 0 }),
           let volume = reference.volume, let amount = reference.amount {
            let lot: Double = amount / volume / reference.point.price > 10 ? 100 : 1
            return rows.map { row in
                var point = row.point
                if let volume = row.volume, volume > 0, let amount = row.amount, amount > 0 {
                    point.average = plausible(amount / (volume * lot))
                }
                return point
            }
        }
        var weighted = 0.0
        var total = 0.0
        var previous = 0.0
        return rows.map { row in
            var point = row.point
            if let volume = row.volume {
                let added = max(volume - previous, 0)
                previous = max(previous, volume)
                weighted += point.price * added
                total += added
                if total > 0 { point.average = plausible(weighted / total) }
            }
            return point
        }
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

/// 横轴上的一个刻度：位置（0 到 1）和文字。
public struct AxisTick: Equatable, Sendable {
    public var position: Double
    public var label: String

    public init(position: Double, label: String) {
        self.position = position
        self.label = label
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

    /// 横轴下面标的时刻：开盘、午休（美股是中间）、收盘，位置是 0 到 1。
    public static func ticks(for region: MarketRegion) -> [AxisTick] {
        let length = Double(length(for: region))
        let sessions = sessions(for: region)
        guard let first = sessions.first, let last = sessions.last, length > 0 else { return [] }
        func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
        var ticks = [AxisTick(position: 0, label: time(first.lowerBound))]
        if sessions.count > 1 {
            // 上午收盘和下午开盘在横轴上是同一个位置。
            let morning = sessions[0]
            ticks.append(AxisTick(
                position: Double(morning.upperBound - morning.lowerBound) / length,
                label: time(morning.upperBound) + "/" + time(sessions[1].lowerBound)
            ))
        } else {
            let middle = first.lowerBound + (first.upperBound - first.lowerBound) / 2
            ticks.append(AxisTick(position: 0.5, label: time(middle)))
        }
        ticks.append(AxisTick(position: 1, label: time(last.upperBound)))
        return ticks
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
    /// 画成交量柱时用的最大值。开盘那一分钟带着集合竞价的量，常常比别的分钟大好几倍，把别的柱子压得看不见；
    /// 最大的一根超过第二大的 3 倍时按第二大的 1.2 倍画（最大的那根顶到头）。没有成交量时为 nil。
    public var volumeScale: Double? {
        let volumes = points.compactMap(\.volume).filter { $0 > 0 }.sorted(by: >)
        guard let first = volumes.first else { return nil }
        guard volumes.count > 1 else { return first }
        return first > volumes[1] * 3 ? volumes[1] * 1.2 : first
    }

    /// 横轴上离 offset（0 到 IntradayAxis.length）最近的点，鼠标悬停时用。
    public func point(nearest offset: Double, region: MarketRegion) -> IntradayPoint? {
        points.min { lhs, rhs in
            abs(Double(IntradayAxis.offset(of: lhs.minute, region: region)) - offset)
                < abs(Double(IntradayAxis.offset(of: rhs.minute, region: region)) - offset)
        }
    }
}

/// 最近几个交易日的分时（五日图），从早到晚排列。
public struct MultiDaySeries: Equatable, Sendable {
    public var symbol: Symbol
    public var days: [IntradaySeries]
    /// 第一天之前的收盘价，五日图的基准线；接口没给时为 nil。
    public var previousClose: Double?
    /// 每一天各自的昨收，和 days 一一对应，用来算那一天的涨跌幅。
    public var dayPreviousCloses: [Double?]

    public init(symbol: Symbol, days: [IntradaySeries], previousClose: Double?, dayPreviousCloses: [Double?]) {
        self.symbol = symbol
        self.days = days
        self.previousClose = previousClose
        self.dayPreviousCloses = dayPreviousCloses
    }

    public var pointCount: Int { days.reduce(0) { $0 + $1.points.count } }

    /// 横轴位置 fraction（0 到 1）最近的点：第几天、哪个点。每天占一样宽。
    public func point(nearest fraction: Double, region: MarketRegion) -> (day: Int, point: IntradayPoint)? {
        guard !days.isEmpty else { return nil }
        let length = Double(IntradayAxis.length(for: region))
        let offset = min(max(fraction, 0), 1) * Double(days.count) * length
        var day = min(Int(offset / length), days.count - 1)
        // 那一天还没有数据（比如今天还没开盘）时往前找。
        while day > 0, days[day].points.isEmpty { day -= 1 }
        guard let point = days[day].point(nearest: offset - Double(day) * length, region: region) else { return nil }
        return (day, point)
    }
}

/// 五日图的横轴：每天一段，只包含连续交易时段。
public enum MultiDayAxis {
    /// 第 day 天（最早的一天是 0）的 minute 在横轴上的位置（0 到 1）。
    public static func position(day: Int, minute: Int, days: Int, region: MarketRegion) -> Double {
        guard days > 0 else { return 0 }
        let length = Double(IntradayAxis.length(for: region))
        return (Double(day) * length + Double(IntradayAxis.offset(of: minute, region: region))) / (Double(days) * length)
    }
}

/// 解析腾讯五日分时接口的返回。
///
/// - A 股、港股：`https://web.ifzq.gtimg.cn/appstock/app/day/query?code=sh600519`
/// - 美股：`https://web.ifzq.gtimg.cn/appstock/app/dayus/query?code=usAAPL.OQ`（带交易所后缀）
///
/// 返回 `{"data":{"sh600519":{"data":[{"date":"20260928","data":["0930 1236.00 349 43136400.00", …],"prec":"1237.00"}, …]}}}`，
/// 最近的一天在最前面，每天带着那一天的昨收 `prec`。
public enum TencentMultiDayParser {
    public static func parse(_ data: Data, symbol: Symbol) -> MultiDaySeries? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = json["data"] as? [String: Any],
              let entry = (all[symbol.rawValue] ?? (all.count == 1 ? all.values.first : nil)) as? [String: Any],
              let list = entry["data"] as? [Any]
        else { return nil }
        var days: [IntradaySeries] = []
        var closes: [Double?] = []
        for case let day as [String: Any] in list {
            guard let rows = day["data"] as? [String] else { continue }
            let date = (day["date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // 每天的均价各算各的，和分时图一样指数没有。
            let points = TencentMinuteParser.points(rows.compactMap(TencentMinuteParser.row(from:)), isIndex: symbol.isIndex)
            days.append(IntradaySeries(symbol: symbol, date: date, points: points))
            closes.append((day["prec"] as? String).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil })
        }
        // 接口是最近的一天在前，画图要从早到晚。
        days.reverse()
        closes.reverse()
        return MultiDaySeries(symbol: symbol, days: days, previousClose: closes.first ?? nil, dayPreviousCloses: closes)
    }
}
