import SwiftUI
import StoxCore

/// 展开详情里的走势图：上面一排“分时 日K 周K 月K”，中间是图，下面是时间或日期。鼠标移到图上时，
/// 上面那一排换成指着的那一点的价格（分时）或开高低收（K 线）。
@MainActor
struct QuoteChartSection: View {
    static let headerHeight: CGFloat = 16
    static let spacing: CGFloat = 4
    static let axisHeight: CGFloat = 11
    static let height: CGFloat = headerHeight + spacing + IntradayChart.height + axisHeight

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
            VStack(spacing: 0) {
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
                ChartAxis(ticks: axisTicks)
                    .frame(height: Self.axisHeight, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(settings.chartPeriod.title)走势")
        .accessibilityValue(summary ?? "")
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

    /// K 线图上画的：接口的数据，最后一根用实时行情更新过，只留最后 60 根，带着均线。
    private var klineData: KlineChartData? {
        guard let period = settings.chartPeriod.klinePeriod,
              let series = store.klines[KlineKey(symbol: item.symbol, period: period)]
        else { return nil }
        return KlineChartData(series: series.merging(quote))
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
                hovered: hoveredPoint,
                showAverage: settings.showMovingAverages,
                decimals: quote.priceDecimals
            )
        case .fiveDay:
            FiveDayChart(
                series: fiveDaySeries,
                region: region,
                color: Theme.priceColor(for: fiveDayDirection, convention: settings.colorConvention),
                hovered: hoveredFiveDay,
                showAverage: settings.showMovingAverages,
                decimals: quote.priceDecimals
            )
        case .day, .week, .month:
            let data = klineData
            KlineChart(
                data: data,
                convention: settings.colorConvention,
                hoveredIndex: hoveredCandle(in: data),
                showAverages: settings.showMovingAverages,
                decimals: quote.priceDecimals
            )
        }
    }

    /// 图下面的横轴：分时是开盘、午休、收盘的时刻，五日是每天的日期，K 线是头、中、尾三根的日期。
    private var axisTicks: [AxisTick] {
        switch settings.chartPeriod {
        case .intraday:
            return IntradayAxis.ticks(for: region)
        case .fiveDay:
            guard let days = fiveDaySeries?.days, !days.isEmpty else { return [] }
            return days.indices.compactMap { index in
                guard let date = days[index].date, date.count == 8 else { return nil }
                return AxisTick(
                    position: (Double(index) + 0.5) / Double(days.count),
                    label: "\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
                )
            }
        case .day, .week, .month:
            guard let data = klineData, !data.candles.isEmpty else { return [] }
            let layout = CandleLayout(count: data.candles.count, width: 1)
            let indices = Array(Set([0, data.candles.count / 2, data.candles.count - 1])).sorted()
            return indices.map { index in
                let date = data.candles[index].date
                return AxisTick(position: layout.centerX(of: index), label: data.period == .month ? String(date.prefix(7)) : date)
            }
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

    private func hoveredCandle(in data: KlineChartData?) -> Int? {
        guard let hoverX, chartWidth > 0, let data else { return nil }
        return CandleLayout(count: data.candles.count, width: Double(chartWidth)).index(at: Double(hoverX))
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

    /// 没有指着图时，右边显示这一段的涨跌，例如“近 60 日 -8.12%”；分时图上是最新的成交均价。
    private var summary: String? {
        if settings.chartPeriod == .intraday {
            guard settings.showMovingAverages, let average = intradaySeries?.latestAverage else { return nil }
            return "均价 \(QuoteFormatter.price(average, decimals: quote.priceDecimals))"
        }
        if settings.chartPeriod == .fiveDay {
            guard let series = fiveDaySeries, let last = fiveDayLast, let base = series.previousClose, base > 0 else { return nil }
            return "近 \(series.days.count) 日 \(QuoteFormatter.percent((last - base) / base * 100))"
        }
        guard let data = klineData, let change = data.totalChangePercent else { return nil }
        let unit: String
        switch data.period {
        case .day: unit = "日"
        case .week: unit = "周"
        case .month: unit = "个月"
        }
        return "近 \(data.candles.count) \(unit) \(QuoteFormatter.percent(change))"
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
            if settings.showMovingAverages, let average = point.average {
                text += "  均价 " + price(average)
            }
            return text
        }
        if settings.chartPeriod.klinePeriod == nil {
            guard let point = hoveredPoint else { return nil }
            var text = String(format: "%02d:%02d  ", point.minute / 60, point.minute % 60) + price(point.price)
            if quote.previousClose > 0 {
                text += "  " + QuoteFormatter.percent((point.price - quote.previousClose) / quote.previousClose * 100)
            }
            if settings.showMovingAverages, let average = point.average {
                text += "  均价 " + price(average)
            }
            return text
        }
        guard let data = klineData, let index = hoveredCandle(in: data) else { return nil }
        let candle = data.candles[index]
        let date = data.period == .month ? String(candle.date.prefix(7)) : candle.date
        var text = "\(date)  开 \(price(candle.open))  高 \(price(candle.high))  低 \(price(candle.low))  收 \(price(candle.close))"
        if let change = data.changes[index] {
            text += "  " + QuoteFormatter.percent(change)
        }
        return text
    }
}

/// K 线图：每根一个实体加上下影线，红涨绿跌跟着设置走。不显示红绿时阳线空心、阴线实心。
/// 画均线时上方留一行写 MA5、MA10、MA20 的值：鼠标指着时是那一根的，否则是最后一根的。
struct KlineChart: View {
    static let legendHeight: CGFloat = 11
    /// 三条均线的颜色，和 KlineChartData.averagePeriods 一一对应。
    static let averageColors: [Color] = [.orange, .blue, .purple]

    let data: KlineChartData?
    let convention: ColorConvention
    var hoveredIndex: Int?
    var showAverages = true
    var decimals = 2

    var body: some View {
        GeometryReader { _ in
            if let data, !data.candles.isEmpty {
                VStack(spacing: 0) {
                    if showAverages {
                        legend(data)
                            .frame(height: Self.legendHeight)
                    }
                    Canvas { context, size in
                        draw(data, in: &context, size: size)
                    }
                }
            } else {
                Text(data == nil ? "正在加载 K 线…" : "暂时没有 K 线数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: IntradayChart.height)
        .accessibilityLabel("K 线走势")
    }

    private func legend(_ data: KlineChartData) -> some View {
        let index = hoveredIndex.flatMap { data.candles.indices.contains($0) ? $0 : nil } ?? data.candles.count - 1
        return HStack(spacing: 8) {
            ForEach(0..<min(data.averages.count, KlineChartData.averagePeriods.count), id: \.self) { line in
                let value = data.averages[line][index]
                Text("MA\(KlineChartData.averagePeriods[line]) \(value.map { QuoteFormatter.price($0, decimals: decimals) } ?? "--")")
                    .foregroundStyle(Self.color(ofAverage: line))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9).monospacedDigit())
        .lineLimit(1)
        .accessibilityHidden(true)
    }

    static func color(ofAverage line: Int) -> Color {
        averageColors[line % averageColors.count]
    }

    private func draw(_ data: KlineChartData, in context: inout GraphicsContext, size: CGSize) {
        let candles = data.candles
        guard size.width > 0, size.height > 0, let range = data.priceRange(includingAverages: showAverages) else { return }
        // 上下各留一点边，最高最低点不贴着边；一动不动时给 1% 的范围。
        let span = max(range.high - range.low, range.high * 0.01, 0.0001)
        let top = range.high + span * 0.06
        let bottom = range.low - span * 0.06
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

        guard showAverages else { return }
        // 均线画在 K 线上面；前面根数不够算的地方空着。
        for (line, values) in data.averages.enumerated() {
            var path = Path()
            var drawing = false
            for (index, value) in values.enumerated() {
                guard let value else {
                    drawing = false
                    continue
                }
                let point = CGPoint(x: CGFloat(layout.centerX(of: index)), y: y(value))
                if drawing {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    drawing = true
                }
            }
            context.stroke(
                path, with: .color(Self.color(ofAverage: line).opacity(0.9)),
                style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func color(for direction: PriceDirection) -> Color {
        if convention == .neutral {
            return Color.primary.opacity(0.75)
        }
        return Theme.priceColor(for: direction, convention: convention)
    }
}
