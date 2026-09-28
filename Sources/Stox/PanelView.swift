import AppKit
import SwiftUI
import StoxCore

struct PanelActions {
    var openSettings: (SettingsPage?) -> Void
    var quit: () -> Void
    /// SwiftUI 量出来的面板实际尺寸，窗口跟着调整。
    var sizeChanged: (CGSize) -> Void
}

struct PanelSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// 面板根视图：自选列表页和单只证券的编辑页，外面是一层玻璃。
@MainActor
struct PanelView: View {
    @EnvironmentObject private var router: PanelRouter
    let actions: PanelActions

    var body: some View {
        Group {
            switch router.route {
            case .list:
                WatchlistPanel(actions: actions)
            case .edit(let symbol):
                StockEditorPanel(symbol: symbol)
            }
        }
        .padding(12)
        .frame(width: Theme.panelWidth)
        .background(GlassPanelBackground())
        .padding(8)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { size in
            actions.sizeChanged(size)
        }
    }
}

// MARK: - 自选列表页

@MainActor
struct WatchlistPanel: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter
    let actions: PanelActions

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader()
            SearchBar()
            if router.trimmedQuery.isEmpty {
                HoldingsSummaryView()
                WatchlistView()
            } else if router.batch != nil {
                BatchAddView()
            } else {
                SearchResultsView()
            }
            UpdateBanner { actions.openSettings(.about) }
            PanelFooter(actions: actions)
        }
        .task(id: router.searchText) {
            await router.runSearch(using: store)
        }
    }
}

@MainActor
struct PanelHeader: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Stox")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    ForEach(store.activeRegions, id: \.self) { region in
                        let phase = store.phase(for: region)
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Theme.phaseColor(phase, convention: settings.colorConvention))
                                .frame(width: 6, height: 6)
                            Text("\(region.displayName)\(phase.displayName)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .help(region == .hk ? "港股行情延时约 15 分钟" : "")
                    }
                }
            }
            Spacer(minLength: 4)
            if let error = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("刷新失败：\(error)")
            }
            Button {
                store.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 180 : 0))
                    .animation(.easeInOut(duration: 0.3), value: store.isRefreshing)
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .help("立即刷新（⌘R）")
        }
        .padding(10)
        .glassCard(prominent: true)
    }
}

@MainActor
struct SearchBar: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索代码、名称或拼音，回车添加", text: $router.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit(submit)
            if router.isSearching || router.isAddingBatch {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else if !router.searchText.isEmpty {
                Button {
                    router.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassCard(cornerRadius: 12)
    }

    /// 回车：粘贴了多个代码时全部添加，否则添加第一条搜索结果。
    private func submit() {
        if router.batch != nil {
            Task { await router.addBatch(using: store) }
        } else {
            addFirstResult()
        }
    }

    private func addFirstResult() {
        guard let candidate = router.submissionCandidate(excluding: { store.contains($0) }) else { return }
        store.add(candidate.symbol, name: candidate.isDirect ? "" : candidate.name)
        router.clearSearch()
    }
}

@MainActor
struct WatchlistView: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    /// 屏幕够高时列表最多这么高；屏幕放不下整个面板时由 PanelRouter.listMaxHeight 再压低。
    static let defaultMaxHeight: CGFloat = 430

    var body: some View {
        Group {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("还没有自选，在上面的搜索框里添加")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(store.items) { item in
                            QuoteRow(item: item, quote: store.quotes[item.symbol], expanded: router.expanded == item.symbol)
                                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .id(item.symbol)
                        }
                        .onMove { source, destination in
                            store.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 1)
                    .frame(height: listHeight)
                    .padding(.vertical, 6)
                    .onAppear { reveal(router.expanded, with: proxy) }
                    .onChange(of: router.expanded) { symbol in
                        reveal(symbol, with: proxy)
                    }
                }
            }
        }
        .glassCard()
    }

    /// 展开靠下的一只时，把整行滚到看得见的地方。等展开的动画和布局完成后再滚；
    /// 不给 anchor，只滚动需要的最小距离，本来就看得见的不会跳。
    private func reveal(_ symbol: Symbol?, with proxy: ScrollViewProxy) {
        guard let symbol else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(symbol)
            }
        }
    }

    private var listHeight: CGFloat {
        var height = CGFloat(store.items.count) * QuoteRow.rowHeight
        if let expanded = router.expanded, let item = store.item(for: expanded), store.quotes[expanded] != nil {
            height += QuoteRow.detailHeight(for: item)
        }
        return min(max(height, QuoteRow.rowHeight * 2), router.listMaxHeight)
    }
}

@MainActor
struct SearchResultsView: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        Group {
            if router.searchResults.isEmpty {
                Text(router.isSearching ? "搜索中…" : (router.searchError.map { "搜索失败：\($0)" } ?? "没有找到相关证券"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(router.searchResults) { result in
                            SearchResultRow(result: result, added: store.contains(result.symbol)) {
                                store.add(result.symbol, name: result.isDirect ? "" : result.name)
                                router.clearSearch()
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(router.searchResults.count) * SearchResultRow.height + 12, 360))
            }
        }
        .glassCard()
    }
}

/// 粘贴了多个代码时的批量添加：列出认出的代码，查过行情后标出已添加和不存在的。
@MainActor
struct BatchAddView: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        if let batch = router.batch {
            let pending = batch.symbols.filter { !store.contains($0) && !router.batchMissing.contains($0) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("认出 \(batch.symbols.count) 个代码")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button(pending.isEmpty ? "都已处理" : "全部添加（\(pending.count)）") {
                        Task { await router.addBatch(using: store) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(pending.isEmpty || router.isAddingBatch)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(batch.symbols, id: \.self) { symbol in
                            row(symbol)
                        }
                    }
                }
                .frame(height: min(CGFloat(batch.symbols.count) * 28, 280))
                if !batch.rejected.isEmpty {
                    Text("认不出：" + batch.rejected.joined(separator: "、"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let error = router.batchError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Text("回车全部添加，会先查一次行情，只添加存在的代码。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .glassCard()
        }
    }

    private func row(_ symbol: Symbol) -> some View {
        HStack(spacing: 8) {
            MarketBadge(market: symbol.market)
            if let item = store.item(for: symbol), !item.name.isEmpty {
                Text(item.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(symbol.displayCode)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(symbol.displayCode)
                    .font(.system(size: 12.5).monospacedDigit())
            }
            Spacer()
            if store.contains(symbol) {
                Label("已添加", systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if router.batchMissing.contains(symbol) {
                Label("没有这个代码", systemImage: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 4)
    }
}

/// 有持仓时显示在列表上方：按币种分别合计的今日盈亏、持仓盈亏和市值，排成一张小表。
@MainActor
struct HoldingsSummaryView: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        let summaries = Portfolio.summaries(items: store.items, quotes: store.quotes)
        if !summaries.isEmpty {
            // 只有一种货币时不需要货币那一列。
            let showsCurrency = summaries.count > 1
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    if showsCurrency {
                        Color.clear
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    header("今日盈亏")
                    header("持仓盈亏")
                    header(showsCurrency ? "市值" : "持仓市值")
                        .gridColumnAlignment(.trailing)
                }
                ForEach(summaries, id: \.region) { summary in
                    GridRow(alignment: .firstTextBaseline) {
                        if showsCurrency {
                            Text(summary.region.currencyName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        profit(summary.dayProfit, percent: summary.dayProfitPercent)
                        profit(summary.totalProfit, percent: summary.totalProfitPercent)
                        Text(QuoteFormatter.money(summary.marketValue))
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCard()
            .help("按现价计算。人民币、港币、美元分别合计，不换算")
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    /// 金额在上、比例在下，窄一点也放得下。
    private func profit(_ value: Double, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(QuoteFormatter.signedMoney(value))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            if let percent {
                Text(QuoteFormatter.percent(percent))
                    .font(.system(size: 10).monospacedDigit())
            }
        }
        .foregroundStyle(Theme.priceColor(for: PriceDirection(value), convention: settings.colorConvention))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct SearchResultRow: View {
    static let height: CGFloat = 40

    let result: SearchResult
    let added: Bool
    let add: () -> Void

    var body: some View {
        Button {
            if !added { add() }
        } label: {
            HStack(spacing: 8) {
                MarketBadge(market: result.symbol.market)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(result.isDirect ? "按代码添加" : "\(result.symbol.displayCode) · \(result.typeLabel)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if added {
                    Label("已添加", systemImage: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .disabled(added)
    }
}

@MainActor
struct PanelFooter: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 6) {
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                actions.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            .help("设置（⌘,）")
            Button {
                actions.quit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
            .help("退出 Stox（⌘Q）")
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        guard let updated = store.lastUpdated else { return "正在获取行情…" }
        let cadence = store.effectiveInterval > settings.refreshInterval
            ? "休市中每分钟刷新"
            : "每 \(Int(settings.refreshInterval)) 秒刷新"
        return "\(QuoteFormatter.time(updated)) 更新 · \(cadence) · 拖动排序"
    }
}

@MainActor
struct MarketBadge: View {
    @EnvironmentObject private var settings: SettingsStore
    let market: Market

    var body: some View {
        let tint = Theme.marketTint(market, convention: settings.colorConvention)
        Text(market.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 15, height: 13)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.14)))
    }
}
