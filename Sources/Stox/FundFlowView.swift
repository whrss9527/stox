import SwiftUI
import StoxCore

/// 展开详情里的“资金”：左边是当天每分钟累计的主力净流入（在 0 上面是净流入，用涨的颜色；下面是净流出，用跌的颜色），
/// 横轴和分时图一样只有交易时段；右边是超大单、大单、中单、小单各自的净流入。只有 A 股个股和 ETF 有。
struct FundFlowView: View {
    /// 右边一栏的宽度，以及和左边的图隔开多少。鼠标位置换算到图上时要减掉。
    static let breakdownWidth: CGFloat = 104
    static let spacing: CGFloat = 10

    let flow: FundFlow?
    /// 取过一次了但是没有数据（开盘前、这只没有资金流向）。
    var loaded = false
    let convention: ColorConvention
    var hovered: FundFlowPoint?

    var body: some View {
        if let flow {
            HStack(spacing: Self.spacing) {
                FundFlowChart(flow: flow, convention: convention, hovered: hovered)
                breakdown(flow)
                    .frame(width: Self.breakdownWidth)
            }
            .help(flow.note ?? "")
        } else {
            Text(loaded ? L("暂无资金流向（开盘后才有）") : L("正在加载资金流向…"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func breakdown(_ flow: FundFlow) -> some View {
        VStack(spacing: 0) {
            row(L("超大单"), flow.superNet)
            row(L("大单"), flow.bigNet)
            row(L("中单"), flow.mediumNet)
            row(L("小单"), flow.smallNet)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(QuoteFormatter.signedLargeNumber(value))
                .foregroundStyle(Theme.priceColor(for: PriceDirection(value), convention: convention))
        }
        .font(.system(size: 9).monospacedDigit())
        .lineLimit(1)
        .frame(maxHeight: .infinity)
    }
}

/// 主力净流入的分时：0 是虚线，线和 0 之间淡淡地填上颜色；左上角、左下角标着图上最大、最小的值。
struct FundFlowChart: View {
    let flow: FundFlow
    let convention: ColorConvention
    var hovered: FundFlowPoint?

    var body: some View {
        GeometryReader { proxy in
            if let range = flow.trendRange, flow.trend.count > 1 {
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(in: &context, size: size, range: range)
                    }
                    if range.upperBound > 0 {
                        label(QuoteFormatter.signedLargeNumber(range.upperBound))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if range.lowerBound < 0 {
                        label(QuoteFormatter.signedLargeNumber(range.lowerBound))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    if let hovered {
                        let point = location(of: hovered, size: size, range: range)
                        Path { path in
                            path.move(to: CGPoint(x: point.x, y: 0))
                            path.addLine(to: CGPoint(x: point.x, y: size.height))
                        }
                        .stroke(Color.secondary.opacity(0.7), lineWidth: 0.6)
                        Circle()
                            .fill(color(hovered.mainNetInflow))
                            .frame(width: 5, height: 5)
                            .position(point)
                    }
                }
            } else {
                Text(L("还没有资金流向的分时"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityLabel(L("主力净流入走势"))
        .accessibilityValue(L("主力净流入 ") + QuoteFormatter.signedLargeNumber(flow.mainNetInflow))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8).monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 1)
            .fixedSize()
    }

    private func color(_ value: Double) -> Color {
        Theme.priceColor(for: PriceDirection(value), convention: convention)
    }

    private func location(of point: FundFlowPoint, size: CGSize, range: ClosedRange<Double>) -> CGPoint {
        let length = Double(IntradayAxis.length(for: .cn))
        let x = CGFloat(Double(IntradayAxis.offset(of: point.minute, region: .cn)) / length) * size.width
        let y = size.height * CGFloat((range.upperBound - point.mainNetInflow) / (range.upperBound - range.lowerBound))
        return CGPoint(x: x, y: y)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, range: ClosedRange<Double>) {
        let points = flow.trend.map { location(of: $0, size: size, range: range) }
        guard let first = points.first, let last = points.last else { return }
        let zeroY = size.height * CGFloat(range.upperBound / (range.upperBound - range.lowerBound))

        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: zeroY))
        zero.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(zero, with: .color(Color.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))

        var line = Path()
        line.move(to: first)
        points.dropFirst().forEach { line.addLine(to: $0) }
        var area = line
        area.addLine(to: CGPoint(x: last.x, y: zeroY))
        area.addLine(to: CGPoint(x: first.x, y: zeroY))
        area.closeSubpath()

        // 0 上面是净流入的颜色，下面是净流出的颜色：同一条线画两遍，各自只留 0 的一边。
        let sides: [(CGRect, PriceDirection)] = [
            (CGRect(x: 0, y: 0, width: size.width, height: zeroY), .up),
            (CGRect(x: 0, y: zeroY, width: size.width, height: max(size.height - zeroY, 0)), .down),
        ]
        for (rect, direction) in sides where rect.height > 0 {
            let color = Theme.priceColor(for: direction, convention: convention)
            context.drawLayer { layer in
                layer.clip(to: Path(rect))
                layer.fill(area, with: .color(color.opacity(0.16)))
                layer.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// 资金页下面一行：主力流入、流出，右边是前几个交易日加起来的主力净流入和排名。
struct FundFlowFooter: View {
    let flow: FundFlow?

    var body: some View {
        HStack(spacing: 8) {
            if let flow {
                Text(L("主力流入 ") + QuoteFormatter.largeNumber(flow.mainInflow))
                Text(L("流出 ") + QuoteFormatter.largeNumber(flow.mainOutflow))
                Spacer(minLength: 0)
                if let total = flow.daysTotal {
                    Text(L("前 %@ 日 ", flow.days.count) + QuoteFormatter.signedLargeNumber(total))
                }
            }
        }
        .font(.system(size: 8.5).monospacedDigit())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
