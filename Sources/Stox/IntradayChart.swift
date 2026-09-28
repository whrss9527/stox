import SwiftUI
import StoxCore

/// 展开后的分时图：当天的价格走势，虚线是昨收。横轴按交易时段排，午休不占位置，
/// 所以上午收盘和下午开盘接在一起，还没到的时间留空。
struct IntradayChart: View {
    static let height: CGFloat = 44

    let series: IntradaySeries?
    let previousClose: Double
    let region: MarketRegion
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            if let paths = Self.paths(series: series, previousClose: previousClose, region: region, size: proxy.size) {
                ZStack {
                    paths.area
                        .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    paths.baseline
                        .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    paths.line
                        .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
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

    /// 把分时点换算成图上的路径。纵轴包含昨收，涨跌很小时至少留出昨收 0.4% 的范围，免得一点波动就撑满。
    static func paths(series: IntradaySeries?, previousClose: Double, region: MarketRegion, size: CGSize) -> ChartPaths? {
        guard let points = series?.points, points.count > 1, size.width > 0, size.height > 0 else { return nil }
        let prices = points.map(\.price) + (previousClose > 0 ? [previousClose] : [])
        guard let low = prices.min(), let high = prices.max() else { return nil }
        let reference = previousClose > 0 ? previousClose : (high + low) / 2
        let span = max(high - low, reference * 0.004)
        let middle = (high + low) / 2
        let top = middle + span * 0.55
        let bottom = middle - span * 0.55
        let length = CGFloat(IntradayAxis.length(for: region))

        func location(_ point: IntradayPoint) -> CGPoint {
            let x = CGFloat(IntradayAxis.offset(of: point.minute, region: region)) / length * size.width
            let y = CGFloat((top - point.price) / (top - bottom)) * size.height
            return CGPoint(x: x, y: y)
        }

        let locations = points.map(location)
        var line = Path()
        line.addLines(locations)
        var area = line
        if let first = locations.first, let last = locations.last {
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
        }
        let baseY = CGFloat((top - reference) / (top - bottom)) * size.height
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: baseY))
        baseline.addLine(to: CGPoint(x: size.width, y: baseY))
        return ChartPaths(line: line, area: area, baseline: baseline)
    }
}
