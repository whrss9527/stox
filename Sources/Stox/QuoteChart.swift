import SwiftUI
import StoxCore

/// 展开详情里的走势图：上面一排“分时 日K 周K 月K”，下面是图。鼠标移到图上时，
/// 那一排换成指着的那一点的价格（分时）或开高低收（K 线）。
@MainActor
struct QuoteChartSection: View {
    static let headerHeight: CGFloat = 16
    static let spacing: CGFloat = 4
    static let height: CGFloat = headerHeight + spacing + IntradayChart.height

    let item: WatchItem
    let quote: Quote

    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    /// 鼠标在图上的横坐标。
    @State private var hoverX: CGFloat?
    @State private var chartWidth: CGFloat = 0

    private struct TrackID: Hashable {
        var symbol: Symbol
        var period: ChartPeriod
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            header
                .frame(height: Self.headerHeight)
            chart
                .frame(height: IntradayChart.height)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { chartWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { chartWidth = $0 }
                })
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
        }
        .task(id: TrackID(symbol: item.symbol, period: settings.chartPeriod)) {
            switch settings.chartPeriod {
            case .intraday:
                await store.trackIntraday(item.symbol)
            case .fiveDay:
                await store.trackFiveDay(item.symbol)
            case .day, .week, .month:
                if let period = settings.chartPeriod.klinePeriod {
                    await store.trackKline(item.symbol, period: period)
                }
            }
        }
    }

    // MARK: - 图

    private var region: MarketRegion { item.symbol.market.region }

    private var intradaySeries: IntradaySeries? { store.intraday[item.symbol] }

    /// K 线接口的数据，最后一根用实时行情更新过。
    private var klineSeries: KlineSeries? {
        guard let period = settings.chartPeriod.klinePeriod,
              let series = store.klines[KlineKey(symbol: item.symbol, period: period)]
        else { return nil }
        return series.merging(quote)
    }

    private var fiveDaySeries: MultiDaySeries? { store.fiveDay[item.symbol] }

    @ViewBuilder
    private var chart: some View {
        switch settings.chartPeriod {
        case .intraday:
            IntradayChart(
                series: intradaySeries,
                previousClose: quote.previousClose,
                region: region,
                color: Theme.priceColor(for: quote.direction, convention: settings.colorConvention),
                hovered: hoveredPoint
            )
        case .fiveDay:
            FiveDayChart(
                series: fiveDaySeries,
                region: region,
                color: Theme.priceColor(for: fiveDayDirection, convention: settings.colorConvention),
                hovered: hoveredFiveDay
            )
        case .day, .week, .month:
            KlineChart(
                series: klineSeries,
                convention: settings.colorConvention,
                hoveredIndex: hoveredCandle(in: klineSeries)
            )
        }
    }

    /// 五日里最新的价格，和第一天的昨收比。
    private var fiveDayLast: Double? {
        fiveDaySeries?.days.last(where: { !$0.points.isEmpty })?.points.last?.price
    }

    private var fiveDayDirection: PriceDirection {
        guard let last = fiveDayLast, let base = fiveDaySeries?.previousClose else { return quote.direction }
        return PriceDirection(last - base)
    }

    private var hoveredFiveDay: (day: Int, point: IntradayPoint)? {
        guard let hoverX, chartWidth > 0, let series = fiveDaySeries, series.pointCount > 1 else { return nil }
        return series.point(nearest: Double(hoverX / chartWidth), region: region)
    }

    private var hoveredPoint: IntradayPoint? {
        guard let hoverX, chartWidth > 0, let series = intradaySeries, series.points.count > 1 else { return nil }
        let offset = Double(hoverX / chartWidth) * Double(IntradayAxis.length(for: region))
        return series.point(nearest: offset, region: region)
    }

    private func hoveredCandle(in series: KlineSeries?) -> Int? {
        guard let hoverX, chartWidth > 0, let series else { return nil }
        return CandleLayout(count: series.candles.count, width: Double(chartWidth)).index(at: Double(hoverX))
    }

    // MARK: - 上面一排

    @ViewBuilder
    private var header: some View {
        if let readout {
            Text(readout)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 2) {
                ForEach(ChartPeriod.allCases) { period in
                    tab(period)
                }
                Spacer(minLength: 4)
                if let summary {
                    Text(summary)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func tab(_ period: ChartPeriod) -> some View {
        let selected = settings.chartPeriod == period
        return Button {
            settings.chartPeriod = period
        } label: {
            Text(period.title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .frame(height: Self.headerHeight)
                .background(Capsule().fill(Color.primary.opacity(selected ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(period.title)走势（展开时也可以用 ← → 切换）")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 没有指着图时，右边显示这一段的涨跌，例如“近 60 日 -8.12%”。
    private var summary: String? {
        if settings.chartPeriod == .fiveDay {
            guard let series = fiveDaySeries, let last = fiveDayLast, let base = series.previousClose, base > 0 else { return nil }
            return "近 \(series.days.count) 日 \(QuoteFormatter.percent((last - base) / base * 100))"
        }
        guard let series = klineSeries, let first = series.candles.first, let last = series.candles.last,
              series.candles.count > 1, first.open > 0
        else { return nil }
        let unit: String
        switch series.period {
        case .day: unit = "日"
        case .week: unit = "周"
        case .month: unit = "个月"
        }
        return "近 \(series.candles.count) \(unit) \(QuoteFormatter.percent((last.close - first.open) / first.open * 100))"
    }

    /// 指着图时显示的读数。
    private var readout: String? {
        let decimals = quote.priceDecimals
        func price(_ value: Double) -> String { QuoteFormatter.price(value, decimals: decimals) }
        if settings.chartPeriod == .fiveDay {
            guard let series = fiveDaySeries, let hovered = hoveredFiveDay else { return nil }
            let day = hovered.day
            let point = hovered.point
            var text = ""
            if let date = series.days[day].date, date.count == 8 {
                text += "\(date.dropFirst(4).prefix(2))-\(date.suffix(2))  "
            }
            text += String(format: "%02d:%02d  ", point.minute / 60, point.minute % 60) + price(point.price)
            if let reference = series.dayPreviousCloses[day], reference > 0 {
                text += "  " + QuoteFormatter.percent((point.price - reference) / reference * 100)
            }
            return text
        }
        if settings.chartPeriod.klinePeriod == nil {
            guard let point = hoveredPoint else { return nil }
            var text = String(format: "%02d:%02d  ", point.minute / 60, point.minute % 60) + price(point.price)
            if quote.previousClose > 0 {
                text += "  " + QuoteFormatter.percent((point.price - quote.previousClose) / quote.previousClose * 100)
            }
            return text
        }
        guard let series = klineSeries, let index = hoveredCandle(in: series) else { return nil }
        let candle = series.candles[index]
        let date = series.period == .month ? String(candle.date.prefix(7)) : candle.date
        var text = "\(date)  开 \(price(candle.open))  高 \(price(candle.high))  低 \(price(candle.low))  收 \(price(candle.close))"
        if let change = series.changePercent(at: index) {
            text += "  " + QuoteFormatter.percent(change)
        }
        return text
    }
}

/// K 线图：每根一个实体加上下影线，红涨绿跌跟着设置走。不显示红绿时阳线空心、阴线实心。
struct KlineChart: View {
    let series: KlineSeries?
    let convention: ColorConvention
    var hoveredIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            if let series, !series.candles.isEmpty {
                Canvas { context, size in
                    draw(series.candles, in: &context, size: size)
                }
            } else {
                Text(series == nil ? "正在加载 K 线…" : "暂时没有 K 线数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: IntradayChart.height)
        .accessibilityLabel("K 线走势")
    }

    private func draw(_ candles: [Candle], in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0,
              let high = candles.map(\.high).max(), let low = candles.map(\.low).min()
        else { return }
        // 上下各留一点边，最高最低点不贴着边；一动不动时给 1% 的范围。
        let span = max(high - low, high * 0.01, 0.0001)
        let top = high + span * 0.06
        let bottom = low - span * 0.06
        func y(_ price: Double) -> CGFloat {
            CGFloat((top - price) / (top - bottom)) * size.height
        }
        let layout = CandleLayout(count: candles.count, width: Double(size.width))
        let bodyWidth = CGFloat(layout.bodyWidth)

        if let hoveredIndex, candles.indices.contains(hoveredIndex) {
            let x = CGFloat(layout.centerX(of: hoveredIndex))
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.secondary.opacity(0.7)), lineWidth: 0.6)
        }

        for (index, candle) in candles.enumerated() {
            // 对齐到半个点，Retina 屏上 1 点宽的影线不发虚。
            let x = (CGFloat(layout.centerX(of: index)) * 2).rounded() / 2
            let tint = color(for: candle.direction)
            let bodyTop = y(max(candle.open, candle.close))
            let bodyBottom = max(y(min(candle.open, candle.close)), bodyTop + 1)

            // 上影线和下影线分开画，空心的实体里面不会穿过一条线。
            var wick = Path()
            wick.move(to: CGPoint(x: x, y: y(candle.high)))
            wick.addLine(to: CGPoint(x: x, y: bodyTop))
            wick.move(to: CGPoint(x: x, y: bodyBottom))
            wick.addLine(to: CGPoint(x: x, y: y(candle.low)))
            context.stroke(wick, with: .color(tint), lineWidth: 1)

            let rect = CGRect(x: x - bodyWidth / 2, y: bodyTop, width: bodyWidth, height: bodyBottom - bodyTop)
            if convention == .neutral, candle.direction == .up, bodyWidth >= 3 {
                context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(tint), lineWidth: 1)
            } else {
                context.fill(Path(rect), with: .color(tint))
            }
        }
    }

    private func color(for direction: PriceDirection) -> Color {
        if convention == .neutral {
            return Color.primary.opacity(0.75)
        }
        return Theme.priceColor(for: direction, convention: convention)
    }
}
