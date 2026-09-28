import AppKit
import SwiftUI
import StoxCore

enum Theme {
    static let panelWidth: CGFloat = 360

    static func color(for direction: PriceDirection, convention: ColorConvention) -> Color {
        Color(nsColor: nsColor(for: direction, convention: convention))
    }

    static func nsColor(for direction: PriceDirection, convention: ColorConvention) -> NSColor {
        switch direction {
        case .flat: return .secondaryLabelColor
        case .up: return convention == .redUp ? .systemRed : .systemGreen
        case .down: return convention == .redUp ? .systemGreen : .systemRed
        }
    }

    /// 涨跌幅色块的底色，平盘时用灰色。
    static func pillColor(for direction: PriceDirection, convention: ColorConvention) -> Color {
        switch direction {
        case .flat: return Color(nsColor: .systemGray)
        default: return color(for: direction, convention: convention)
        }
    }

    static func phaseColor(_ phase: MarketPhase) -> Color {
        switch phase {
        case .trading: return .green
        case .preMarket, .afterHours: return .orange
        case .lunchBreak: return .yellow
        case .closed: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    static func marketTint(_ market: Market) -> Color {
        switch market {
        case .sh, .sz, .bj: return .red
        case .hk: return .purple
        case .us: return .blue
        }
    }
}
