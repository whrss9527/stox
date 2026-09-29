import AppKit
import SwiftUI
import StoxCore

/// 自选列表的一行：名称 / 代码 / 现价 / 涨跌幅色块。单击展开详情，右键有更多操作。
@MainActor
struct QuoteRow: View {
    static let standardRowHeight: CGFloat = 46
    /// 紧凑列表的一行：名称、代码、现价、色块排成一行。
    static let compactRowHeight: CGFloat = 30

    static func rowHeight(compact: Bool) -> CGFloat {
        compact ? compactRowHeight : standardRowHeight
    }

    /// 展开后详情的高度：走势图、三行行情数据，有持仓时再加一行。场外基金没有走势图，只有一行净值。
    static func detailHeight(for item: WatchItem) -> CGFloat {
        let note: CGFloat = item.note == nil ? 0 : 20
        if item.symbol.isFund {
            return (item.holding == nil ? 63 : 96) + note
        }
        return (item.holding == nil ? 129 : 162) + QuoteChartSection.height + 6 + note
    }

    let item: WatchItem
    let quote: Quote?
    let expanded: Bool
    /// 键盘上下方向键选中了这一行。
    var highlighted = false

    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter
    @State private var hovering = false
    /// 价格刚变过：向上还是向下，用来让价格闪一下。
    @State private var flash: PriceDirection?
    @State private var lastPrice: Double?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if settings.compactRows {
                    compactSummary
                } else {
                    summary
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight(compact: settings.compactRows))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .onAppear { lastPrice = quote?.price }
            .onChange(of: quote?.price) { price in
                priceChanged(to: price)
            }
            if expanded, let quote {
                QuoteDetailView(item: item, quote: quote)
                    .frame(height: Self.detailHeight(for: item))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(expanded ? 0.06 : (hovering ? 0.07 : 0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(highlighted ? 0.8 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // 用鼠标点了以后，方向键从展开的这一行接着走。
            router.highlighted = nil
            withAnimation(.easeInOut(duration: 0.15)) {
                router.toggleExpanded(item.symbol)
            }
        }
        .contextMenu { contextMenu }
    }

    private var direction: PriceDirection { quote?.direction ?? .flat }

    /// 美股个股不在常规交易时显示的盘前盘后价。
    private var extended: ExtendedQuote? {
        guard settings.showExtendedHours else { return nil }
        return quote.flatMap { ExtendedQuote(store.extendedHours[item.symbol], quote: $0) }
    }

    /// 色块里的文字：涨跌幅、涨跌额或者总市值（指数没有市值）。
    private var pillText: String {
        guard let quote else { return "--" }
        switch settings.changeDisplay {
        case .percent: return QuoteFormatter.percent(quote.changePercent)
        case .change: return QuoteFormatter.change(quote.change, decimals: quote.priceDecimals)
        case .marketCap: return quote.marketCap.map { QuoteFormatter.largeNumber($0) } ?? "--"
        }
    }

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
                    if let extended {
                        // 美股盘前盘后：标签加涨跌幅，价格放在提示和详情里。
                        Text("\(extended.label) \(QuoteFormatter.percent(extended.percent))")
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Theme.priceColor(for: PriceDirection(extended.change), convention: settings.colorConvention))
                            .lineLimit(1)
                            .help(extended.helpText)
                    }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                priceLabel(size: 14)
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
            pill(width: 70, height: 24, fontSize: 12)
        }
    }

    /// 紧凑列表的一行：市场、名称、代码、状态标签、现价和色块。持仓盈亏、盘前盘后价在展开后看。
    private var compactSummary: some View {
        HStack(spacing: 6) {
            MarketBadge(market: item.symbol.market)
            Text(quote?.name ?? item.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Text(item.symbol.displayCode)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let tag = statusTag {
                Text(tag)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
            }
            if !item.alert.isEmpty {
                Image(systemName: "bell.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .help("已设置价格提醒")
            }
            Spacer(minLength: 6)
            priceLabel(size: 13)
            pill(width: 64, height: 20, fontSize: 11.5)
        }
    }

    /// 现价，价格变动时背后闪一下。
    private func priceLabel(size: CGFloat) -> some View {
        Text(quote.map { QuoteFormatter.price($0.price, decimals: $0.priceDecimals) } ?? "--")
            .font(.system(size: size, weight: .medium).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.priceColor(for: flash ?? .flat, convention: settings.colorConvention).opacity(flash == nil ? 0 : 0.2))
            )
            .padding(.horizontal, -3)
    }

    /// 右边的色块，点一下在涨跌幅、涨跌额、总市值之间切换。
    private func pill(width: CGFloat, height: CGFloat, fontSize: CGFloat) -> some View {
        Button {
            settings.changeDisplay = settings.changeDisplay.next
        } label: {
            Text(pillText)
                .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.pillForeground(convention: settings.colorConvention))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.pillBackground(for: direction, convention: settings.colorConvention))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(settings.changeDisplay.title)。点一下切换涨跌幅、涨跌额、总市值")
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
            text += "，持仓盈亏 \(holdingText(position))"
        }
        if let extended {
            text += "，\(extended.label) \(extended.priceText)，\(QuoteFormatter.percent(extended.percent))"
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
        return Portfolio.position(holding, quote: quote, trades: item.trades)
    }

    /// 列表里的持仓盈亏：有成本时显示比例，成本为 0 时显示金额（隐藏金额时是 ****）。
    private func holdingText(_ position: PositionValue) -> String {
        if let percent = position.totalProfitPercent {
            return QuoteFormatter.percent(percent)
        }
        return settings.hideAmounts ? QuoteFormatter.hiddenAmount : QuoteFormatter.signedMoney(position.totalProfit)
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
        Menu("分组") {
            let groups = Watchlist.groups(in: store.items)
            ForEach(groups, id: \.self) { name in
                Button {
                    store.setGroup(name, for: item.symbol)
                } label: {
                    if item.group == name {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if !groups.isEmpty {
                Divider()
            }
            Button("新建分组…") {
                router.route = .group(nil, member: item.symbol)
            }
            if item.group != nil {
                Button("移出分组") {
                    store.setGroup(nil, for: item.symbol)
                }
            }
        }
        if let web = QuoteLinks.web(item.symbol) {
            Button("在\(web.title)中查看") {
                NSWorkspace.shared.open(web.url)
            }
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
            if item.symbol.isFund {
                // 场外基金只有每天的净值：单位净值、累计净值和这一天的涨跌。
                HStack(spacing: 0) {
                    cell("单位净值", price(quote.price))
                    cell("累计净值", quote.cumulativeNAV.map(price) ?? "--")
                    cell("日涨跌", QuoteFormatter.change(quote.change, decimals: quote.priceDecimals))
                    cell("日涨幅", QuoteFormatter.percent(quote.changePercent), color: profitColor(quote.change))
                }
            } else {
                QuoteChartSection(item: item, quote: quote)
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
            }
            if let holding = item.holding {
                HStack(spacing: 0) {
                    cell("持有", amount(QuoteFormatter.plain(holding.shares) + (item.symbol.isFund ? "份" : "股")))
                    cell("成本", QuoteFormatter.fixed(holding.cost, decimals: max(quote.priceDecimals, 2)))
                    if let position = Portfolio.position(holding, quote: quote, trades: item.trades) {
                        cell("持仓盈亏", amount(QuoteFormatter.signedMoney(position.totalProfit)), color: profitColor(position.totalProfit))
                        cell("今日盈亏", amount(QuoteFormatter.signedMoney(position.dayProfit)), color: profitColor(position.dayProfit))
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
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer()
                Button(item.symbol.isIndex ? "提醒" : "持仓与提醒") { router.route = .edit(item.symbol) }
                if let web = QuoteLinks.web(item.symbol) {
                    Button(web.title) { NSWorkspace.shared.open(web.url) }
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

    /// 持有数量和盈亏金额：隐藏金额时是 ****。
    private func amount(_ text: @autoclosure () -> String) -> String {
        settings.hideAmounts ? QuoteFormatter.hiddenAmount : text()
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
        // 场外基金写净值是哪天的，每个交易日晚上才出当天的。
        if item.symbol.isFund {
            guard let timestamp = quote.timestamp else { return "净值每个交易日晚上更新" }
            return "净值日期 " + ProfitHistory.day(of: timestamp, region: .cn) + " · 每个交易日晚上更新"
        }
        // 美股不在常规交易时，这一行换成盘前盘后价和它的成交时间；行情时间这时总是收盘那一刻，不用再写。
        if settings.showExtendedHours, let extended = ExtendedQuote(store.extendedHours[item.symbol], quote: quote) {
            var text = "\(extended.label) \(extended.priceText) \(QuoteFormatter.percent(extended.percent))"
            if let time = extended.timeText { text += " · 美东 \(time)" }
            return text
        }
        guard let timestamp = quote.timestamp else { return "" }
        var text = "\(region.displayName)时间 \(QuoteFormatter.time(timestamp, timeZone: region.timeZone))"
        if region == .hk { text += " · 延时约 15 分钟" }
        return text
    }
}

/// 列表和详情里显示的美股盘前盘后价：标签、价格和相对收盘的涨跌。没有数据、和行情对不上时为 nil。
struct ExtendedQuote {
    let label: String
    let price: Double
    let change: Double
    let percent: Double
    let decimals: Int
    let time: Date?

    init?(_ extended: ExtendedHoursQuote?, quote: Quote) {
        guard let extended, let change = extended.change(from: quote) else { return nil }
        label = extended.session.displayName
        price = extended.price
        self.change = change.change
        percent = change.percent
        decimals = quote.priceDecimals
        time = extended.time
    }

    var priceText: String { QuoteFormatter.price(price, decimals: decimals) }

    /// 成交时间，美东时间的时和分。
    var timeText: String? {
        time.map { String(QuoteFormatter.time($0, timeZone: MarketRegion.us.timeZone).prefix(5)) }
    }

    /// 鼠标停在标签上时的说明：价格、相对收盘的涨跌和成交时间。
    var helpText: String {
        var text = "\(label) \(priceText)，相对收盘 \(QuoteFormatter.percent(percent))"
        if let timeText { text += "，美东时间 \(timeText)" }
        return text
    }
}
