import AppKit
import SwiftUI
import StoxCore

/// 面板内的二级页面标题栏：返回按钮 + 标题。
struct NavigationHeader: View {
    let title: String
    var subtitle: String?
    let back: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("返回（Esc）")
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}

struct SettingsPanel: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(spacing: 0) {
            NavigationHeader(title: "设置") { router.route = .list }
            Divider()
            Form {
                Section("行情刷新") {
                    Picker("刷新间隔", selection: $settings.refreshInterval) {
                        ForEach(SettingsStore.intervalOptions, id: \.self) { seconds in
                            Text("\(Int(seconds)) 秒").tag(seconds)
                        }
                    }
                    Toggle("休市时降低刷新频率（每分钟一次）", isOn: $settings.slowWhenIdle)
                }

                Section("菜单栏") {
                    Toggle("显示名称", isOn: $settings.showName)
                    Toggle("显示价格", isOn: $settings.showPrice)
                    Toggle("显示涨跌幅", isOn: $settings.showPercent)
                    Toggle("固定多只时轮播显示", isOn: $settings.rotateTicker)
                    Toggle("隐藏行情，只显示图标", isOn: $settings.hideTicker)
                }

                Section("外观") {
                    Picker("涨跌颜色", selection: $settings.colorConvention) {
                        ForEach(ColorConvention.allCases) { convention in
                            Text(convention.title).tag(convention)
                        }
                    }
                }

                Section {
                    Toggle("全局快捷键 ⌃⌥S 打开 / 关闭面板", isOn: $settings.hotKeyEnabled)
                    Toggle("价格提醒通知", isOn: $settings.alertsEnabled)
                    Toggle("开机自动启动", isOn: launchAtLoginBinding)
                        .disabled(!LoginItem.isAvailable)
                    if let loginItemError {
                        Text(loginItemError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("通用")
                }

                Section {
                    Text("行情来自腾讯财经公开接口，仅供参考。港股延时约 15 分钟。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("版本 \(appVersion)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("GitHub") {
                            if let url = URL(string: "https://github.com/whrss9527/stox") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                } header: {
                    Text("关于")
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 520)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                    loginItemError = nil
                } catch {
                    loginItemError = "设置失败：\(error.localizedDescription)"
                }
                launchAtLogin = LoginItem.isEnabled
            }
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }
}

/// 单只证券的设置：菜单栏显示、简称、价格提醒。
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
        VStack(spacing: 0) {
            NavigationHeader(title: item?.displayName ?? symbol.displayCode, subtitle: symbol.displayCode) {
                router.route = .list
            }
            Divider()
            if let item {
                Form {
                    Section("菜单栏") {
                        Toggle("显示在菜单栏", isOn: $pinned)
                        TextField("简称", text: $alias, prompt: Text(NameAbbreviator.abbreviate(item.displayName)))
                    }
                    Section {
                        numberField("价格高于", text: $priceAbove, unit: currency)
                        numberField("价格低于", text: $priceBelow, unit: currency)
                        numberField("涨幅达到", text: $riseAbove, unit: "%")
                        numberField("跌幅达到", text: $fallBelow, unit: "%")
                    } header: {
                        Text("价格提醒")
                    } footer: {
                        Text(alertFooter)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Button("删除自选", role: .destructive) {
                        store.remove(symbol)
                        router.route = .list
                    }
                    Spacer()
                    Button("取消") { router.route = .list }
                    Button("保存") { save(item) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
                .padding(12)
            } else {
                Text("这只证券已不在自选中")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 470)
        .onAppear(perform: load)
    }

    private var item: WatchItem? { store.item(for: symbol) }

    private var currency: String { symbol.market.region.currency }

    private var alertFooter: String {
        var text = "留空表示不提醒。每个条件每个交易日最多提醒一次。"
        if let quote = store.quotes[symbol] {
            text += "\n现价 \(QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))，"
                + "今日 \(QuoteFormatter.percent(quote.changePercent))。"
        }
        return text
    }

    private func numberField(_ title: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            TextField(title, text: text, prompt: Text("不提醒"))
                .multilineTextAlignment(.trailing)
            Text(unit)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
        }
        .foregroundStyle(parse(text.wrappedValue) == .invalid ? Color.red : Color.primary)
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
