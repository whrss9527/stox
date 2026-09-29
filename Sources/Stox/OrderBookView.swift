import SwiftUI
import StoxCore

/// 展开详情里的“五档”：左边买一到买五，右边卖一到卖五，每档是挂单价和挂单量（手）。价格按和昨收比的涨跌着色，
/// 每档衬一条淡淡的量条，从中间往两边长，最多的一档画满半边。
struct OrderBookView: View {
    let book: OrderBook
    let previousClose: Double
    let decimals: Int
    let market: Market
    let convention: ColorConvention

    private static let numerals = ["一", "二", "三", "四", "五"]

    var body: some View {
        if book.isEmpty {
            Text("暂无挂单（开盘前或停牌）")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 8) {
                side("买", book.bids, barColor: Theme.priceColor(for: .up, convention: convention), barEdge: .trailing)
                side("卖", book.asks, barColor: Theme.priceColor(for: .down, convention: convention), barEdge: .leading)
            }
        }
    }

    private func side(_ name: String, _ levels: [OrderBook.Level], barColor: Color, barEdge: Alignment) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<OrderBook.depth, id: \.self) { index in
                row(name + Self.numerals[index], index < levels.count ? levels[index] : nil, barColor: barColor, barEdge: barEdge)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ label: String, _ level: OrderBook.Level?, barColor: Color, barEdge: Alignment) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(level.map { QuoteFormatter.price($0.price, decimals: decimals) } ?? "--")
                .foregroundStyle(level.map { priceColor($0.price) } ?? Color.secondary)
            Text(level.map { lots($0.volume) } ?? "")
                .foregroundStyle(.primary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .font(.system(size: 9).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 3)
        .background {
            GeometryReader { proxy in
                Rectangle()
                    .fill(barColor.opacity(0.14))
                    .frame(width: proxy.size.width * fraction(level))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: barEdge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(level.map { "\(QuoteFormatter.price($0.price, decimals: decimals))，\(lots($0.volume))手" } ?? "没有挂单")
    }

    /// 这一档的量占最多那一档的几成。
    private func fraction(_ level: OrderBook.Level?) -> CGFloat {
        guard let level, book.maxVolume > 0 else { return 0 }
        return CGFloat(min(level.volume / book.maxVolume, 1))
    }

    private func priceColor(_ price: Double) -> Color {
        guard previousClose > 0 else { return .primary }
        return Theme.priceColor(for: PriceDirection(price - previousClose), convention: convention)
    }

    /// 挂单量按手写，不带单位（A 股的习惯）。
    private func lots(_ shares: Double) -> String {
        QuoteFormatter.largeNumber(shares / 100)
    }
}

/// 五档下面一行：外盘、内盘（主动买入、主动卖出的成交量），右边是委差（委买减委卖，手）。
struct OrderBookFooter: View {
    let book: OrderBook?
    let market: Market

    var body: some View {
        HStack(spacing: 8) {
            if let outer = book?.outerVolume, let inner = book?.innerVolume, outer + inner > 0 {
                Text("外盘 " + QuoteFormatter.volume(outer, market: market))
                Text("内盘 " + QuoteFormatter.volume(inner, market: market))
            }
            Spacer(minLength: 0)
            if let book, !book.isEmpty {
                Text("委差 " + difference(book))
            }
        }
        .font(.system(size: 8.5).monospacedDigit())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func difference(_ book: OrderBook) -> String {
        let lots = (book.bidVolume - book.askVolume) / 100
        return (lots >= 0.5 ? "+" : "") + QuoteFormatter.largeNumber(lots)
    }
}
