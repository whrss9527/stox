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

    var body: some View {
        GeometryReader { proxy in
            if let scale = Self.scale(
                series: series, previousClose: previousClose, region: region, size: proxy.size, includingAverages: showAverage
            ) {
                let paths = scale.paths
                ZStack {
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
            return ChartPaths(line: line, area: area, baseline: baseline, average: average)
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
            high: high, low: low
        )
    }
}

/// 五日图：最近五个交易日的分时连在一起，每天占一样宽，竖线分开各天，虚线是第一天的昨收，
/// 橙色的线是每天各自的成交均价（个股才有）。
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
                ZStack {
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
