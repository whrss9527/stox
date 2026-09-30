import SwiftUI
import StoxCore

/// 展开详情里的走势图：上面一排“分时 五日 日K 周K 月K”（A 股还有“五档”），中间是图，下面是时间或日期。
/// 鼠标移到图上时，上面那一排换成指着的那一点的价格（分时）或开高低收（K 线）。
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

    /// 实际显示的一项：选了五档而这只没有五档时看分时。
    private var period: ChartPeriod { settings.chartPeriod.effective(for: quote) }

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
                Group {
                    switch period {
                    case .orderBook:
                        OrderBookFooter(book: quote.orderBook, market: item.symbol.market)
                    case .fundFlow:
                        FundFlowFooter(flow: store.fundFlows[item.symbol])
                    default:
                        ChartAxis(ticks: axisTicks)
                    }
                }
                .frame(height: Self.axisHeight, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.chartName(period))
        .accessibilityValue(summary ?? "")
        .task(id: TrackID(symbol: item.symbol, period: period)) {
            switch period {
            case .intraday:
                await store.trackIntraday(item.symbol)
            case .fiveDay:
                await store.trackFiveDay(item.symbol)
            case .day, .week, .month:
                if let kline = period.klinePeriod {
                    await store.trackKline(item.symbol, period: kline)
                }
            case .orderBook:
                break  // 五档跟着行情一起刷新
            case .fundFlow:
                await store.trackFundFlow(item.symbol)
            }
        }
    }

    // MARK: - 图

    private var region: MarketRegion { item.symbol.market.region }

    private var intradaySeries: IntradaySeries? { store.intraday[item.symbol] }

    /// K 线图上画的：接口的数据，最后一根用实时行情更新过，只留最后 60 根，带着均线。
    private var klineData: KlineChartData? {
        guard let kline = period.klinePeriod,
              let series = store.klines[KlineKey(symbol: item.symbol, period: kline)]
        else { return nil }
        return KlineChartData(series: series.merging(quote))
    }

    private var fiveDaySeries: MultiDaySeries? { store.fiveDay[item.symbol] }

    /// 图上画的成本线：有持仓、成本价大于 0、设置里没关掉时才有。
    private var cost: Double? {
        guard settings.showCostAndTrades, let cost = item.holding?.cost, cost > 0 else { return nil }
        return cost
    }

    /// K 线上的买卖点。
    private func tradeMarks(in data: KlineChartData?) -> [KlineTradeMark] {
        guard settings.showCostAndTrades, let data else { return [] }
        return data.tradeMarks(item.trades, region: region)
    }

    @ViewBuilder
    private var chart: some View {
        switch period {
        case .intraday:
            IntradayChart(
                series: intradaySeries,
                previousClose: quote.previousClose,
                region: region,
                color: Theme.priceColor(for: quote.direction, convention: settings.colorConvention),
                hovered: hoveredPoint,
                showAverage: settings.showMovingAverages,
                decimals: quote.priceDecimals,
                cost: cost,
                convention: settings.colorConvention
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
                decimals: quote.priceDecimals,
                cost: cost,
                marks: tradeMarks(in: data)
            )
        case .orderBook:
            OrderBookView(
                book: quote.orderBook ?? OrderBook(bids: [], asks: []),
                previousClose: quote.previousClose,
                decimals: quote.priceDecimals,
                market: item.symbol.market,
                convention: settings.colorConvention
            )
        case .fundFlow:
            FundFlowView(
                flow: store.fundFlows[item.symbol],
                loaded: store.fundFlowLoaded.contains(item.symbol),
                convention: settings.colorConvention,
                hovered: hoveredFlow
            )
        }
    }

    /// 图下面的横轴：分时是开盘、午休、收盘的时刻，五日是每天的日期，K 线是头、中、尾三根的日期。
    private var axisTicks: [AxisTick] {
        switch period {
        case .intraday:
            // 期货从开盘那一刻标起，要等分时取回来才知道。
            return IntradayAxis.ticks(for: region, start: intradaySeries?.start)
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
        case .orderBook, .fundFlow:
            return []  // 五档下面写内外盘，资金下面写主力流入流出，见 OrderBookFooter、FundFlowFooter
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

    /// 资金页上鼠标指着的那一分钟。右边一栏不算在图里。
    private var hoveredFlow: FundFlowPoint? {
        let width = chartWidth - FundFlowView.breakdownWidth - FundFlowView.spacing
        guard let hoverX, width > 0, hoverX <= width, let flow = store.fundFlows[item.symbol], flow.trend.count > 1 else { return nil }
        return flow.point(nearest: Double(hoverX / width) * Double(IntradayAxis.length(for: .cn)))
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
                ForEach(ChartPeriod.available(for: quote)) { period in
                    tab(period)
                }
                Spacer(minLength: 4)
                if let summary {
                    Text(summary)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    private func tab(_ period: ChartPeriod) -> some View {
        let selected = self.period == period
        return Button {
            settings.chartPeriod = period
        } label: {
            // A 股个股有七项，留白小一点，右边的均价、委比、主力净流入才放得下。
            Text(period.title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 4)
                .frame(height: Self.headerHeight)
                .background(Capsule().fill(Color.primary.opacity(selected ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tabHelp(period))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tabHelp(_ period: ChartPeriod) -> String {
        switch period {
        case .orderBook: return L("买卖五档和内外盘（展开时也可以用 ← → 切换）")
        case .fundFlow: return L("资金流向：主力（超大单、大单）当天净流入多少，逐分钟累计（展开时也可以用 ← → 切换）")
        default: return Self.chartName(period) + L("（展开时也可以用 ← → 切换）")
        }
    }

    /// 图的名字，读屏和鼠标停在切换按钮上时用。英文里按钮上的字很短（Day、Week），这里写全。
    static func chartName(_ period: ChartPeriod) -> String {
        switch period {
        case .intraday: return L("分时走势")
        case .fiveDay: return L("五日走势")
        case .day: return L("日K走势")
        case .week: return L("周K走势")
        case .month: return L("月K走势")
        case .orderBook: return L("买卖五档")
        case .fundFlow: return L("资金流向")
        }
    }

    /// 读数里的成交量：`1.20万手`、`35.60万股`。
    private static func volumeText(_ volume: Double, lots: Bool) -> String {
        let number = QuoteFormatter.largeNumber(volume)
        return lots ? L("%@手", number) : L("%@股", number)
    }

    /// 没有指着图时，右边显示这一段的涨跌，例如“近 60 日 -8.12%”；分时图上是最新的成交均价，五档是委比，资金是主力净流入。
    private var summary: String? {
        if period == .fundFlow {
            // 上面一排放了七项，写短一点：主力净流入。
            guard let flow = store.fundFlows[item.symbol] else { return nil }
            return L("主力 ") + QuoteFormatter.signedLargeNumber(flow.mainNetInflow)
        }
        if period == .orderBook {
            guard let imbalance = quote.orderBook?.imbalance else { return nil }
            return L("委比 ") + QuoteFormatter.percent(imbalance)
        }
        if period == .intraday {
            guard settings.showMovingAverages, let average = intradaySeries?.latestAverage else { return nil }
            return L("均价 %@", QuoteFormatter.price(average, decimals: quote.priceDecimals))
        }
        if period == .fiveDay {
            guard let series = fiveDaySeries, let last = fiveDayLast, let base = series.previousClose, base > 0 else { return nil }
            return L("近 %@ 日 %@", series.days.count, QuoteFormatter.percent((last - base) / base * 100))
        }
        guard let data = klineData, let change = data.totalChangePercent else { return nil }
        let percent = QuoteFormatter.percent(change)
        switch data.period {
        case .day: return L("近 %@ 日 %@", data.candles.count, percent)
        case .week: return L("近 %@ 周 %@", data.candles.count, percent)
        case .month: return L("近 %@ 个月 %@", data.candles.count, percent)
        }
    }

    /// 指着图时显示的读数。
    private var readout: String? {
        let decimals = quote.priceDecimals
        func price(_ value: Double) -> String { QuoteFormatter.price(value, decimals: decimals) }
        if period == .orderBook { return nil }
        if period == .fundFlow {
            guard let point = hoveredFlow else { return nil }
            var text = String(format: "%02d:%02d  ", point.minute / 60, point.minute % 60)
                + L("主力净流入 ") + QuoteFormatter.signedLargeNumber(point.mainNetInflow)
            if let value = point.price {
                text += "  " + price(value)
            }
            return text
        }
        if period == .fiveDay {
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
                text += L("  均价 ") + price(average)
            }
            return text
        }
        if period.klinePeriod == nil {
            guard let point = hoveredPoint else { return nil }
            var text = IntradayAxis.timeLabel(of: point.minute, start: intradaySeries?.start, region: region) + "  " + price(point.price)
            if quote.previousClose > 0 {
                text += "  " + QuoteFormatter.percent((point.price - quote.previousClose) / quote.previousClose * 100)
            }
            if settings.showMovingAverages, let average = point.average {
                text += L("  均价 ") + price(average)
            }
            // 分时接口里 A 股的量是手，科创板和港股、美股是股。
            if let volume = point.volume, volume > 0 {
                text += L("  量 ") + Self.volumeText(volume, lots: region == .cn && !item.symbol.isStarMarket)
            }
            return text
        }
        guard let data = klineData, let index = hoveredCandle(in: data) else { return nil }
        let candle = data.candles[index]
        let date = data.period == .month ? String(candle.date.prefix(7)) : candle.date
        var text = L("%@ 开%@ 高%@ 低%@ 收%@", date, price(candle.open), price(candle.high), price(candle.low), price(candle.close))
        if let change = data.changes[index] {
            text += " " + QuoteFormatter.percent(change)
        }
        // K 线接口里 A 股的成交量是手，科创板和港股、美股是股。
        if let volume = candle.volume, volume > 0 {
            text += L(" 量") + Self.volumeText(volume, lots: region == .cn && !item.symbol.isStarMarket)
        }
        if let mark = tradeMarks(in: data).first(where: { $0.index == index }) {
            text += mark.bought && mark.sold ? L(" 有买卖") : (mark.bought ? L(" 有买入") : L(" 有卖出"))
        }
        return text
    }
}

/// K 线图：每根一个实体加上下影线，红涨绿跌跟着设置走。不显示红绿时阳线空心、阴线实心。
/// 最下面四分之一淡淡地画着成交量柱。有持仓时成本价落在图里就画一条虚线，记过买卖的那几根下面标 B、上面标 S。
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
    /// 持仓成本价，不画时为 nil。
    var cost: Double?
    /// 记过买卖的那几根。
    var marks: [KlineTradeMark] = []

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
                Text(data == nil ? L("正在加载 K 线…") : L("暂时没有 K 线数据"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: IntradayChart.height)
        .accessibilityLabel(L("K 线走势"))
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

        // 成交量柱画在最下面四分之一，淡一些，K 线压在上面。
        if let maxVolume = data.maxVolume {
            let band = size.height * 0.25
            for (index, candle) in candles.enumerated() {
                guard let volume = candle.volume, volume > 0 else { continue }
                let height = max(CGFloat(volume / maxVolume) * band, 0.5)
                let x = (CGFloat(layout.centerX(of: index)) * 2).rounded() / 2
                let bar = CGRect(x: x - bodyWidth / 2, y: size.height - height, width: bodyWidth, height: height)
                context.fill(Path(bar), with: .color(color(for: candle.direction).opacity(0.28)))
            }
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

        // 均线画在 K 线上面；前面根数不够算的地方空着。
        if showAverages {
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

        // 成本线：落在图的范围里才画，右边写着成本价，垫一块底色，压在均线和成交量柱上也看得清。
        if let cost, cost > bottom, cost < top {
            let costY = y(cost)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: costY))
            line.addLine(to: CGPoint(x: size.width, y: costY))
            context.stroke(line, with: .color(Self.costColor), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
            let label = context.resolve(
                Text(L("成本 ") + QuoteFormatter.price(cost, decimals: decimals))
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundColor(Self.costColor)
            )
            let textSize = label.measure(in: size)
            // 放在线的上面，贴着顶边时放到下面。
            let labelY = costY - textSize.height - 2 >= 0 ? costY - textSize.height - 2 : costY + 2
            let box = CGRect(x: size.width - textSize.width - 5, y: labelY, width: textSize.width + 4, height: textSize.height)
            context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(Self.labelBackground))
            context.draw(label, in: box.insetBy(dx: 2, dy: 0))
        }

        // 买卖点：买入在那一根的最低价下面标 B，卖出在最高价上面标 S，不出图的边。
        for mark in marks where candles.indices.contains(mark.index) {
            let x = CGFloat(layout.centerX(of: mark.index))
            let candle = candles[mark.index]
            if mark.bought {
                Self.badge("B", color: color(for: .up), center: CGPoint(x: x, y: min(y(candle.low) + 6, size.height - 5)), in: &context)
            }
            if mark.sold {
                Self.badge("S", color: color(for: .down), center: CGPoint(x: x, y: max(y(candle.high) - 6, 5)), in: &context)
            }
        }
    }

    private func color(for direction: PriceDirection) -> Color {
        if convention == .neutral {
            return Color.primary.opacity(0.75)
        }
        return Theme.priceColor(for: direction, convention: convention)
    }

    /// 成本线的颜色，分时图上也用它。
    static let costColor = Color.teal
    /// 图上文字下面垫的底色。
    static let labelBackground = Color(nsColor: .windowBackgroundColor).opacity(0.85)

    /// 一个小圆点里写一个字母。
    static func badge(_ letter: String, color: Color, center: CGPoint, in context: inout GraphicsContext) {
        let rect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
        context.fill(Path(ellipseIn: rect), with: .color(color))
        let text = Text(letter).font(.system(size: 6.5, weight: .bold)).foregroundColor(.white)
        context.draw(context.resolve(text), at: center, anchor: .center)
    }
}
