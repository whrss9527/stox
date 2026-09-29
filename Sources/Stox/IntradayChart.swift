import SwiftUI
import StoxCore

/// 展开后的分时图：当天的价格走势，虚线是昨收，橙色的线是成交均价（个股才有），有持仓时青色的虚线是成本价。横轴按交易时段排，
/// 午休不占位置，所以上午收盘和下午开盘接在一起，还没到的时间留空。鼠标指着的点画一条竖线和一个圆点。
struct IntradayChart: View {
    static let height: CGFloat = 56
    static let averageColor = Color.orange

    let series: IntradaySeries?
    let previousClose: Double
    let region: MarketRegion
    let color: Color
    var hovered: IntradayPoint?
    var showAverage = true
    /// 左上、左下角标的价格用几位小数。
    var decimals = 2
    /// 持仓成本价：落在图的范围里时画一条虚线，不画时为 nil。
    var cost: Double?
    /// 成交量柱的颜色跟着涨跌颜色的设置走。
    var convention: ColorConvention = .redUp

    var body: some View {
        GeometryReader { proxy in
            if let scale = Self.scale(
                series: series, previousClose: previousClose, region: region, size: proxy.size, includingAverages: showAverage
            ) {
                let paths = scale.paths
                ZStack {
                    // 成交量柱在最下面四分之一，淡淡的，价格线压在上面。
                    paths.volumeUp.fill(volumeColor(.up))
                    paths.volumeDown.fill(volumeColor(.down))
                    paths.volumeFlat.fill(volumeColor(.flat))
                    paths.area
                        .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    paths.baseline
                        .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    ChartRangeLabels(high: scale.high, low: scale.low, reference: previousClose, decimals: decimals)
                    // 成本线的字写在中间，四个角留给最高最低。
                    if let cost, cost > scale.bottom, cost < scale.top {
                        let costY = scale.y(cost)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: costY))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: costY))
                        }
                        .stroke(KlineChart.costColor, style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                        Text("成本 " + QuoteFormatter.price(cost, decimals: decimals))
                            .font(.system(size: 8, weight: .medium).monospacedDigit())
                            .foregroundStyle(KlineChart.costColor)
                            .padding(.horizontal, 2)
                            .background(RoundedRectangle(cornerRadius: 2).fill(KlineChart.labelBackground))
                            .fixedSize()
                            .position(x: proxy.size.width / 2, y: max(costY - 7, 6))
                    }
                    if showAverage {
                        paths.average
                            .stroke(Self.averageColor.opacity(0.9), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                    }
                    paths.line
                        .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    if let hovered {
                        let location = scale.location(of: hovered)
                        Path { path in
                            path.move(to: CGPoint(x: location.x, y: 0))
                            path.addLine(to: CGPoint(x: location.x, y: proxy.size.height))
                        }
                        .stroke(Color.secondary.opacity(0.7), lineWidth: 0.6)
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .position(location)
                    }
                }
            } else {
                Text(series == nil ? "正在加载分时…" : "今天还没有分时数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: Self.height)
        .accessibilityLabel("分时走势")
    }

    struct ChartPaths {
        var line: Path
        var area: Path
        var baseline: Path
        /// 均价线；没有均价的点断开。
        var average: Path
        /// 成交量柱，按这一分钟比上一分钟涨了、跌了还是平的分开，好上不同的颜色。
        var volumeUp = Path()
        var volumeDown = Path()
        var volumeFlat = Path()
    }

    private func volumeColor(_ direction: PriceDirection) -> Color {
        if convention == .neutral { return Color.primary.opacity(0.18) }
        return Theme.priceColor(for: direction, convention: convention).opacity(0.3)
    }

    /// 价格和时刻到图上坐标的换算。纵轴包含昨收，涨跌很小时至少留出昨收 0.4% 的范围，免得一点波动就撑满。
    struct Scale {
        let points: [IntradayPoint]
        let region: MarketRegion
        let size: CGSize
        let top: Double
        let bottom: Double
        let reference: Double
        /// 图上画出来的最高、最低的值（价格、均价、昨收），标在左上角和左下角。
        let high: Double
        let low: Double
        /// 成交量柱画满四分之一高度时对应的量；没有成交量时为 nil。
        var volumeScale: Double?

        func location(of point: IntradayPoint) -> CGPoint {
            let length = CGFloat(IntradayAxis.length(for: region))
            let x = CGFloat(IntradayAxis.offset(of: point.minute, region: region)) / length * size.width
            return CGPoint(x: x, y: y(point.price))
        }

        func y(_ price: Double) -> CGFloat {
            CGFloat((top - price) / (top - bottom)) * size.height
        }

        var paths: ChartPaths {
            let locations = points.map(location(of:))
            var line = Path()
            line.addLines(locations)
            var area = line
            if let first = locations.first, let last = locations.last {
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
            }
            let baseY = y(reference)
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: baseY))
            baseline.addLine(to: CGPoint(x: size.width, y: baseY))
            var average = Path()
            var drawing = false
            for (point, location) in zip(points, locations) {
                guard let value = point.average else {
                    drawing = false
                    continue
                }
                let target = CGPoint(x: location.x, y: y(value))
                if drawing {
                    average.addLine(to: target)
                } else {
                    average.move(to: target)
                    drawing = true
                }
            }
            var paths = ChartPaths(line: line, area: area, baseline: baseline, average: average)
            // 成交量柱：一分钟一根，最高到图的四分之一；开盘那根特别高时顶到头（见 volumeScale）。
            if let scale = volumeScale, scale > 0 {
                let band = size.height * 0.25
                let step = size.width / CGFloat(max(IntradayAxis.length(for: region), 1))
                let width = max(step - 0.3, 0.8)
                var previous = reference
                for (point, location) in zip(points, locations) {
                    defer { previous = point.price }
                    guard let volume = point.volume, volume > 0 else { continue }
                    let height = max(CGFloat(min(volume / scale, 1)) * band, 0.5)
                    let bar = CGRect(x: location.x - width / 2, y: size.height - height, width: width, height: height)
                    switch PriceDirection(point.price - previous) {
                    case .up: paths.volumeUp.addRect(bar)
                    case .down: paths.volumeDown.addRect(bar)
                    case .flat: paths.volumeFlat.addRect(bar)
                    }
                }
            }
            return paths
        }
    }

    /// 纵轴包含价格、昨收，画均价线时也包含均价。
    static func scale(
        series: IntradaySeries?, previousClose: Double, region: MarketRegion, size: CGSize, includingAverages: Bool = false
    ) -> Scale? {
        guard let points = series?.points, points.count > 1, size.width > 0, size.height > 0 else { return nil }
        var prices = points.map(\.price)
        if previousClose > 0 { prices.append(previousClose) }
        if includingAverages { prices += points.compactMap(\.average) }
        guard let low = prices.min(), let high = prices.max() else { return nil }
        let reference = previousClose > 0 ? previousClose : (high + low) / 2
        let span = max(high - low, reference * 0.004)
        let middle = (high + low) / 2
        return Scale(
            points: points, region: region, size: size,
            top: middle + span * 0.55, bottom: middle - span * 0.55, reference: reference,
            high: high, low: low, volumeScale: series?.volumeScale
        )
    }
}

/// 五日图：最近五个交易日的分时连在一起，每天占一样宽，竖线分开各天，虚线是第一天的昨收，
/// 橙色的线是每天各自的成交均价（个股才有），最下面淡淡的是成交量柱。
struct FiveDayChart: View {
    let series: MultiDaySeries?
    let region: MarketRegion
    let color: Color
    /// 鼠标指着的那一天和那一点。
    var hovered: (day: Int, point: IntradayPoint)?
    var showAverage = true
    var decimals = 2

    var body: some View {
        GeometryReader { proxy in
            if let series, let scale = Scale(series: series, region: region, size: proxy.size, includingAverages: showAverage) {
                // 成交量柱：每 2 个点宽一根，在最下面四分之一，淡淡的，价格线压在上面。
                let volumes = series.volumeBuckets(count: max(Int(proxy.size.width / 2), 1), region: region)
                ZStack {
                    if let cap = MultiDaySeries.volumeCap(volumes) {
                        VolumeBars(values: volumes, cap: cap)
                            .fill(Color.primary.opacity(0.16))
                    }
                    scale.separators
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    scale.area
                        .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    if let baseline = scale.baseline {
                        baseline
                            .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    }
                    ChartRangeLabels(high: scale.high, low: scale.low, reference: series.previousClose ?? 0, decimals: decimals)
                    if showAverage {
                        scale.averages
                            .stroke(IntradayChart.averageColor.opacity(0.9), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                    }
                    scale.line
                        .stroke(color, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                    if let hovered {
                        let location = scale.location(day: hovered.day, point: hovered.point)
                        Path { path in
                            path.move(to: CGPoint(x: location.x, y: 0))
                            path.addLine(to: CGPoint(x: location.x, y: proxy.size.height))
                        }
                        .stroke(Color.secondary.opacity(0.7), lineWidth: 0.6)
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .position(location)
                    }
                }
            } else {
                Text(series == nil ? "正在加载五日…" : "暂时没有五日数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: IntradayChart.height)
        .accessibilityLabel("五日走势")
    }

    /// 坐标换算。纵轴包含第一天的昨收（画均价线时也包含均价），和分时图一样至少留出 0.4% 的范围。
    struct Scale {
        let series: MultiDaySeries
        let region: MarketRegion
        let size: CGSize
        let top: Double
        let bottom: Double
        let high: Double
        let low: Double

        init?(series: MultiDaySeries, region: MarketRegion, size: CGSize, includingAverages: Bool = false) {
            var prices = series.days.flatMap { $0.points.map(\.price) }
            if let previousClose = series.previousClose { prices.append(previousClose) }
            if includingAverages { prices += series.days.flatMap { $0.points.compactMap(\.average) } }
            guard series.pointCount > 1, size.width > 0, size.height > 0,
                  let low = prices.min(), let high = prices.max()
            else { return nil }
            let reference = series.previousClose ?? (high + low) / 2
            let span = max(high - low, reference * 0.004)
            let middle = (high + low) / 2
            self.series = series
            self.region = region
            self.size = size
            top = middle + span * 0.55
            bottom = middle - span * 0.55
            self.high = high
            self.low = low
        }

        func y(_ price: Double) -> CGFloat {
            CGFloat((top - price) / (top - bottom)) * size.height
        }

        func location(day: Int, point: IntradayPoint) -> CGPoint {
            let x = MultiDayAxis.position(day: day, minute: point.minute, days: series.days.count, region: region)
            return CGPoint(x: CGFloat(x) * size.width, y: y(point.price))
        }

        private var locations: [CGPoint] {
            series.days.enumerated().flatMap { day, daySeries in daySeries.points.map { location(day: day, point: $0) } }
        }

        var line: Path {
            var path = Path()
            path.addLines(locations)
            return path
        }

        var area: Path {
            let points = locations
            var path = Path()
            path.addLines(points)
            if let first = points.first, let last = points.last {
                path.addLine(to: CGPoint(x: last.x, y: size.height))
                path.addLine(to: CGPoint(x: first.x, y: size.height))
                path.closeSubpath()
            }
            return path
        }

        /// 每天各自的均价线，天与天之间断开。
        var averages: Path {
            var path = Path()
            for (day, daySeries) in series.days.enumerated() {
                var drawing = false
                for point in daySeries.points {
                    guard let average = point.average else {
                        drawing = false
                        continue
                    }
                    let target = CGPoint(x: location(day: day, point: point).x, y: y(average))
                    if drawing {
                        path.addLine(to: target)
                    } else {
                        path.move(to: target)
                        drawing = true
                    }
                }
            }
            return path
        }

        var baseline: Path? {
            guard let previousClose = series.previousClose else { return nil }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(previousClose)))
            path.addLine(to: CGPoint(x: size.width, y: y(previousClose)))
            return path
        }

        var separators: Path {
            var path = Path()
            let count = series.days.count
            guard count > 1 else { return path }
            for day in 1..<count {
                let x = (CGFloat(day) / CGFloat(count) * size.width * 2).rounded() / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            return path
        }
    }
}

/// 分时图、五日图四个角上的小字：左边是图上最高、最低的价格，右边是它们相对基准（昨收）的涨跌幅。
struct ChartRangeLabels: View {
    let high: Double
    let low: Double
    /// 算涨跌幅的基准；没有时（为 0）右边不标。
    let reference: Double
    let decimals: Int

    var body: some View {
        VStack(spacing: 0) {
            row(high)
            Spacer(minLength: 0)
            row(low)
        }
        .font(.system(size: 8).monospacedDigit())
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(_ value: Double) -> some View {
        HStack(spacing: 0) {
            Text(QuoteFormatter.price(value, decimals: decimals))
            Spacer(minLength: 4)
            if reference > 0 {
                Text(QuoteFormatter.percent((value - reference) / reference * 100))
            }
        }
        .lineLimit(1)
    }
}

/// 走势图下面的横轴文字：第一个靠左、最后一个靠右，中间的居中对在位置上，都不超出图的两边。
struct ChartAxis: View {
    let ticks: [AxisTick]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(ticks.indices, id: \.self) { index in
                    let tick = ticks[index]
                    Text(tick.label)
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .alignmentGuide(.leading) { dimensions in
                            let x = CGFloat(tick.position) * proxy.size.width
                            return -min(max(x - dimensions.width / 2, 0), max(proxy.size.width - dimensions.width, 0))
                        }
                }
            }
            .frame(width: proxy.size.width, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }
}

/// 五日图下面的成交量柱：values 平均排满横轴，cap 对应最下面四分之一的高度，更高的顶到头。
struct VolumeBars: Shape {
    let values: [Double]
    let cap: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty, cap > 0 else { return path }
        let step = rect.width / CGFloat(values.count)
        let full = rect.height / 4
        for (index, value) in values.enumerated() where value > 0 {
            let height = max(full * CGFloat(min(value / cap, 1)), 0.5)
            path.addRect(CGRect(x: rect.minX + CGFloat(index) * step + step * 0.15, y: rect.maxY - height, width: max(step * 0.7, 0.5), height: height))
        }
        return path
    }
}

/// 列表里一行的迷你分时：一条细线，虚线是昨收。横轴和分时图一样从开盘到收盘，还没到的时间留空。
struct SparklineView: View {
    let sparkline: Sparkline
    /// 昨收，画成虚线；没有时为 0。
    let reference: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard let range = sparkline.range(reference: reference) else { return }
            let count = sparkline.values.count
            func x(_ index: Int) -> CGFloat {
                count > 1 ? CGFloat(index) / CGFloat(count - 1) * size.width : 0
            }
            func y(_ value: Double) -> CGFloat {
                size.height * CGFloat((range.upperBound - value) / (range.upperBound - range.lowerBound))
            }
            if reference > 0 {
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: y(reference)))
                baseline.addLine(to: CGPoint(x: size.width, y: y(reference)))
                context.stroke(baseline, with: .color(Color.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            }
            var line = Path()
            var started = false
            for (index, value) in sparkline.values.enumerated() {
                guard let value else { continue }
                let point = CGPoint(x: x(index), y: y(value))
                if started {
                    line.addLine(to: point)
                } else {
                    line.move(to: point)
                    started = true
                }
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
