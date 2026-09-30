import AppKit
import SwiftUI
import StoxCore

/// 单只证券的设置：菜单栏显示、简称、持仓、价格提醒。在面板里打开，Esc 返回列表。
@MainActor
struct StockEditorPanel: View {
    let symbol: Symbol

    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter
    @State private var pinned = false
    @State private var alias = ""
    @State private var priceAbove = ""
    @State private var priceBelow = ""
    @State private var riseAbove = ""
    @State private var fallBelow = ""
    @State private var profitAbove = ""
    @State private var lossBelow = ""
    @State private var shares = ""
    @State private var cost = ""
    @State private var note = ""
    @State private var group = ""
    @State private var tradeShares = ""
    @State private var tradePrice = ""
    /// 分红送转：A 股填每 10 股派多少、送转多少，港股美股填每股派多少。
    @State private var dividendCash = ""
    @State private var dividendBonus = ""
    /// 刚记了一笔买卖：说明算出来的新持仓，保存后才生效。
    @State private var tradeMessage: String?
    /// 这只的买卖记录（最早的在前），记一笔、删一条都先改这里，保存时一起写回。
    @State private var trades: [Trade] = []
    @State private var loaded = false
    /// 滚动区里三块内容的高度，量出来以后滚动区就这么高（屏幕放不下时再矮一些）。
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            header
            if let item {
                // 三块内容放在一个滚动区里：屏幕矮、放不下时在里面滚动，底下的按钮总在。
                ScrollView {
                    VStack(spacing: 10) {
                        VStack(spacing: 0) {
                            Toggle(L("显示在菜单栏"), isOn: $pinned)
                                .toggleStyle(.switch)
                                .padding(.vertical, 8)
                            Divider()
                            HStack {
                                Text(L("菜单栏简称"))
                                Spacer()
                                TextField("", text: $alias, prompt: Text(NameAbbreviator.abbreviate(item.displayName)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                            }
                            .padding(.vertical, 8)
                            Divider()
                            HStack {
                                Text(L("分组"))
                                Spacer()
                                TextField("", text: $group, prompt: Text(L("不分组")))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                                Menu {
                                    ForEach(existingGroups, id: \.self) { name in
                                        Button(name) { group = name }
                                    }
                                    if !existingGroups.isEmpty {
                                        Divider()
                                    }
                                    Button(L("不分组")) { group = "" }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.button)
                                .buttonStyle(.borderless)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help(L("选一个已有的分组"))
                            }
                            .padding(.vertical, 8)
                            Divider()
                            HStack(alignment: .firstTextBaseline) {
                                Text(L("备注"))
                                Spacer()
                                TextField("", text: $note, prompt: Text(L("比如关注的理由")), axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(1...3)
                                    .frame(width: 220)
                            }
                            .padding(.vertical, 8)
                        }
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 12)
                        .glassCard()

                        if symbol.canHold {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("持仓"))
                                    .font(.system(size: 12.5, weight: .semibold))
                                numberField(L("持有数量"), text: $shares, unit: shareUnit, placeholder: L("没有持仓"))
                                numberField(L("成本价"), text: $cost, unit: currency, placeholder: L("每股成本"), allowZero: true)
                                tradeRow
                                dividendRow
                                Text(holdingFooter)
                                    .font(.system(size: 11))
                                    .foregroundStyle(holdingState == .invalid ? Color.orange : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let tradeMessage {
                                    Text(tradeMessage)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.accentColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if !trades.isEmpty {
                                    tradeList
                                }
                            }
                            .padding(12)
                            .glassCard()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("价格提醒"))
                                .font(.system(size: 12.5, weight: .semibold))
                            numberField(L("价格高于"), text: $priceAbove, unit: currency)
                            numberField(L("价格低于"), text: $priceBelow, unit: currency)
                            numberField(L("涨幅达到"), text: $riseAbove, unit: "%")
                            numberField(L("跌幅达到"), text: $fallBelow, unit: "%")
                            // 止盈止损按持仓成本算，填了持仓才有。
                            if case .valid(let holding) = holdingState, holding.cost > 0 {
                                numberField(L("持仓盈利达到"), text: $profitAbove, unit: "%")
                                numberField(L("持仓亏损达到"), text: $lossBelow, unit: "%")
                            }
                            Text(alertFooter)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .glassCard()
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: EditorContentHeightKey.self, value: proxy.size.height)
                    })
                }
                .frame(height: contentHeight > 0 ? min(contentHeight, router.pageMaxHeight) : nil)
                .onPreferenceChange(EditorContentHeightKey.self) { contentHeight = $0 }

                HStack {
                    Button(L("删除自选"), role: .destructive) {
                        store.remove(symbol)
                        router.route = .list
                    }
                    Spacer()
                    Button(L("取消")) { router.route = .list }
                    Button(L("保存")) { save(item) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
                .controlSize(.regular)
                .padding(.horizontal, 2)
            } else {
                Text(L("这只证券已不在自选中"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .glassCard()
            }
        }
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                router.route = .list
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .help(L("返回（Esc）"))
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.displayName ?? symbol.displayCode)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("\(symbol.market.region.displayName) \(symbol.displayCode)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .glassCard(prominent: true)
    }

    /// 记一笔买卖：买入按加权平均重新算成本，卖出只减数量。价格不填时按现价。
    private var tradeRow: some View {
        editorRow(L("记一笔")) {
            TextField("", text: $tradeShares, prompt: Text(L("数量")))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text(shareUnit)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("", text: $tradePrice, prompt: Text(currentPriceText ?? L("价格")))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Button(L("买入"), action: buy)
                .disabled(tradeAmount == nil || tradeUnitPrice == nil || holdingState == .invalid)
            Button(L("卖出"), action: sell)
                .disabled(tradeAmount == nil || tradeUnitPrice == nil || !canSell)
        }
        .controlSize(.small)
        .help(L("按成交记一笔：买入按加权平均重新算成本价，卖出只减少数量、按成本价算出赚了多少。记完检查一下，点保存才生效"))
    }

    /// 编辑页里左边是标题、右边是一排输入框和按钮的一行。一行放不下时（英文的字比中文长）标题单独放在上面一行，
    /// 输入框和按钮靠右排在下面，不把标题挤成两行。
    private func editorRow<Controls: View>(_ title: String, @ViewBuilder controls: () -> Controls) -> some View {
        let controls = controls()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 4)
                controls
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5))
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
    }

    /// A 股的分红按“每 10 股”说（10 派 25 元、10 送 4 股），港股、美股按每股，场外基金按每份。
    private var perTen: Bool { symbol.market.region == .cn && !symbol.isFund }

    /// 数量的单位：场外基金是份，别的是股。
    private var shareUnit: String { symbol.isFund ? L("份") : L("股") }

    /// 分红送转：现金分红从总成本里扣掉，送转的股加到数量里，成本价跟着摊薄。港股、美股只有现金分红。
    private var dividendRow: some View {
        editorRow(L("分红送转")) {
            Text(perTen ? L("10股派") : (symbol.isFund ? L("每份派") : L("每股派")))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("", text: $dividendCash, prompt: Text("0"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            if perTen {
                Text(L("送转"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("", text: $dividendBonus, prompt: Text("0"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 36)
                Text(L("股"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button(L("记一笔"), action: recordDividend)
                .disabled(dividendInput == nil)
        }
        .controlSize(.small)
        .help(perTen
            ? L("按公告填，比如“10 派 25 元”填 25，“10 送 4 股”在送转里填 4。现金分红从成本里扣掉，送转的股加到持有数量里，成本价跟着摊薄。点保存才生效")
            : (symbol.isFund
                ? L("按公告填每份派多少。现金分红从成本里扣掉，成本价跟着摊薄。点保存才生效")
                : L("按公告填每股派多少。现金分红从成本里扣掉，成本价跟着摊薄。点保存才生效")))
    }

    /// 填好的分红送转，换算成每股：(现金, 送转)。没填、填错或者没有持仓时为 nil。
    private var dividendInput: (cash: Double, bonus: Double)? {
        guard case .valid(let holding) = holdingState else { return nil }
        let scale = perTen ? 10.0 : 1.0
        var values: [Double] = []
        for text in [dividendCash, perTen ? dividendBonus : ""] {
            switch parse(text, allowZero: true) {
            case .empty: values.append(0)
            case .value(let value): values.append(value / scale)
            case .invalid: return nil
            }
        }
        guard holding.applyingDividend(cash: values[0], bonus: values[1]) != nil else { return nil }
        return (values[0], values[1])
    }

    private func recordDividend() {
        guard case .valid(let holding) = holdingState, let input = dividendInput,
              let updated = holding.applyingDividend(cash: input.cash, bonus: input.bonus)
        else { return }
        let trade = Trade.dividend(cash: input.cash, bonus: input.bonus, holding: holding, day: tradeDay)
        trades = trades.appending([trade])
        shares = QuoteFormatter.plain(updated.shares)
        cost = QuoteFormatter.plain(updated.cost)
        tradeMessage = L("%@，到手 %@：持有 %@ %@，成本摊薄到 %@。点保存生效", dividendText(trade), QuoteFormatter.money(trade.profit ?? 0), shares, shareUnit, cost)
        dividendCash = ""
        dividendBonus = ""
    }

    /// “10 派 25、送 4”或“每股派 0.5”。
    private func dividendText(_ trade: Trade) -> String {
        guard perTen else {
            let cash = QuoteFormatter.plain(trade.price)
            return symbol.isFund ? L("每份派 %@", cash) : L("每股派 %@", cash)
        }
        var parts: [String] = []
        if trade.price > 0 { parts.append(L("10 派 %@", QuoteFormatter.plain(trade.price * 10))) }
        if let bonus = trade.bonus, bonus > 0 { parts.append(L("送转 %@", QuoteFormatter.plain(bonus * 10))) }
        return parts.joined(separator: L("、"))
    }

    /// 最近的买卖：最新的在前，最多列 3 笔（编辑页不滚动，太长小屏幕放不下），标题行写着一共几笔和今年卖出、
    /// 分红一共赚了多少。删掉一条只删记录，不改持仓。
    private var tradeList: some View {
        let recent = Array(trades.indices.reversed().prefix(3))
        let yearStart = Portfolio.yearStart(now: Date())
        let realized = trades.realizedProfit(since: yearStart)
        let hasRealized = trades.contains { $0.profit != nil && $0.day >= yearStart }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(trades.count > recent.count ? L("最近的买卖（共 %@ 笔）", trades.count) : L("最近的买卖"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if hasRealized {
                    Text(L("今年已实现 ") + QuoteFormatter.signedMoney(realized))
                        .foregroundStyle(Theme.priceColor(for: PriceDirection(realized), convention: settings.colorConvention))
                        .help(L("今年卖出和分红一共赚了多少"))
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .lineLimit(1)
            ForEach(recent, id: \.self) { index in
                tradeLine(trades[index]) {
                    if trades.indices.contains(index) { trades.remove(at: index) }
                }
            }
        }
        .padding(.top, 2)
    }

    private func tradeLine(_ trade: Trade, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(dayText(trade.day))
                .foregroundStyle(.secondary)
            if trade.side == .dividend {
                Text(L("分红 ") + dividendText(trade))
            } else {
                Text("\(trade.side.title) \(QuoteFormatter.plain(trade.shares)) \(shareUnit) @ \(QuoteFormatter.plain(trade.price))")
            }
            Spacer(minLength: 4)
            if let profit = trade.profit {
                Text(QuoteFormatter.signedMoney(profit))
                    .foregroundStyle(Theme.priceColor(for: PriceDirection(profit), convention: settings.colorConvention))
            }
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(L("删掉这条记录（不改持仓），保存后生效"))
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
    }

    /// 今年的只写月日。
    private func dayText(_ day: String) -> String {
        day.hasPrefix(String(Portfolio.yearStart(now: Date()).prefix(5))) ? String(day.dropFirst(5)) : day
    }

    /// 现在记的一笔算哪个交易日（见 Trade.day）。
    private var tradeDay: String {
        let region = symbol.market.region
        return Trade.day(for: region, now: Date(), latestQuoteTime: store.latestQuoteTime(for: region))
    }

    private var currentPriceText: String? {
        store.quotes[symbol].map { QuoteFormatter.plain($0.price) }
    }

    private var tradeAmount: Double? {
        if case .value(let value) = parse(tradeShares) { return value }
        return nil
    }

    /// 成交价：填了用填的，没填用现价。
    private var tradeUnitPrice: Double? {
        switch parse(tradePrice, allowZero: true) {
        case .value(let value): return value
        case .empty: return store.quotes[symbol]?.price
        case .invalid: return nil
        }
    }

    private var canSell: Bool {
        guard case .valid(let holding) = holdingState, let amount = tradeAmount else { return false }
        return holding.selling(shares: amount) != nil
    }

    private func buy() {
        guard let amount = tradeAmount, let price = tradeUnitPrice else { return }
        let updated: Holding
        switch holdingState {
        case .valid(let holding):
            guard let bought = holding.buying(shares: amount, at: price) else { return }
            updated = bought
        case .none:
            updated = Holding(shares: amount, cost: price)
        case .invalid:
            return
        }
        shares = QuoteFormatter.plain(updated.shares)
        cost = QuoteFormatter.plain(updated.cost)
        trades = trades.appending([Trade(side: .buy, shares: amount, price: price, day: tradeDay)])
        tradeMessage = L("买入 %@ %@ @ %@：持有 %@ %@，成本 %@。点保存生效", QuoteFormatter.plain(amount), shareUnit, QuoteFormatter.plain(price), shares, shareUnit, cost)
        tradeShares = ""
        tradePrice = ""
    }

    private func sell() {
        guard case .valid(let holding) = holdingState, let amount = tradeAmount, let price = tradeUnitPrice,
              let remaining = holding.selling(shares: amount)
        else { return }
        let trade = Trade.sell(amount, at: price, from: holding, day: tradeDay)
        trades = trades.appending([trade])
        let realized = L("已实现 ") + QuoteFormatter.signedMoney(trade.profit ?? 0)
        if remaining.isValid {
            shares = QuoteFormatter.plain(remaining.shares)
            tradeMessage = L("卖出 %@ %@ @ %@，%@：还剩 %@ %@，成本不变。点保存生效", QuoteFormatter.plain(amount), shareUnit, QuoteFormatter.plain(price), realized, shares, shareUnit)
        } else {
            shares = ""
            cost = ""
            tradeMessage = L("全部卖出 @ %@，%@。保存后清掉持仓，买卖记录还留着", QuoteFormatter.plain(price), realized)
        }
        tradeShares = ""
        tradePrice = ""
    }

    private var item: WatchItem? { store.item(for: symbol) }

    /// 自选里已经有的分组，编辑时可以直接选。
    private var existingGroups: [String] { Watchlist.groups(in: store.items) }

    /// 价格后面写的货币。期货外汇不写：外汇的价格是另一种货币的汇率，期货是每盎司、每桶多少美元。
    private var currency: String { symbol.isGlobal ? "" : symbol.market.region.currency }

    private var alertFooter: String {
        var text = L("留空表示不提醒。每个条件每个交易日最多提醒一次。")
        if let quote = store.quotes[symbol] {
            text += L("现价 %@，", QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))
                + L("今日 %@。", QuoteFormatter.percent(quote.changePercent))
        }
        return text
    }

    private var holdingFooter: String {
        switch holdingState {
        case .invalid:
            return L("持有数量和成本价要一起填写，数量大于 0，成本价不小于 0。")
        case .none:
            return L("填写后在列表和详情里显示持仓盈亏，面板上方按币种合计。只保存在本机和你的 iCloud 里。")
        case .valid(let holding):
            guard let quote = store.quotes[symbol], let position = Portfolio.position(holding, quote: quote) else {
                return L("按现价计算持仓盈亏。")
            }
            var text = L("按现价 %@，", QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))
                + L("市值 %@，持仓盈亏 %@", QuoteFormatter.money(position.marketValue), QuoteFormatter.signedMoney(position.totalProfit))
            if let percent = position.totalProfitPercent {
                text += L("（%@）", QuoteFormatter.percent(percent))
            }
            return text + L("。")
        }
    }

    private enum HoldingState: Equatable {
        case none
        case valid(Holding)
        case invalid
    }

    /// 两项都空表示没有持仓；只填一项或者数字不对都算无效。
    private var holdingState: HoldingState {
        switch (parse(shares), parse(cost, allowZero: true)) {
        case (.empty, .empty): return .none
        case (.value(let count), .value(let price)): return .valid(Holding(shares: count, cost: price))
        default: return .invalid
        }
    }

    private func numberField(
        _ title: String, text: Binding<String>, unit: String, placeholder: String = L("不提醒"), allowZero: Bool = false
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
            Spacer()
            TextField("", text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .foregroundStyle(parse(text.wrappedValue, allowZero: allowZero) == .invalid ? Color.red : Color.primary)
            Text(unit)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                // 英文的单位（shares、units）比“股”“份”宽。
                .frame(width: AppLanguage.isEnglish ? 40 : 30, alignment: .leading)
        }
    }

    private enum ParsedNumber: Equatable {
        case empty, value(Double), invalid
    }

    private func parse(_ text: String, allowZero: Bool = false) -> ParsedNumber {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        if trimmed.isEmpty { return .empty }
        guard let value = Double(trimmed), value.isFinite, allowZero ? value >= 0 : value > 0 else { return .invalid }
        return .value(value)
    }

    private func value(_ text: String) -> Double? {
        if case .value(let v) = parse(text) { return v }
        return nil
    }

    private var isValid: Bool {
        [priceAbove, priceBelow, riseAbove, fallBelow, profitAbove, lossBelow].allSatisfy { parse($0) != .invalid }
            && holdingState != .invalid
    }

    private func load() {
        guard !loaded, let item else { return }
        loaded = true
        pinned = item.pinned
        alias = item.alias ?? ""
        priceAbove = format(item.alert.priceAbove)
        priceBelow = format(item.alert.priceBelow)
        riseAbove = format(item.alert.riseAbove)
        fallBelow = format(item.alert.fallBelow)
        profitAbove = format(item.alert.profitAbove)
        lossBelow = format(item.alert.lossBelow)
        shares = item.holding.map { QuoteFormatter.plain($0.shares) } ?? ""
        note = item.note ?? ""
        group = item.group ?? ""
        cost = format(item.holding?.cost)
        trades = item.trades
    }

    /// 输入框里显示的数字。不用 %g：它只保留 6 位有效数字，大数还会变成科学计数法。
    private func format(_ value: Double?) -> String {
        value.map(QuoteFormatter.plain) ?? ""
    }

    private func save(_ item: WatchItem) {
        var updated = item
        updated.pinned = pinned
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        updated.alias = trimmedAlias.isEmpty ? nil : trimmedAlias
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.note = trimmedNote.isEmpty ? nil : trimmedNote
        updated.group = WatchItem.normalizedGroup(group)
        updated.trades = trades
        // 没有持仓（或者成本为 0）时止盈止损没有意义，一起清掉。
        var hasCost = false
        if case .valid(let holding) = holdingState {
            updated.holding = holding
            hasCost = holding.cost > 0
        } else {
            updated.holding = nil
        }
        updated.alert = PriceAlert(
            priceAbove: value(priceAbove),
            priceBelow: value(priceBelow),
            riseAbove: value(riseAbove),
            fallBelow: value(fallBelow),
            profitAbove: hasCost ? value(profitAbove) : nil,
            lossBelow: hasCost ? value(lossBelow) : nil
        )
        if !updated.alert.isEmpty {
            Notifier.shared.requestAuthorization()
        }
        store.update(updated)
        router.route = .list
    }
}

/// 编辑页滚动区里内容的高度。
private struct EditorContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
