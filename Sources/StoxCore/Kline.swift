import Foundation

/// K 线的周期。
public enum KlinePeriod: String, CaseIterable, Codable, Sendable {
    case day, week, month
}

/// 一根 K 线。日期是这根 K 线的最后一个交易日（周 K、月 K 也是），例如 `2026-09-28`。
public struct Candle: Equatable, Sendable {
    public var date: String
    public var open: Double
    public var close: Double
    public var high: Double
    public var low: Double

    public init(date: String, open: Double, close: Double, high: Double, low: Double) {
        self.date = date
        self.open = open
        self.close = close
        self.high = high
        self.low = low
    }

    /// 阳线还是阴线：收盘相对开盘。
    public var direction: PriceDirection { PriceDirection(close - open) }
}

/// 一只证券某个周期的 K 线，按时间从早到晚排列。
public struct KlineSeries: Equatable, Sendable {
    public var symbol: Symbol
    public var period: KlinePeriod
    public var candles: [Candle]

    public init(symbol: Symbol, period: KlinePeriod, candles: [Candle]) {
        self.symbol = symbol
        self.period = period
        self.candles = candles
    }

    /// 第 index 根相对前一根收盘的涨跌幅（%）。第一根没有前一根，返回 nil。
    public func changePercent(at index: Int) -> Double? {
        guard index > 0, candles.indices.contains(index) else { return nil }
        let reference = candles[index - 1].close
        guard reference > 0 else { return nil }
        return (candles[index].close - reference) / reference * 100
    }

    /// 用最新行情更新最后一根 K 线，或者在新的交易日、新的一周、新的一月补上一根。
    /// 这样 K 线和列表里的价格一致，不用等下一次请求 K 线接口。
    public func merging(_ quote: Quote) -> KlineSeries {
        guard let last = candles.last, quote.price > 0, let timestamp = quote.timestamp else { return self }
        let region = symbol.market.region
        let day = KlineCalendar.dayString(timestamp, region: region)
        // 接口里的日期比行情还新（行情延时），或者今天还没成交（开盘前），都不动。
        guard day >= last.date else { return self }

        var result = self
        // 新的一天要等开盘（有了开盘价）才补一根；美股盘前已经有成交量，但常规交易还没开始。
        let opened = quote.open > 0
        switch period {
        case .day:
            guard quote.hasTraded, day == last.date || opened else { return self }
            let today = Candle(
                date: day,
                open: quote.open > 0 ? quote.open : quote.price,
                close: quote.price,
                high: max(quote.high, quote.price),
                low: quote.low > 0 ? min(quote.low, quote.price) : quote.price
            )
            if day == last.date {
                result.candles[result.candles.count - 1] = today
            } else {
                result.candles.append(today)
            }
        case .week, .month:
            guard quote.hasTraded else { return self }
            let unit: Calendar.Component = period == .week ? .weekOfYear : .month
            let samePeriod = KlineCalendar.isSame(unit, day, last.date, region: region)
            guard samePeriod || opened else { return self }
            if samePeriod {
                var updated = last
                updated.date = day
                updated.close = quote.price
                updated.high = max(last.high, quote.high, quote.price)
                if quote.low > 0 { updated.low = min(last.low, quote.low) }
                updated.low = min(updated.low, quote.price)
                result.candles[result.candles.count - 1] = updated
            } else {
                result.candles.append(Candle(
                    date: day,
                    open: quote.open > 0 ? quote.open : quote.price,
                    close: quote.price,
                    high: max(quote.high, quote.price),
                    low: quote.low > 0 ? min(quote.low, quote.price) : quote.price
                ))
            }
        }
        return result
    }
}

/// K 线图上画的东西：最后几根 K 线、每根的涨跌幅和收盘价均线。
/// 向接口多要的那些历史只用来算均线和第一根的涨跌，不画出来，这样均线从图的最左边就有。
public struct KlineChartData: Equatable, Sendable {
    /// 图上显示多少根。
    public static let visibleCount = 60
    /// 均线的根数：MA5、MA10、MA20。
    public static let averagePeriods = [5, 10, 20]
    /// 向接口要多少根：比显示的多出最长的均线要用的那些。
    public static var fetchCount: Int { visibleCount + (averagePeriods.max() ?? 0) }

    public var period: KlinePeriod
    public var candles: [Candle]
    /// 每根相对前一根收盘的涨跌幅（%）；前面没有 K 线的那一根为 nil。
    public var changes: [Double?]
    /// 均线，和 averagePeriods 一一对应；每条和 candles 一一对应，前面的根数不够算时为 nil。
    public var averages: [[Double?]]

    public init(series: KlineSeries, visibleCount: Int = KlineChartData.visibleCount, averagePeriods: [Int] = KlineChartData.averagePeriods) {
        let all = series.candles
        let start = max(0, all.count - visibleCount)
        period = series.period
        candles = Array(all[start...])
        changes = (start..<all.count).map { series.changePercent(at: $0) }
        // 收盘价的前缀和，sums[i] 是前 i 根的和。
        var sums = [0.0]
        sums.reserveCapacity(all.count + 1)
        for candle in all { sums.append(sums[sums.count - 1] + candle.close) }
        averages = averagePeriods.map { n in
            (start..<all.count).map { index -> Double? in
                guard n > 0, index + 1 >= n else { return nil }
                return (sums[index + 1] - sums[index + 1 - n]) / Double(n)
            }
        }
    }

    /// 纵轴要容下的范围：K 线的最高最低，画均线时再加上图上的均线值。
    public func priceRange(includingAverages: Bool) -> (low: Double, high: Double)? {
        var values = candles.flatMap { [$0.low, $0.high] }
        if includingAverages {
            values += averages.flatMap { $0.compactMap { $0 } }
        }
        guard let low = values.min(), let high = values.max() else { return nil }
        return (low, high)
    }

    /// 这一段的涨跌幅（%）：最后一根的收盘相对第一根的开盘。
    public var totalChangePercent: Double? {
        guard candles.count > 1, let first = candles.first, let last = candles.last, first.open > 0 else { return nil }
        return (last.close - first.open) / first.open * 100
    }
}

/// K 线日期的换算，都按交易所当地时间。
enum KlineCalendar {
    static func calendar(for region: MarketRegion) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = region.timeZone
        // 周 K 从周一开始。
        calendar.firstWeekday = 2
        return calendar
    }

    static func dayString(_ date: Date, region: MarketRegion) -> String {
        let c = calendar(for: region).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(from day: String, region: MarketRegion) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        // 取当天中午，避开夏令时切换的零点。
        return calendar(for: region).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// 两个日期是否在同一周（周一到周日）或同一个月。
    static func isSame(_ unit: Calendar.Component, _ a: String, _ b: String, region: MarketRegion) -> Bool {
        guard let first = date(from: a, region: region), let second = date(from: b, region: region) else { return false }
        let calendar = calendar(for: region)
        guard let lhs = calendar.dateInterval(of: unit, for: first), let rhs = calendar.dateInterval(of: unit, for: second) else {
            return false
        }
        return lhs.start == rhs.start
    }
}

/// 解析腾讯 K 线接口的返回。
///
/// - A 股：`https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=sh600519,day,,,60,qfq`
/// - 港股：`https://web.ifzq.gtimg.cn/appstock/app/hkfqkline/get?param=hk00700,day,,,60,qfq`
/// - 美股：`https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usAAPL.OQ,day,,,60,qfq`，
///   个股要带交易所后缀，否则只返回很久以前的一根和今天的一根。
///
/// 返回 `{"code":0,"data":{"sh600519":{"qfqday":[["2026-09-28","1236.000","1243.880","1244.010","1228.100","28218.000"], …]}}}`，
/// 每条是“日期 开 收 高 低 成交量”，后面可能跟着分红、回购等附加信息。前复权数据的键是 `qfqday`、`qfqweek`、`qfqmonth`；
/// 指数和没有复权数据的证券是 `day`、`week`、`month`。
public enum TencentKlineParser {
    public static func parse(_ data: Data, symbol: Symbol, period: KlinePeriod) -> KlineSeries? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = json["data"] as? [String: Any]
        else { return nil }
        // 美股的键带交易所后缀（usAAPL.OQ），和自选里的代码对不上；只请求了一只，直接取唯一的那个。
        let value = all[symbol.rawValue] ?? (all.count == 1 ? all.values.first : nil)
        guard let entry = value as? [String: Any],
              let rows = (entry["qfq" + period.rawValue] ?? entry[period.rawValue]) as? [Any]
        else { return nil }
        let candles = rows.compactMap { ($0 as? [Any]).flatMap(candle(from:)) }
        return KlineSeries(symbol: symbol, period: period, candles: candles)
    }

    static func candle(from row: [Any]) -> Candle? {
        guard row.count >= 5, let date = row[0] as? String, date.count == 10 else { return nil }
        func number(_ index: Int) -> Double? {
            if let text = row[index] as? String { return Double(text) }
            return row[index] as? Double
        }
        guard let open = number(1), let close = number(2), let high = number(3), let low = number(4),
              open > 0, close > 0, high > 0, low > 0
        else { return nil }
        return Candle(date: date, open: open, close: close, high: max(high, open, close), low: min(low, open, close))
    }
}

/// K 线图的横向排布：每根占一格，从左往右排。根数少（新股）时格子也不会太宽。
public struct CandleLayout: Equatable, Sendable {
    /// 至少按这么多格来分宽度。
    public static let minimumSlots = 40

    public let count: Int
    public let width: Double

    public init(count: Int, width: Double) {
        self.count = count
        self.width = width
    }

    /// 每一格的宽度。
    public var slot: Double { width / Double(max(count, Self.minimumSlots)) }

    /// 实体的宽度：格子的七成，最窄 1、最宽 8。
    public var bodyWidth: Double { max(1, min(slot * 0.7, 8)) }

    /// 第 index 根的中线位置。
    public func centerX(of index: Int) -> Double {
        (Double(index) + 0.5) * slot
    }

    /// 鼠标在 x 处时指着哪一根；右边空着的地方算最后一根。
    public func index(at x: Double) -> Int? {
        guard count > 0, slot > 0 else { return nil }
        return min(max(Int((x / slot).rounded(.down)), 0), count - 1)
    }
}
