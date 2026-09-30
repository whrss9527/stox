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

/// 列表上方几张卡片（更新提示、小技巧、持仓合计）各自的高度，屏幕放不下时用来算它们能占多高。
struct CardHeightsKey: PreferenceKey {
    static let defaultValue: [CGFloat] = []

    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
        value += nextValue()
    }
}

extension View {
    /// 报告这张卡片的高度（见 CardHeightsKey）。
    func reportsCardHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: CardHeightsKey.self, value: [proxy.size.height])
        })
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
            case .group(let name, let member):
                GroupEditorPanel(original: name, member: member)
            case .alerts:
                AlertLogPanel()
            case .rank:
                RankPanel()
            case .calendar:
                ProfitCalendarPanel()
            }
        }
        .padding(12)
        .frame(width: Theme.panelWidth)
        .background(GlassPanelBackground())
        .padding(8)
        // 按内容本来的高度量：窗口比内容矮时 SwiftUI 会把内容压扁去凑窗口，量出来的就不是真的高度，
        // 放不下时也就不会去压矮列表。
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { size in
            actions.sizeChanged(size)
        }
        // 窗口还没跟上内容尺寸的那一瞬间，内容贴着顶部，被裁掉的是底部而不是标题。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                if let maxHeight = router.cardsMaxHeight {
                    // 屏幕太矮、列表已经压到最矮还放不下时，列表上方的提示和持仓合计放进一个能滚动的区域。
                    ScrollView {
                        VStack(spacing: 10) {
                            TipsCards()
                            HoldingsSummaryView()
                        }
                    }
                    .frame(height: min(maxHeight, router.cardsHeight))
                } else {
                    TipsCards()
                    HoldingsSummaryView()
                }
                WatchlistView()
            } else if router.batch != nil {
                BatchAddView()
            } else {
                SearchResultsView()
            }
            #if !APP_STORE
            UpdateBanner { actions.openSettings(.about) }
            #endif
            PanelFooter(actions: actions)
        }
        .task(id: router.searchText) {
            await router.runSearch(using: store)
        }
        .onPreferenceChange(CardHeightsKey.self) { heights in
            // 几张卡片之间隔着 10。
            let total = heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * 10
            if abs(total - router.cardsHeight) > 0.5 {
                router.cardsHeight = total
            }
        }
    }
}

@MainActor
struct PanelHeader: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore

    /// 标题下面每个市场的状态：“A股交易中”，英文是“CN Open”。
    static func status(_ region: MarketRegion, _ phase: MarketPhase) -> String {
        switch region {
        case .cn: return L("A股%@", phase.displayName)
        case .hk: return L("港股%@", phase.displayName)
        case .us: return L("美股%@", phase.displayName)
        case .global: return L("期货外汇%@", phase.displayName)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Stox")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    // 期货外汇工作日全天都在交易，不占这里的地方。
                    ForEach(store.activeRegions.filter { $0 != .global }, id: \.self) { region in
                        let phase = store.phase(for: region)
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Theme.phaseColor(phase, convention: settings.colorConvention))
                                .frame(width: 6, height: 6)
                            Text(Self.status(region, phase))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .help(region == .hk ? L("港股行情延时约 15 分钟") : "")
                    }
                }
            }
            Spacer(minLength: 4)
            if let error = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(L("刷新失败：%@", error))
            }
            Button {
                settings.panelPinned.toggle()
            } label: {
                Image(systemName: settings.panelPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(IconButtonStyle())
            .help(settings.panelPinned ? L("取消钉住：点别处时自动关闭") : L("钉住：点别处时不关闭，可以拖到任何位置"))
            Button {
                store.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 180 : 0))
                    .animation(.easeInOut(duration: 0.3), value: store.isRefreshing)
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .help(L("立即刷新（⌘R）"))
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
            TextField(L("搜索代码、名称或拼音，回车添加"), text: $router.searchText)
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
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter

    /// 屏幕够高时列表最多这么高；屏幕放不下整个面板时由 PanelRouter.listMaxHeight 再压低。
    static let defaultMaxHeight: CGFloat = 430

    /// 取迷你分时的任务按这个重新开始：面板开关、设置改了、列表里的证券变了（只是顺序变了不算）。
    private struct SparklineTrack: Hashable {
        var active: Bool
        var symbols: Set<Symbol>
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text(L("还没有自选，在上面的搜索框里添加"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(L("添加常用指数")) {
                        store.add(Watchlist.commonIndices)
                    }
                    .controlSize(.small)
                    .help(Watchlist.commonIndices.map(\.name).joined(separator: L("、")))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            } else {
                let filters = WatchlistFilter.available(for: store.items)
                let filter = WatchlistFilter.effective(settings.listFilter, items: store.items)
                let visible = Self.visibleItems(store: store, settings: settings)
                if !filters.isEmpty {
                    WatchlistFilterBar(filters: filters, active: filter, count: visible.count)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
                ScrollViewReader { proxy in
                    List {
                        ForEach(visible) { item in
                            QuoteRow(
                                item: item,
                                quote: store.quotes[item.symbol],
                                expanded: router.expanded == item.symbol,
                                highlighted: router.highlighted == item.symbol
                            )
                                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .id(item.symbol)
                        }
                        // 按涨跌幅排序的时候不能拖动；筛选着的时候只在看得见的几只之间换位置。
                        .onMove(perform: settings.sortMode == .custom ? { source, destination in
                            store.move(visible: visible.map(\.symbol), fromOffsets: source, toOffset: destination)
                        } : nil)
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
                    .onChange(of: router.highlighted) { symbol in
                        // 方向键移动时马上滚到看得见的地方，不等动画。
                        if let symbol { proxy.scrollTo(symbol) }
                    }
                }
                .task(id: SparklineTrack(
                    active: router.isOpen && settings.showSparklines && !settings.compactRows, symbols: Set(visible.map(\.symbol))
                )) {
                    guard router.isOpen, settings.showSparklines, !settings.compactRows else { return }
                    await store.trackSparklines(visible.map(\.symbol))
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
        min(Self.naturalHeight(store: store, settings: settings, expanded: router.expanded), router.listMaxHeight)
    }

    /// 列表里显示的自选：先筛选，再排序。键盘上下选择也按这个顺序。
    static func visibleItems(store: QuoteStore, settings: SettingsStore) -> [WatchItem] {
        let filter = WatchlistFilter.effective(settings.listFilter, items: store.items)
        return settings.sortMode.apply(filter.apply(store.items), quotes: store.quotes)
    }

    /// 列表不受屏幕高度限制时的高度：每行固定高度，展开的那一行加上详情，最多 defaultMaxHeight。
    static func naturalHeight(store: QuoteStore, settings: SettingsStore, expanded: Symbol?) -> CGFloat {
        let visible = visibleItems(store: store, settings: settings)
        let rowHeight = QuoteRow.rowHeight(compact: settings.compactRows)
        var height = CGFloat(visible.count) * rowHeight
        if let expanded, let item = visible.first(where: { $0.symbol == expanded }), store.quotes[expanded] != nil {
            height += QuoteRow.detailHeight(for: item)
        }
        return min(max(height, rowHeight * 2), defaultMaxHeight)
    }
}

/// 列表上方的筛选：全部、各市场、持仓、各个分组，右边是显示了几只。分组多了放不下时可以左右滚动。
@MainActor
struct WatchlistFilterBar: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter
    let filters: [WatchlistFilter]
    let active: WatchlistFilter
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(filters, id: \.self) { filter in
                        chip(filter)
                    }
                }
            }
            .frame(height: 20)
            Text(L("%@ 只", count))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    /// 分组右键可以编辑或解散。
    @ViewBuilder
    private func chip(_ filter: WatchlistFilter) -> some View {
        if case .group(let name) = filter {
            chipButton(filter)
                .contextMenu {
                    Button(L("编辑分组…")) { router.route = .group(name, member: nil) }
                    Button(L("解散“%@”分组", name)) { store.dissolveGroup(name) }
                }
                .help(L("分组“%@”，右键可以编辑或解散", name))
        } else {
            chipButton(filter)
        }
    }

    private func chipButton(_ filter: WatchlistFilter) -> some View {
        let selected = filter == active
        return Button {
            settings.listFilter = filter
        } label: {
            Text(filter.title)
                .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.primary.opacity(selected ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
struct SearchResultsView: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        Group {
            if router.searchResults.isEmpty {
                Text(router.isSearching ? L("搜索中…") : (router.searchError.map { L("搜索失败：%@", $0) } ?? L("没有找到相关证券")))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            } else {
                let highlighted = router.highlighted ?? router.defaultSearchHighlight(excluding: { store.contains($0) })
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(router.searchResults) { result in
                                SearchResultRow(
                                    result: result,
                                    added: store.contains(result.symbol),
                                    highlighted: highlighted == result.symbol,
                                    quote: router.searchQuotes[result.symbol],
                                    missing: router.searchResultMissing(result.symbol)
                                ) {
                                    store.add(result.symbol, name: result.isDirect ? "" : result.name)
                                    router.clearSearch()
                                }
                                .id(result.symbol)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(router.searchResults.count) * SearchResultRow.height + 12, 360))
                    .onChange(of: router.highlighted) { symbol in
                        if let symbol { proxy.scrollTo(symbol) }
                    }
                }
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
                    Text(L("认出 %@ 个代码", batch.symbols.count))
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button(pending.isEmpty ? L("都已处理") : L("全部添加（%@）", pending.count)) {
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
                    Text(L("认不出：") + batch.rejected.joined(separator: L("、")))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let error = router.batchError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Text(L("回车全部添加，会先查一次行情，只添加存在的代码。"))
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
                Label(L("已添加"), systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if router.batchMissing.contains(symbol) {
                Label(L("没有这个代码"), systemImage: "xmark")
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

/// 列表上方的一次性提示：第一次使用时的小提示，更新后的“已更新到 x.y.z”。都可以关掉。
@MainActor
struct TipsCards: View {
    @EnvironmentObject private var settings: SettingsStore
    /// 这个版本更新了什么（从发布说明里取的“更新内容”），取不到时只显示版本号。
    @State private var whatsNewNotes: String?

    var body: some View {
        // App Store 版的更新内容由 App Store 显示，不去 GitHub 取。
        #if !APP_STORE
        if let version = settings.whatsNewVersion {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("已更新到 %@", version))
                            .font(.system(size: 12, weight: .semibold))
                        Text(settings.whatsNewSince.map { L("从 %@ 更新上来，自选和设置都还在", $0) } ?? L("自选和设置都还在"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(L("看看更新了什么")) {
                        if let url = URL(string: "https://github.com/\(UpdateCheck.repository)/releases/tag/v\(version)") {
                            NSWorkspace.shared.open(url)
                        }
                        settings.whatsNewVersion = nil
                    }
                    .controlSize(.small)
                    closeButton { settings.whatsNewVersion = nil }
                }
                if let whatsNewNotes {
                    Text(ReleaseNotes.attributed(whatsNewNotes))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .glassCard()
            .reportsCardHeight()
            .task(id: version) {
                whatsNewNotes = await Self.loadNotes(version, since: settings.whatsNewSince)
            }
        }
        #endif
        if !settings.tipsDismissed {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L("几个小技巧"), systemImage: "lightbulb")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    closeButton { settings.tipsDismissed = true }
                }
                tip(L("右键单击菜单栏图标，在显示行情和只显示图标之间切换"))
                tip(L("%@ 在任何 App 里打开或关闭这个面板", settings.toggleHotkey.display))
                tip(L("右键单击一只可以固定到菜单栏、放进分组，或者填持仓和价格提醒"))
                tip(L("点右边的色块，在涨跌幅、涨跌额和总市值之间切换"))
                tip(L("一次粘贴多个代码，回车全部添加"))
                tip(L("↑ ↓ 选择，回车添加或展开；展开后 ← → 切换分时和 K 线"))
                tip(L("点右上角的图钉，面板就一直显示，可以拖到任何位置"))
            }
            .padding(10)
            .glassCard()
            .reportsCardHeight()
        }
    }

    #if !APP_STORE
    /// 发布说明里“更新内容”的前几条。
    /// 隔了几个版本才更新时，每个版本一行（它的第一条更新内容），最多 5 个版本；只差一个版本时是这个版本的前几条。
    private static func loadNotes(_ version: String, since: String?) async -> String? {
        let lines: [String]
        do {
            let all = try await UpdateCheck.releases(count: 30, currentVersion: AppInfo.version)
            let range = UpdateCheck.releases(all, after: since ?? version, upTo: version)
            if range.count > 1 {
                lines = ReleaseNotesText.firstLines(range, limit: 5)
            } else {
                // 只差一个版本，或者不知道是从哪个版本更新的：这个版本自己的前几条。
                let release: ReleaseInfo
                if let found = all.first(where: { $0.version == version }) {
                    release = found
                } else {
                    release = try await UpdateCheck.release(version: version, currentVersion: AppInfo.version)
                }
                lines = Array(release.highlights
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .prefix(4))
            }
        } catch {
            Log.info("取 \(version) 的更新内容失败：\(error.localizedDescription)")
            print("STOX_DIAG whatsnew=failed \(error)")
            fflush(stdout)
            return nil
        }
        print("STOX_DIAG whatsnew=\(lines.count) lines since=\(since ?? "none")")
        fflush(stdout)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    #endif

    private func tip(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L("不再显示"))
    }
}

/// 有持仓时显示在列表上方：按币种分别合计的今日盈亏、持仓盈亏和市值，排成一张小表。
@MainActor
struct HoldingsSummaryView: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter

    var body: some View {
        // 跟着列表上方的筛选走：只看某个分组、某个市场时只算这些。
        let filter = WatchlistFilter.effective(settings.listFilter, items: store.items)
        let summaries = Self.summaries(store: store, settings: settings)
        if !summaries.isEmpty {
            // 只有一种货币、也没有筛选时不需要第一列；筛选着的时候第一列的表头写着筛的是什么。
            let filtered = filter != .all
            let showsCurrency = summaries.count > 1 || filtered
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        if filtered {
                            Text(filter.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if showsCurrency {
                            Color.clear
                                .gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                        header(L("今日盈亏"))
                        header(L("持仓盈亏"))
                        HStack(spacing: 4) {
                            header(showsCurrency ? L("市值") : L("持仓市值"))
                            hideAmountsButton
                        }
                        .gridColumnAlignment(.trailing)
                    }
                    ForEach(summaries, id: \.region) { summary in
                        row(summary.region.currencyName, summary, showsCurrency: showsCurrency)
                    }
                    // 几种货币都有时，按现在的汇率折成人民币再合计一行。
                    if let total = Portfolio.combined(summaries, rates: store.rates) {
                        Divider()
                            .gridCellUnsizedAxes(.horizontal)
                        row(L("合计"), total, showsCurrency: true, help: combinedHelp)
                    }
                }
                // 今年卖出和分红的已实现盈亏：编辑页里记了卖出、分红才有。
                let realized = Self.realized(store: store, settings: settings)
                if !realized.isEmpty {
                    realizedRow(realized)
                }
                // 两只以上持仓时可以展开看每只占多少。
                if summaries.reduce(0, { $0 + $1.count }) > 1 {
                    allocation
                }
                // 盈亏记录是全部持仓的，筛选着的时候不显示。
                if !filtered, !store.profitHistory.records.isEmpty {
                    history
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCard()
            .reportsCardHeight()
            .help((filtered ? L("只算列表上方选中的“%@”。", filter.title) : "")
                + L("按现价计算。人民币、港币、美元分别合计；合计一行按现在的汇率折成人民币"))
        }
    }

    /// 持仓分布：点一下展开或收起，展开后每只一行，横条是占总市值的比例。
    @ViewBuilder
    private var allocation: some View {
        disclosure(L("持仓分布"), expanded: $settings.showAllocation, help: L("看每只持仓占总市值多少"))
        if settings.showAllocation {
            let entries = Self.allocation(store: store, settings: settings)
            let view = AllocationView(entries)
            if entries.isEmpty {
                Text(L("几种货币都有时，要等取到汇率才能放在一起比。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach(view.shown, id: \.symbol) { entry in
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .frame(width: 84, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.55))
                                .frame(width: max(2, proxy.size.width * CGFloat(entry.share / 100)))
                        }
                    }
                    .frame(height: 5)
                    Text(QuoteFormatter.fixed(entry.share, decimals: 1) + "%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
                .frame(height: 15)
                .help(L("%@：市值 %@", entry.name, amount(QuoteFormatter.money(entry.marketValue)))
                    + (entry.profitPercent.map { L("，持仓盈亏 %@", QuoteFormatter.percent($0)) } ?? ""))
            }
            if view.restCount > 0 {
                HStack(spacing: 6) {
                    Text(L("其余 %@ 只", view.restCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(QuoteFormatter.fixed(view.restShare, decimals: 1) + "%")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .frame(height: 15)
            }
        }
    }

    /// 盈亏记录：点一下展开或收起，展开后每种货币一行，柱子是最近 20 个交易日的今日盈亏，右边是本周、本月合计。
    @ViewBuilder
    private var history: some View {
        disclosure(L("盈亏记录"), expanded: $settings.showProfitHistory, help: L("看最近每个交易日赚了多少"))
        if settings.showProfitHistory {
            ForEach(store.profitHistory.regions, id: \.self) { region in
                historyRow(region)
            }
            HStack(spacing: 6) {
                Text(L("每个交易日收盘后记在这台 Mac 上，一整天没开机的日子没有。"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Button(L("日历")) { router.route = .calendar }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .help(L("按月看每天赚了多少"))
            }
        }
    }

    private func historyRow(_ region: MarketRegion) -> some View {
        let records = store.profitHistory.recent(region, limit: 20)
        let today = ProfitHistory.day(of: Date(), region: region)
        let week = store.profitHistory.dayProfitTotal(region, since: ProfitHistory.weekStart(of: today, region: region))
        let month = store.profitHistory.dayProfitTotal(region, since: ProfitHistory.monthStart(of: today))
        return HStack(spacing: 6) {
            Text(region.currencyName)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            ProfitBars(values: records.map(\.dayProfit), convention: settings.colorConvention)
                .frame(height: 18)
                .help(records.last.map { L("最近一天 %@ %@", $0.day, amount(QuoteFormatter.signedMoney($0.dayProfit))) } ?? "")
            VStack(alignment: .trailing, spacing: 0) {
                Text(L("本周 ") + amount(QuoteFormatter.signedMoney(week)))
                    .foregroundStyle(Theme.priceColor(for: PriceDirection(week), convention: settings.colorConvention))
                Text(L("本月 ") + amount(QuoteFormatter.signedMoney(month)))
                    .foregroundStyle(Theme.priceColor(for: PriceDirection(month), convention: settings.colorConvention))
            }
            .font(.system(size: 10).monospacedDigit())
            .lineLimit(1)
            .frame(width: 96, alignment: .trailing)
        }
    }

    /// 可以点开的小标题：持仓分布、盈亏记录。
    private func disclosure(_ title: String, expanded: Binding<Bool>, help: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded.wrappedValue ? L("收起%@", title) : help)
    }

    /// 列表上方筛选出来的那些持仓，各占总市值多少。
    static func allocation(store: QuoteStore, settings: SettingsStore) -> [AllocationEntry] {
        let filter = WatchlistFilter.effective(settings.listFilter, items: store.items)
        return Portfolio.allocation(items: filter.apply(store.items), quotes: store.quotes, rates: store.rates)
    }

    /// 列表上方筛选出来的那些，今年卖出的已实现盈亏，按币种。
    static func realized(store: QuoteStore, settings: SettingsStore) -> [(region: MarketRegion, profit: Double)] {
        let filter = WatchlistFilter.effective(settings.listFilter, items: store.items)
        return Portfolio.realizedProfit(items: filter.apply(store.items), since: Portfolio.yearStart(now: Date()))
    }

    /// 今年已实现：人民币 +1234.00 · 美元 -56.00。只有一种货币时不写币种。
    private func realizedRow(_ realized: [(region: MarketRegion, profit: Double)]) -> some View {
        HStack(spacing: 8) {
            Text(L("今年已实现"))
                .foregroundStyle(.secondary)
            ForEach(realized.indices, id: \.self) { index in
                let entry = realized[index]
                Text((realized.count > 1 ? entry.region.currencyName + " " : "") + amount(QuoteFormatter.signedMoney(entry.profit)))
                    .foregroundStyle(Theme.priceColor(for: PriceDirection(entry.profit), convention: settings.colorConvention))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .help(L("今年卖出的部分按当时的成本价算出的盈亏，加上记下的现金分红，来自编辑页里“记一笔”记下的卖出和分红"))
    }

    /// 列表上方筛选出来的那些持仓，按币种合计。
    static func summaries(store: QuoteStore, settings: SettingsStore) -> [PortfolioSummary] {
        let filter = WatchlistFilter.effective(settings.listFilter, items: store.items)
        return Portfolio.summaries(items: filter.apply(store.items), quotes: store.quotes)
    }

    private func row(_ title: String, _ summary: PortfolioSummary, showsCurrency: Bool, help: String = "") -> some View {
        GridRow(alignment: .firstTextBaseline) {
            if showsCurrency {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(help)
            }
            profit(summary.dayProfit, percent: summary.dayProfitPercent)
            profit(summary.totalProfit, percent: summary.totalProfitPercent)
            Text(amount(QuoteFormatter.money(summary.marketValue)))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var combinedHelp: String {
        guard let rates = store.rates else { return "" }
        return L("按现在的汇率折成人民币：1 港币 = %@ 元，", QuoteFormatter.fixed(rates.hkdCNY, decimals: 4))
            + L("1 美元 = %@ 元。成本也按现在的汇率折算", QuoteFormatter.fixed(rates.usdCNY, decimals: 4))
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    /// 隐藏金额时是 ****，比例照常显示。
    private func amount(_ text: @autoclosure () -> String) -> String {
        settings.hideAmounts ? QuoteFormatter.hiddenAmount : text()
    }

    /// 市值表头旁边的小眼睛：点一下隐藏或显示面板、菜单栏和通知里的金额，给别人看屏幕时用。
    private var hideAmountsButton: some View {
        Button {
            settings.hideAmounts.toggle()
        } label: {
            Image(systemName: settings.hideAmounts ? "eye.slash" : "eye")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(settings.hideAmounts ? L("显示金额") : L("隐藏金额：市值、盈亏金额和持有数量换成 ****，比例照常显示，给别人看屏幕时用"))
        .accessibilityLabel(settings.hideAmounts ? L("显示金额") : L("隐藏金额"))
    }

    /// 金额在上、比例在下，窄一点也放得下。
    private func profit(_ value: Double, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(amount(QuoteFormatter.signedMoney(value)))
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
    /// 回车会添加这一条（默认第一条，也可以用上下方向键选）。
    var highlighted = false
    /// 这条结果的行情，查到了就在右边显示现价和涨跌幅。
    var quote: Quote?
    /// 查过行情但是查不到。
    var missing = false
    let add: () -> Void

    @EnvironmentObject private var settings: SettingsStore

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
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(missing ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
                Spacer()
                if let quote, quote.price > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(QuoteFormatter.price(quote.price, decimals: quote.priceDecimals))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        Text(QuoteFormatter.percent(quote.changePercent))
                            .font(.system(size: 10).monospacedDigit())
                    }
                    .foregroundStyle(Theme.priceColor(for: quote.direction, convention: settings.colorConvention))
                    .lineLimit(1)
                }
                if added {
                    Label(L("已添加"), systemImage: "checkmark")
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
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted ? 0.14 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .disabled(added)
    }

    private var subtitle: String {
        if missing { return result.isDirect ? L("查不到这个代码的行情") : L("%@ · 查不到行情", result.symbol.displayCode) }
        return result.isDirect ? L("按代码添加") : "\(result.symbol.displayCode) · \(result.typeLabel)"
    }
}

@MainActor
struct PanelFooter: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter
    let actions: PanelActions
    /// 刚复制了东西：底部的状态文字换成提示，几秒后恢复。
    @State private var copiedMessage: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(store.usingBackup ? L("腾讯的行情接口暂时取不到，正在用新浪的行情；分时和 K 线要等腾讯恢复") : "")
            Spacer(minLength: 4)
            Menu {
                Text(L("排序"))
                Picker(L("排序"), selection: $settings.sortMode) {
                    ForEach(WatchlistSort.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Text(L("右边的色块显示"))
                Picker(L("右边的色块显示"), selection: $settings.changeDisplay) {
                    ForEach(ChangeDisplay.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button(L("复制全部代码")) { copyCodes() }
                    .disabled(store.items.isEmpty)
                Button(L("复制持仓表格")) { copyHoldings() }
                    .disabled(!store.items.contains { $0.holding != nil })
                Button(L("复制买卖记录")) { copyTrades() }
                    .disabled(!store.items.contains { !$0.trades.isEmpty })
                Button(L("复制盈亏记录")) { copyProfitHistory() }
                    .disabled(store.profitHistory.records.isEmpty)
                Divider()
                Button(L("新建分组…")) { router.route = .group(nil, member: nil) }
                    .disabled(store.items.isEmpty)
                Button(L("最近的提醒…")) { router.route = .alerts }
                    .disabled(store.alertLog.entries.isEmpty)
                Button(L("盈亏日历…")) { router.route = .calendar }
                    .disabled(store.profitHistory.records.isEmpty)
                Button(L("A 股涨跌榜…")) { router.route = .rank }
            } label: {
                Image(systemName: settings.sortMode == .custom ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(IconButtonStyle())
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.primary.opacity(0.05)))
            .help(L("排序：%@；色块显示%@", settings.sortMode.title, settings.changeDisplay.title))
            Button {
                actions.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            .help(L("设置（⌘,）"))
            Button {
                actions.quit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
            .help(L("退出 Stox（⌘Q）"))
        }
        .padding(.horizontal, 4)
    }

    /// 复制出去的代码粘贴到另一台 Mac（或者重装后）的搜索框里，回车就能全部加回来。
    private func copyCodes() {
        copy(Watchlist.exportText(store.items), message: L("已复制 %@ 个代码，粘贴到搜索框就能全部加回来", store.items.count))
    }

    /// 持仓表格用制表符分隔，粘贴到 Numbers、Excel 就是一张表。
    private func copyHoldings() {
        let text = Portfolio.tableText(items: store.items, quotes: store.quotes)
        guard !text.isEmpty else { return }
        let rows = text.components(separatedBy: "\n").count - 1
        copy(text, message: L("已复制 %@ 行持仓，可以直接粘贴到表格里", rows))
    }

    private func copyTrades() {
        let text = Portfolio.tradesText(items: store.items)
        guard !text.isEmpty else { return }
        let rows = text.components(separatedBy: "\n").count - 1
        copy(text, message: L("已复制 %@ 笔买卖，可以直接粘贴到表格里", rows))
    }

    private func copyProfitHistory() {
        let text = store.profitHistory.tableText
        guard !text.isEmpty else { return }
        copy(text, message: L("已复制 %@ 天的盈亏记录，可以直接粘贴到表格里", store.profitHistory.records.count))
    }

    private func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if copiedMessage == message { copiedMessage = nil }
        }
    }

    private var statusText: String {
        if let copiedMessage {
            return copiedMessage
        }
        if store.items.isEmpty { return L("还没有自选") }
        guard let updated = store.lastUpdated else { return L("正在获取行情…") }
        let cadence = store.effectiveInterval > settings.refreshInterval
            ? L("休市中每分钟刷新")
            : L("每 %@ 秒刷新", Int(settings.refreshInterval))
        // 用新浪行情时地方不够，省掉排序方式，标出行情来源。
        if store.usingBackup {
            return L("%@ 更新 · 新浪行情 · %@", QuoteFormatter.time(updated), cadence)
        }
        let filter = WatchlistFilter.effective(settings.listFilter, items: store.items)
        let order: String
        if filter != .all {
            order = L("只看%@", filter.title)
        } else {
            order = settings.sortMode == .custom ? L("拖动排序") : settings.sortMode.title
        }
        return L("%@ 更新 · %@ · %@", QuoteFormatter.time(updated), cadence, order)
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
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(tint)
            .frame(width: 15, height: 13)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.14)))
    }
}

/// 盈亏记录里的小柱子：每个交易日一根，赚了往上、亏了往下，按最大的一根缩放。
struct ProfitBars: View {
    let values: [Double]
    let convention: ColorConvention

    var body: some View {
        Canvas { context, size in
            let biggest = values.map(abs).max() ?? 0
            guard !values.isEmpty, biggest > 0, size.width > 0 else { return }
            let middle = size.height / 2
            let slot = size.width / CGFloat(max(values.count, 20))
            let width = max(1, min(slot - 1, 6))
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: middle))
            baseline.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            for (index, value) in values.enumerated() {
                let height = max(CGFloat(abs(value) / biggest) * (middle - 1), 0.5)
                let x = CGFloat(index) * slot + (slot - width) / 2
                let rect = CGRect(x: x, y: value >= 0 ? middle - height : middle, width: width, height: height)
                context.fill(Path(rect), with: .color(Theme.priceColor(for: PriceDirection(value), convention: convention).opacity(0.8)))
            }
        }
        .accessibilityHidden(true)
    }
}
