import AppKit
import SwiftUI
import StoxCore

/// 自选列表的一行：名称 / 代码 / 现价 / 涨跌幅色块。单击展开详情，右键有更多操作。
@MainActor
struct QuoteRow: View {
    static let rowHeight: CGFloat = 46
    static let detailHeight: CGFloat = 96

    let item: WatchItem
    let quote: Quote?
    let expanded: Bool

    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            summary
            if expanded, let quote {
                QuoteDetailView(item: item, quote: quote)
                    .frame(height: Self.detailHeight)
            }
        }
        .background(hovering || expanded ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                router.toggleExpanded(item.symbol)
            }
        }
        .contextMenu { contextMenu }
    }

    private var direction: PriceDirection { quote?.direction ?? .flat }

    private var color: Color { Theme.color(for: direction, convention: settings.colorConvention) }

    private var summary: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(quote?.name ?? item.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if item.pinned {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("显示在菜单栏")
                    }
                    if !item.alert.isEmpty {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.orange)
                            .help("已设置价格提醒")
                    }
                }
                HStack(spacing: 4) {
                    MarketBadge(market: item.symbol.market)
                    Text(item.symbol.displayCode)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let tag = statusTag {
                        Text(tag)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .background(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
                    }
                }
            }
            Spacer(minLength: 6)
            Text(quote.map { QuoteFormatter.price($0.price, decimals: $0.priceDecimals) } ?? "--")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
            Text(quote.map { QuoteFormatter.percent($0.changePercent) } ?? "--")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 70, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.pillColor(for: direction, convention: settings.colorConvention))
                )
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
    }

    /// 停牌、涨停、跌停等状态标签。
    private var statusTag: String? {
        guard let quote else { return nil }
        if quote.isLimitUp { return "涨停" }
        if quote.isLimitDown { return "跌停" }
        let phase = store.phase(for: item.symbol.market.region)
        if !quote.hasTraded, phase == .trading || phase == .lunchBreak { return "停牌" }
        return nil
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(item.pinned ? "不在菜单栏显示" : "显示在菜单栏") {
            store.togglePinned(item.symbol)
        }
        Button("价格提醒与简称…") {
            router.route = .edit(item.symbol)
        }
        Button("在雪球中查看") {
            if let url = QuoteLinks.xueqiu(item.symbol) { NSWorkspace.shared.open(url) }
        }
        Button("复制代码") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.symbol.displayCode, forType: .string)
        }
        Divider()
        Button("移到最前") {
            store.moveToTop(item.symbol)
        }
        Divider()
        Button("删除", role: .destructive) {
            store.remove(item.symbol)
        }
    }
}

/// 展开后的详情：开高低收、成交、市值，以及常用操作。
@MainActor
struct QuoteDetailView: View {
    let item: WatchItem
    let quote: Quote

    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                cell("今开", price(quote.open))
                cell("最高", price(quote.high))
                cell("最低", price(quote.low))
                cell("昨收", price(quote.previousClose))
            }
            HStack(spacing: 0) {
                cell("涨跌", QuoteFormatter.change(quote.change, decimals: quote.priceDecimals))
                cell("成交量", QuoteFormatter.volume(quote.volume, market: item.symbol.market))
                cell("成交额", quote.amount > 0 ? QuoteFormatter.largeNumber(quote.amount) : "--")
                if let marketCap = quote.marketCap {
                    cell("市值", QuoteFormatter.largeNumber(marketCap))
                } else {
                    cell("振幅", quote.amplitude.map { QuoteFormatter.fixed($0, decimals: 2) + "%" } ?? "--")
                }
            }
            HStack(spacing: 10) {
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("提醒") { router.route = .edit(item.symbol) }
                Button("雪球") {
                    if let url = QuoteLinks.xueqiu(item.symbol) { NSWorkspace.shared.open(url) }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func price(_ value: Double) -> String {
        QuoteFormatter.price(value, decimals: quote.priceDecimals)
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11.5).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeText: String {
        let region = item.symbol.market.region
        guard let timestamp = quote.timestamp else { return "" }
        var text = "\(region.displayName)时间 \(QuoteFormatter.time(timestamp, timeZone: region.timeZone))"
        if region == .hk { text += " · 延时约 15 分钟" }
        return text
    }
}
