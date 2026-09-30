import SwiftUI
import StoxCore

/// 走势图上的横线：成本线（青色）和提醒线（褐色，价格提醒、涨跌幅提醒、止盈止损），都是虚线，落在图的范围里才画。
/// 字写在线的上面，垫一块底色，压在均线和成交量柱上也看得清；几条线挨得近时字并排，见 LevelLabelLayout。
enum ChartLevelLines {
    /// 提醒线的颜色：和涨跌的红绿、均线的橙蓝紫、成本线的青色都分得开。
    static let alertColor = Color.brown

    static func color(of level: ChartLevel) -> Color {
        level.isAlert ? alertColor : KlineChart.costColor
    }

    /// 落在图里的线：严格在 bottom 和 top 之间。
    static func visible(_ levels: [ChartLevel], top: Double, bottom: Double) -> [ChartLevel] {
        levels.filter { $0.price > bottom && $0.price < top }
    }

    /// 画出落在 bottom 和 top 之间的线，y 把价格换成纵坐标。分时图的字放在中间（四个角写着最高最低），K 线的靠右。
    static func draw(
        _ levels: [ChartLevel], top: Double, bottom: Double, y: (Double) -> CGFloat, decimals: Int,
        alignment: LevelLabelLayout.Alignment, in context: inout GraphicsContext, size: CGSize
    ) {
        let shown = visible(levels, top: top, bottom: bottom)
        guard !shown.isEmpty else { return }
        for level in shown {
            let lineY = y(level.price)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: lineY))
            line.addLine(to: CGPoint(x: size.width, y: lineY))
            // 成本线的虚线长一些，提醒线的短一些，不看颜色也分得出来。
            let dash: [CGFloat] = level.isAlert ? [2, 2] : [4, 2]
            context.stroke(line, with: .color(color(of: level)), style: StrokeStyle(lineWidth: 1, dash: dash))
        }
        // 字最后画，压在所有的线上面。
        let texts = shown.map { level in
            context.resolve(
                Text(level.label(decimals: decimals))
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundColor(color(of: level))
            )
        }
        let labels = zip(shown, texts).map { level, text -> LevelLabelLayout.Label in
            let textSize = text.measure(in: size)
            return LevelLabelLayout.Label(lineY: Double(y(level.price)), width: Double(textSize.width + 4), height: Double(textSize.height))
        }
        let placements = LevelLabelLayout.place(labels, width: Double(size.width), height: Double(size.height), alignment: alignment)
        for (index, text) in texts.enumerated() {
            let box = CGRect(x: placements[index].x, y: placements[index].y, width: labels[index].width, height: labels[index].height)
            context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(KlineChart.labelBackground))
            context.draw(text, in: box.insetBy(dx: 2, dy: 0))
        }
    }
}
