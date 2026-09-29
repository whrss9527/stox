import AppKit
import SwiftUI
import StoxCore

enum Theme {
    /// 面板玻璃卡片区域的宽度。
    static let panelWidth: CGFloat = 372

    /// 菜单栏行情文字的颜色。不显示红绿时统一用菜单栏默认的文字颜色。
    static func tickerColor(for direction: PriceDirection, convention: ColorConvention) -> NSColor {
        switch (convention, direction) {
        case (.neutral, _): return .labelColor
        case (_, .flat): return .secondaryLabelColor
        case (.redUp, .up), (.greenUp, .down): return .systemRed
        case (.redUp, .down), (.greenUp, .up): return .systemGreen
        }
    }

    /// 面板里价格的颜色。
    static func priceColor(for direction: PriceDirection, convention: ColorConvention) -> Color {
        switch (convention, direction) {
        case (.neutral, _): return .primary
        case (_, .flat): return .secondary
        default: return Color(nsColor: tickerColor(for: direction, convention: convention))
        }
    }

    /// 涨跌幅色块的底色。不显示红绿时是一块淡淡的中性色。
    static func pillBackground(for direction: PriceDirection, convention: ColorConvention) -> Color {
        switch (convention, direction) {
        case (.neutral, _): return Color.primary.opacity(0.1)
        case (_, .flat): return Color(nsColor: .systemGray)
        default: return Color(nsColor: tickerColor(for: direction, convention: convention))
        }
    }

    /// 涨跌幅色块上的文字颜色。
    static func pillForeground(convention: ColorConvention) -> Color {
        convention == .neutral ? .primary : .white
    }

    /// 市场状态圆点。不显示红绿时只用明暗区分交易中和休市。
    static func phaseColor(_ phase: MarketPhase, convention: ColorConvention) -> Color {
        if convention == .neutral {
            return phase.isLive ? .primary : Color(nsColor: .tertiaryLabelColor)
        }
        switch phase {
        case .trading: return .green
        case .preMarket, .afterHours: return .orange
        case .lunchBreak: return .yellow
        case .closed: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// 市场标签（沪、深、港、美）的颜色。
    static func marketTint(_ market: Market, convention: ColorConvention) -> Color {
        if convention == .neutral { return .secondary }
        switch market {
        case .sh, .sz, .bj: return .red
        case .hk: return .purple
        case .us: return .blue
        case .jj: return .orange
        }
    }
}

extension SearchResult {
    /// 搜索接口没有结果时，按用户输入的代码直接构造的候选项。
    static let directTypeCode = "DIRECT"

    var isDirect: Bool { typeCode == Self.directTypeCode }
}
