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
                WatchlistView()
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
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassCard(cornerRadius: 12)
    }

    /// 回车：添加第一条搜索结果。
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

    private static let maxHeight: CGFloat = 430

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
                List {
                    ForEach(store.items) { item in
                        QuoteRow(item: item, quote: store.quotes[item.symbol], expanded: router.expanded == item.symbol)
                            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
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
                .padding(.vertical, 6)
            }
        }
        .glassCard()
    }

    private var listHeight: CGFloat {
        var height = CGFloat(store.items.count) * QuoteRow.rowHeight
        if let expanded = router.expanded, store.contains(expanded), store.quotes[expanded] != nil {
            height += QuoteRow.detailHeight
        }
        return min(max(height, QuoteRow.rowHeight * 2), Self.maxHeight)
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
