import AppKit
import SwiftUI
import StoxCore

/// 自选列表的一行：名称 / 代码 / 现价 / 涨跌幅色块。单击展开详情，右键有更多操作。
@MainActor
struct QuoteRow: View {
    static let rowHeight: CGFloat = 46

    /// 展开后详情的高度：分时图、三行行情数据，有持仓时再加一行。
    static func detailHeight(for item: WatchItem) -> CGFloat {
        (item.holding == nil ? 129 : 162) + IntradayChart.height + 6 + (item.note == nil ? 0 : 20)
    }

    let item: WatchItem
    let quote: Quote?
    let expanded: Bool

    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter
    @State private var hovering = false
    /// 价格刚变过：向上还是向下，用来让价格闪一下。
    @State private var flash: PriceDirection?
    @State private var lastPrice: Double?

    var body: some View {
        VStack(spacing: 0) {
            summary
            if expanded, let quote {
                QuoteDetailView(item: item, quote: quote)
                    .frame(height: Self.detailHeight(for: item))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(expanded ? 0.06 : (hovering ? 0.07 : 0)))
        )
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

    private var color: Color { Theme.priceColor(for: direction, convention: settings.colorConvention) }

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
                    if let note = item.note {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .help(note)
                    }
                }
                HStack(spacing: 4) {
                    MarketBadge(market: item.symbol.market)
                    Text(item.symbol.displayCode)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            VStack(alignment: .trailing, spacing: 1) {
                Text(quote.map { QuoteFormatter.price($0.price, decimals: $0.priceDecimals) } ?? "--")
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.priceColor(for: flash ?? .flat, convention: settings.colorConvention).opacity(flash == nil ? 0 : 0.2))
                    )
                    .padding(.horizontal, -3)
                if let position {
                    // 有持仓时在现价下面显示持仓盈亏：公文包图标加比例，不占名称和代码的地方。
                    HStack(spacing: 2) {
                        Image(systemName: "briefcase.fill")
                            .font(.system(size: 8))
                        Text(holdingText(position))
                            .font(.system(size: 10.5).monospacedDigit())
                    }
                    .foregroundStyle(Theme.priceColor(for: PriceDirection(position.totalProfit), convention: settings.colorConvention))
                    .lineLimit(1)
                    .help("持仓盈亏")
                }
            }
            Text(quote.map { QuoteFormatter.percent($0.changePercent) } ?? "--")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.pillForeground(convention: settings.colorConvention))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 70, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.pillBackground(for: direction, convention: settings.colorConvention))
                )
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .onAppear { lastPrice = quote?.price }
        .onChange(of: quote?.price) { price in
            priceChanged(to: price)
        }
    }

    /// 读屏软件念的内容：名称、代码、现价、涨跌，有持仓时加上持仓盈亏。
    private var accessibilityText: String {
        var text = "\(quote?.name ?? item.displayName)，\(item.symbol.displayCode)"
        guard let quote else { return text + "，暂无行情" }
        text += "，现价 \(QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))"
        switch quote.direction {
        case .up: text += "，上涨 \(QuoteFormatter.fixed(abs(quote.changePercent), decimals: 2))%"
        case .down: text += "，下跌 \(QuoteFormatter.fixed(abs(quote.changePercent), decimals: 2))%"
        case .flat: text += "，平盘"
        }
        if let position {
            text += "，持仓盈亏 \(QuoteFormatter.signedMoney(position.totalProfit))"
        }
        return text
    }

    /// 价格变了就闪一下，0.8 秒后淡出。第一次拿到行情时不闪。
    private func priceChanged(to price: Double?) {
        defer { lastPrice = price }
        guard settings.flashOnChange, let price, let lastPrice, price > 0, lastPrice > 0, price != lastPrice else { return }
        let direction: PriceDirection = price > lastPrice ? .up : .down
        withAnimation(.easeIn(duration: 0.1)) { flash = direction }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            withAnimation(.easeOut(duration: 0.6)) {
                if flash == direction { flash = nil }
            }
        }
    }

    private var position: PositionValue? {
        guard let holding = item.holding, let quote else { return nil }
        return Portfolio.position(holding, quote: quote)
    }

    /// 列表里的持仓盈亏：有成本时显示比例，成本为 0 时显示金额。
    private func holdingText(_ position: PositionValue) -> String {
        if let percent = position.totalProfitPercent {
            return QuoteFormatter.percent(percent)
        }
        return QuoteFormatter.signedMoney(position.totalProfit)
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
        Button(item.symbol.isIndex ? "价格提醒与简称…" : "持仓、提醒与简称…") {
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
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IntradayChart(
                series: store.intraday[item.symbol],
                previousClose: quote.previousClose,
                region: item.symbol.market.region,
                color: Theme.priceColor(for: quote.direction, convention: settings.colorConvention)
            )
            .task(id: item.symbol) {
                await store.trackIntraday(item.symbol)
            }
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
                cell("换手率", quote.turnoverRate.map { QuoteFormatter.fixed($0, decimals: 2) + "%" } ?? "--")
            }
            HStack(spacing: 0) {
                if let marketCap = quote.marketCap {
                    cell("市值", QuoteFormatter.largeNumber(marketCap))
                } else {
                    cell("振幅", quote.amplitude.map { QuoteFormatter.fixed($0, decimals: 2) + "%" } ?? "--")
                }
                cell("市盈率", peText)
                cell("52周最高", quote.high52Week.map(price) ?? "--")
                cell("52周最低", quote.low52Week.map(price) ?? "--")
            }
            if let holding = item.holding {
                HStack(spacing: 0) {
                    cell("持有", QuoteFormatter.plain(holding.shares) + "股")
                    cell("成本", QuoteFormatter.fixed(holding.cost, decimals: max(quote.priceDecimals, 2)))
                    if let position = Portfolio.position(holding, quote: quote) {
                        cell("持仓盈亏", QuoteFormatter.signedMoney(position.totalProfit), color: profitColor(position.totalProfit))
                        cell("今日盈亏", QuoteFormatter.signedMoney(position.dayProfit), color: profitColor(position.dayProfit))
                    } else {
                        cell("持仓盈亏", "--")
                        cell("今日盈亏", "--")
                    }
                }
            }
            if let note = item.note {
                Label(note, systemImage: "text.bubble")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note)
            }
            HStack(spacing: 10) {
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(item.symbol.isIndex ? "提醒" : "持仓与提醒") { router.route = .edit(item.symbol) }
                Button("雪球") {
                    if let url = QuoteLinks.xueqiu(item.symbol) { NSWorkspace.shared.open(url) }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func price(_ value: Double) -> String {
        QuoteFormatter.price(value, decimals: quote.priceDecimals)
    }

    /// 亏损公司的市盈率是负数，和券商软件一样显示“亏损”。
    private var peText: String {
        guard let pe = quote.peRatio else { return "--" }
        return pe < 0 ? "亏损" : QuoteFormatter.fixed(pe, decimals: 2)
    }

    private func profitColor(_ value: Double) -> Color {
        Theme.priceColor(for: PriceDirection(value), convention: settings.colorConvention)
    }

    private func cell(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(color)
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
