import AppKit
import StoxCore

/// 菜单栏上下两行的排法画成的一张图：每段左边一行名称（或者“今日”“持仓”），右边上下两行数，
/// 价格（金额）在上、涨跌幅（比例）在下，右对齐；右边只有一个数时它单独一行、上下居中。
/// 用绘制闭包画：菜单栏换深浅色时 AppKit 重新画，文字颜色跟着变。
enum StackedTickerImage {
    /// 左边名称的字号，比一行排法（12.5）略小。
    static let labelFont = NSFont.systemFont(ofSize: 12)
    /// 右边上下两行的字号：两行加起来不超过菜单栏的高度。
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    /// 右边只有一个数时的字号。
    static let singleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    /// 名称和右边的数之间、两段之间的空隙。
    static let labelGap: CGFloat = 3
    static let blockGap: CGFloat = 8
    /// 上下两行的行距：上一行的顶到下一行的顶。比行高小一点，上一行下伸部分的空白和下一行重叠，数字本身不会碰到。
    static let lineStep: CGFloat = 10

    static func size(_ text: String, _ font: NSFont) -> CGSize {
        NSAttributedString(string: text, attributes: [.font: font]).size()
    }

    static func make(_ blocks: [StackedTickerBlock], convention: ColorConvention, height: CGFloat) -> NSImage {
        // 先量好每段的宽度，图的大小要在画之前定下来。
        let widths: [CGFloat] = blocks.map { block in
            let label = block.label.map { size($0.text, labelFont).width + labelGap } ?? 0
            let values = [block.top, block.bottom].compactMap { $0 }
            let column: CGFloat
            if values.count == 2 {
                column = values.map { size($0.text, valueFont).width }.max() ?? 0
            } else {
                column = values.first.map { size($0.text, singleFont).width } ?? 0
            }
            // 只有名称、没有数时不要多出来的空隙。
            return column > 0 ? label + column : max(label - labelGap, 0)
        }
        let width = ceil(widths.reduce(0, +) + blockGap * CGFloat(max(blocks.count - 1, 0)))
        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: true) { _ in
            // 按基线画（不带 usesLineFragmentOrigin 时矩形的原点就是基线）：“万”和名称里的汉字用的是回退字体，
            // 行高和数字不一样，按左上角放会上下错开一点，按基线放都对齐。
            func draw(_ part: TickerPart, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat) {
                let text = NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: color])
                text.draw(with: NSRect(x: x, y: baseline, width: text.size().width + 4, height: 0), options: [], context: nil)
            }
            // 一行字上下居中时的基线：按这个字号的上伸、下伸算。
            func centeredBaseline(_ font: NSFont) -> CGFloat {
                (height - (font.ascender - font.descender)) / 2 + font.ascender
            }
            var x: CGFloat = 0
            for (index, block) in blocks.enumerated() {
                let end = x + widths[index]
                if let label = block.label {
                    draw(label, font: labelFont, color: .labelColor, x: x, baseline: centeredBaseline(labelFont))
                }
                let values = [block.top, block.bottom].compactMap { $0 }
                if values.count == 2, let top = block.top, let bottom = block.bottom {
                    let topBaseline = (height - lineStep - (valueFont.ascender - valueFont.descender)) / 2 + valueFont.ascender
                    for (part, baseline) in [(top, topBaseline), (bottom, topBaseline + lineStep)] {
                        let color = Theme.tickerColor(for: part.direction, convention: convention)
                        draw(part, font: valueFont, color: color, x: end - size(part.text, valueFont).width, baseline: baseline)
                    }
                } else if let part = values.first {
                    let color = Theme.tickerColor(for: part.direction, convention: convention)
                    draw(part, font: singleFont, color: color, x: end - size(part.text, singleFont).width, baseline: centeredBaseline(singleFont))
                }
                x = end + blockGap
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = blocks.map(\.text).joined(separator: "，")
        return image
    }
}
