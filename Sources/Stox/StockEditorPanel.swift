import AppKit
import SwiftUI
import StoxCore

/// 单只证券的设置：菜单栏显示、简称、价格提醒。在面板里打开，Esc 返回列表。
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
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .glassCard()

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

    private func numberField(_ title: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
            Spacer()
            TextField("", text: text, prompt: Text("不提醒"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .foregroundStyle(parse(text.wrappedValue) == .invalid ? Color.red : Color.primary)
            Text(unit)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
        }
    }

    private enum ParsedNumber: Equatable {
        case empty, value(Double), invalid
    }

    private func parse(_ text: String) -> ParsedNumber {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        guard let value = Double(trimmed), value > 0 else { return .invalid }
        return .value(value)
    }

    private func value(_ text: String) -> Double? {
        if case .value(let v) = parse(text) { return v }
        return nil
    }

    private var isValid: Bool {
        [priceAbove, priceBelow, riseAbove, fallBelow].allSatisfy { parse($0) != .invalid }
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
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%g", value)
    }

    private func save(_ item: WatchItem) {
        var updated = item
        updated.pinned = pinned
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        updated.alias = trimmedAlias.isEmpty ? nil : trimmedAlias
        updated.alert = PriceAlert(
            priceAbove: value(priceAbove),
            priceBelow: value(priceBelow),
            riseAbove: value(riseAbove),
            fallBelow: value(fallBelow)
        )
        if !updated.alert.isEmpty {
            Notifier.shared.requestAuthorization()
        }
        store.update(updated)
        router.route = .list
    }
}
