import AppKit
import SwiftUI
import StoxCore

/// 单只证券的设置：菜单栏显示、简称、持仓、价格提醒。在面板里打开，Esc 返回列表。
@MainActor
struct StockEditorPanel: View {
    let symbol: Symbol

    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter
    @State private var pinned = false
    @State private var alias = ""
    @State private var priceAbove = ""
    @State private var priceBelow = ""
    @State private var riseAbove = ""
    @State private var fallBelow = ""
    @State private var shares = ""
    @State private var cost = ""
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 10) {
            header
            if let item {
                VStack(spacing: 0) {
                    Toggle("显示在菜单栏", isOn: $pinned)
                        .toggleStyle(.switch)
                        .padding(.vertical, 8)
                    Divider()
                    HStack {
                        Text("菜单栏简称")
                        Spacer()
                        TextField("", text: $alias, prompt: Text(NameAbbreviator.abbreviate(item.displayName)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                    .padding(.vertical, 8)
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text("备注")
                        Spacer()
                        TextField("", text: $note, prompt: Text("比如关注的理由"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                            .frame(width: 220)
                    }
                    .padding(.vertical, 8)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .glassCard()

                if !symbol.isIndex {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("持仓")
                            .font(.system(size: 12.5, weight: .semibold))
                        numberField("持有数量", text: $shares, unit: "股", placeholder: "没有持仓")
                        numberField("成本价", text: $cost, unit: currency, placeholder: "每股成本", allowZero: true)
                        Text(holdingFooter)
                            .font(.system(size: 11))
                            .foregroundStyle(holdingState == .invalid ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .glassCard()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("价格提醒")
                        .font(.system(size: 12.5, weight: .semibold))
                    numberField("价格高于", text: $priceAbove, unit: currency)
                    numberField("价格低于", text: $priceBelow, unit: currency)
                    numberField("涨幅达到", text: $riseAbove, unit: "%")
                    numberField("跌幅达到", text: $fallBelow, unit: "%")
                    Text(alertFooter)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .glassCard()

                HStack {
                    Button("删除自选", role: .destructive) {
                        store.remove(symbol)
                        router.route = .list
                    }
                    Spacer()
                    Button("取消") { router.route = .list }
                    Button("保存") { save(item) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
                .controlSize(.regular)
                .padding(.horizontal, 2)
            } else {
                Text("这只证券已不在自选中")
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
            .help("返回（Esc）")
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

    private var item: WatchItem? { store.item(for: symbol) }

    private var currency: String { symbol.market.region.currency }

    private var alertFooter: String {
        var text = "留空表示不提醒。每个条件每个交易日最多提醒一次。"
        if let quote = store.quotes[symbol] {
            text += "现价 \(QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))，"
                + "今日 \(QuoteFormatter.percent(quote.changePercent))。"
        }
        return text
    }

    private var holdingFooter: String {
        switch holdingState {
        case .invalid:
            return "持有数量和成本价要一起填写，数量大于 0，成本价不小于 0。"
        case .none:
            return "填写后在列表和详情里显示持仓盈亏，面板上方按币种合计。只保存在本机和你的 iCloud 里。"
        case .valid(let holding):
            guard let quote = store.quotes[symbol], let position = Portfolio.position(holding, quote: quote) else {
                return "按现价计算持仓盈亏。"
            }
            var text = "按现价 \(QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))，"
                + "市值 \(QuoteFormatter.money(position.marketValue))，持仓盈亏 \(QuoteFormatter.signedMoney(position.totalProfit))"
            if let percent = position.totalProfitPercent {
                text += "（\(QuoteFormatter.percent(percent))）"
            }
            return text + "。"
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
        _ title: String, text: Binding<String>, unit: String, placeholder: String = "不提醒", allowZero: Bool = false
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
                .frame(width: 30, alignment: .leading)
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
        [priceAbove, priceBelow, riseAbove, fallBelow].allSatisfy { parse($0) != .invalid } && holdingState != .invalid
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
        shares = item.holding.map { QuoteFormatter.plain($0.shares) } ?? ""
        note = item.note ?? ""
        cost = format(item.holding?.cost)
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
        updated.alert = PriceAlert(
            priceAbove: value(priceAbove),
            priceBelow: value(priceBelow),
            riseAbove: value(riseAbove),
            fallBelow: value(fallBelow)
        )
        if case .valid(let holding) = holdingState {
            updated.holding = holding
        } else {
            updated.holding = nil
        }
        if !updated.alert.isEmpty {
            Notifier.shared.requestAuthorization()
        }
        store.update(updated)
        router.route = .list
    }
}
