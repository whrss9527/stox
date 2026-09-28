import AppKit
import SwiftUI
import StoxCore

/// 面板根视图：自选列表、设置、单只证券编辑三个页面。
struct PanelView: View {
    @EnvironmentObject private var router: PanelRouter
    let close: () -> Void

    var body: some View {
        Group {
            switch router.route {
            case .list:
                WatchlistPanel(close: close)
            case .settings:
                SettingsPanel()
            case .edit(let symbol):
                StockEditorPanel(symbol: symbol)
            }
        }
        .frame(width: Theme.panelWidth)
    }
}

// MARK: - 自选列表页

struct WatchlistPanel: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            SearchBar()
            Divider()
            if router.trimmedQuery.isEmpty {
                WatchlistView()
            } else {
                SearchResultsView()
            }
            Divider()
            PanelFooter()
        }
        .task(id: router.searchText) {
            await router.runSearch(using: store)
        }
    }
}

struct PanelHeader: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        HStack(spacing: 10) {
            Text("Stox")
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(store.activeRegions, id: \.self) { region in
                    let phase = store.phase(for: region)
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Theme.phaseColor(phase))
                            .frame(width: 6, height: 6)
                        Text("\(region.displayName)\(phase.displayName)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .help(region == .hk ? "港股行情延时约 15 分钟" : "")
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
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("立即刷新（⌘R）")
            Button {
                router.route = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help("设置（⌘,）")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

struct SearchBar: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("添加自选：代码 / 名称 / 拼音，如 600519、腾讯、aapl", text: $router.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit(addFirstResult)
            if router.isSearching {
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
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 回车：添加第一条搜索结果。
    private func addFirstResult() {
        guard let first = router.searchResults.first(where: { !store.contains($0.symbol) }) else { return }
        store.add(first.symbol, name: first.typeCode == "按代码添加" ? "" : first.name)
        router.clearSearch()
    }
}

struct WatchlistView: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    private static let maxHeight: CGFloat = 440

    var body: some View {
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
            .frame(height: 150)
        } else {
            List {
                ForEach(store.items) { item in
                    QuoteRow(item: item, quote: store.quotes[item.symbol], expanded: router.expanded == item.symbol)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .frame(height: listHeight)
        }
    }

    private var listHeight: CGFloat {
        var height = CGFloat(store.items.count) * QuoteRow.rowHeight
        if let expanded = router.expanded, store.contains(expanded), store.quotes[expanded] != nil {
            height += QuoteRow.detailHeight
        }
        return min(max(height, QuoteRow.rowHeight * 2), Self.maxHeight)
    }
}

struct SearchResultsView: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        VStack(spacing: 0) {
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
                                store.add(result.symbol, name: result.typeCode == "按代码添加" ? "" : result.name)
                                router.clearSearch()
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(router.searchResults.count) * SearchResultRow.height, 360))
            }
        }
    }
}

struct SearchResultRow: View {
    static let height: CGFloat = 38

    let result: SearchResult
    let added: Bool
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            MarketBadge(market: result.symbol.market)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("\(result.symbol.displayCode) · \(result.typeLabel)")
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
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background(hovering && !added ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if !added { add() }
        }
    }
}

struct PanelFooter: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 6) {
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .keyboardShortcut("q", modifiers: .command)
            .help("退出 Stox（⌘Q）")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var statusText: String {
        guard let updated = store.lastUpdated else { return "正在获取行情…" }
        return "\(QuoteFormatter.time(updated)) 更新 · 每 \(Int(settings.refreshInterval)) 秒刷新 · 拖动可排序"
    }
}

struct MarketBadge: View {
    let market: Market

    var body: some View {
        Text(market.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.marketTint(market))
            .frame(width: 15, height: 13)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.marketTint(market).opacity(0.14)))
    }
}
