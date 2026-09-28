import SwiftUI
import StoxCore

/// 展开后的分时图：当天的价格走势，虚线是昨收。横轴按交易时段排，午休不占位置，
/// 所以上午收盘和下午开盘接在一起，还没到的时间留空。鼠标指着的点画一条竖线和一个圆点。
struct IntradayChart: View {
    static let height: CGFloat = 56

    let series: IntradaySeries?
    let previousClose: Double
    let region: MarketRegion
    let color: Color
    var hovered: IntradayPoint?

    var body: some View {
        GeometryReader { proxy in
            if let scale = Self.scale(series: series, previousClose: previousClose, region: region, size: proxy.size) {
                let paths = scale.paths
                ZStack {
                    paths.area
                        .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    paths.baseline
                        .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
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
    }

    /// 价格和时刻到图上坐标的换算。纵轴包含昨收，涨跌很小时至少留出昨收 0.4% 的范围，免得一点波动就撑满。
    struct Scale {
        let points: [IntradayPoint]
        let region: MarketRegion
        let size: CGSize
        let top: Double
        let bottom: Double
        let reference: Double

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
            return ChartPaths(line: line, area: area, baseline: baseline)
        }
    }

    static func scale(series: IntradaySeries?, previousClose: Double, region: MarketRegion, size: CGSize) -> Scale? {
        guard let points = series?.points, points.count > 1, size.width > 0, size.height > 0 else { return nil }
        let prices = points.map(\.price) + (previousClose > 0 ? [previousClose] : [])
        guard let low = prices.min(), let high = prices.max() else { return nil }
        let reference = previousClose > 0 ? previousClose : (high + low) / 2
        let span = max(high - low, reference * 0.004)
        let middle = (high + low) / 2
        return Scale(
            points: points, region: region, size: size,
            top: middle + span * 0.55, bottom: middle - span * 0.55, reference: reference
        )
    }
}

/// 五日图：最近五个交易日的分时连在一起，每天占一样宽，竖线分开各天，虚线是第一天的昨收。
struct FiveDayChart: View {
    let series: MultiDaySeries?
    let region: MarketRegion
    let color: Color
    /// 鼠标指着的那一天和那一点。
    var hovered: (day: Int, point: IntradayPoint)?

    var body: some View {
        GeometryReader { proxy in
            if let series, let scale = Scale(series: series, region: region, size: proxy.size) {
                ZStack {
                    scale.separators
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    scale.area
                        .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    if let baseline = scale.baseline {
                        baseline
                            .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
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

    /// 坐标换算。纵轴包含第一天的昨收，和分时图一样至少留出 0.4% 的范围。
    struct Scale {
        let series: MultiDaySeries
        let region: MarketRegion
        let size: CGSize
        let top: Double
        let bottom: Double

        init?(series: MultiDaySeries, region: MarketRegion, size: CGSize) {
            let prices = series.days.flatMap { $0.points.map(\.price) } + (series.previousClose.map { [$0] } ?? [])
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
