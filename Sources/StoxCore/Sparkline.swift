import Foundation

/// 列表里每一行的迷你分时：把当天的分时按时间平均分成几段，每段取最后一个价格；还没到的时间是 nil。
/// 横轴和分时图一样只有连续交易时段，午休不占位置。
public struct Sparkline: Equatable, Sendable {
    /// 分成多少段：A 股每段 5 分钟，港股约 7 分钟，美股约 8 分钟，画在 40 来个点宽的地方足够了。
    public static let buckets = 48

    /// 每一段的价格，从开盘到收盘；还没到、这一段没有成交的是 nil。
    public var values: [Double?]
    /// 交易日，和分时一样（`20260929`）；没有时为 nil。
    public var date: String?
    /// 期货的交易日从这个时刻算起，和分时一样（见 IntradaySeries.start）；股票是 nil。
    public var start: Date?

    public init(values: [Double?], date: String? = nil, start: Date? = nil) {
        self.values = values
        self.date = date
        self.start = start
    }

    /// 从一天的分时抽出来。没有点时返回 nil。
    public init?(series: IntradaySeries, region: MarketRegion, buckets: Int = Sparkline.buckets) {
        guard !series.points.isEmpty, buckets > 1 else { return nil }
        var values = [Double?](repeating: nil, count: buckets)
        for point in series.points where point.price > 0 {
            values[Self.bucket(of: point.minute, region: region, buckets: buckets)] = point.price
        }
        guard values.contains(where: { $0 != nil }) else { return nil }
        self.values = values
        self.date = series.date
        self.start = series.start
    }

    /// 某个时刻（交易所当地时间，自零点起的分钟数）落在第几段。开盘前的算第一段，收盘后的算最后一段。
    public static func bucket(of minute: Int, region: MarketRegion, buckets: Int = Sparkline.buckets) -> Int {
        let length = Double(IntradayAxis.length(for: region))
        guard length > 0, buckets > 0 else { return 0 }
        let offset = Double(IntradayAxis.offset(of: minute, region: region))
        return min(max(Int(offset / length * Double(buckets)), 0), buckets - 1)
    }

    /// 用实时行情更新最后一段：两次取分时之间，线的末端跟着现价走。行情不是这一天的、没有时间时不动。
    public func updating(with quote: Quote?, region: MarketRegion) -> Sparkline {
        guard let quote, quote.price > 0, let time = quote.timestamp else { return self }
        if let start {
            // 期货：离开盘多少分钟，在这个交易日的 24 小时里才算。
            let minute = Int(time.timeIntervalSince(start) / 60)
            guard (0..<IntradayAxis.length(for: region)).contains(minute) else { return self }
            var updated = self
            updated.values[Self.bucket(of: minute, region: region, buckets: values.count)] = quote.price
            return updated
        }
        guard let date else { return self }
        let calendar = region.calendar
        let day = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: time)
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day, let hour = day.hour, let minute = day.minute,
              String(format: "%04d%02d%02d", year, month, dayOfMonth) == date
        else { return self }
        var updated = self
        updated.values[Self.bucket(of: hour * 60 + minute, region: region, buckets: values.count)] = quote.price
        return updated
    }

    /// 画出来的纵轴范围：包含所有价格和昨收（reference 大于 0 时），太窄时至少留出昨收的 0.4%，免得一点波动就撑满。
    public func range(reference: Double) -> ClosedRange<Double>? {
        var prices = values.compactMap { $0 }
        guard !prices.isEmpty else { return nil }
        if reference > 0 { prices.append(reference) }
        var low = prices.min()!, high = prices.max()!
        let base = reference > 0 ? reference : (low + high) / 2
        let minimum = base * 0.004
        if high - low < minimum {
            let middle = (high + low) / 2
            low = middle - minimum / 2
            high = middle + minimum / 2
        }
        guard high > low else { return nil }
        return low...high
    }
}
