import SwiftUI
import StoxCore

/// A 股涨跌榜：涨幅榜、跌幅榜、成交额各列前 20 只，行业榜列出全部行业和各自领涨的那只；开着的时候每 30 秒
/// 刷新一次。点一只加到自选（行业榜上加的是领涨股），已经在自选里的点一下回到列表并展开它。
@MainActor
struct RankPanel: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter

    /// 每个榜列多少只。
    static let shown = 20
    /// 向接口要多少只：不看新股时筛掉几只以后还够。
    static let fetched = 40
    private static let rowHeight: CGFloat = 38
    /// 列表最多这么高，多了在里面滚动。
    private static let listMaxHeight: CGFloat = 380
    private static let refreshInterval: UInt64 = 30

    var body: some View {
        VStack(spacing: 10) {
            header
            Picker(L("榜单"), selection: $settings.rankKind) {
                ForEach(RankKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            content
            HStack {
                if settings.rankKind != .industries {
                    Toggle(L("不看新股"), isOn: $settings.rankHidesNewListings)
                        .toggleStyle(.checkbox)
                        .help(L("新股上市首日（名字前面有 N）和注册制新股上市后前 5 天（有 C）没有涨跌幅限制，常常挤满涨幅榜"))
                }
                Spacer()
                Button(L("返回")) { router.route = .list }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            .padding(.horizontal, 2)
        }
        .task(id: settings.rankKind) {
            while !Task.isCancelled {
                await store.loadRank(settings.rankKind, count: Self.fetched)
                try? await Task.sleep(nanoseconds: Self.refreshInterval * 1_000_000_000)
            }
        }
    }

    /// 这个榜上要列出来的：按设置筛掉新股，只留前 20 只。
    static func entries(store: QuoteStore, settings: SettingsStore) -> [RankEntry] {
        let all = store.rank[settings.rankKind] ?? []
        return Array(all.filter { !settings.rankHidesNewListings || !$0.isNewListing }.prefix(shown))
    }

    /// 诊断信息里写的条数：行业榜是行业数。
    static func count(store: QuoteStore, settings: SettingsStore) -> Int {
        settings.rankKind == .industries ? store.industries?.count ?? 0 : entries(store: store, settings: settings).count
    }

    /// 这个榜取到过没有（取到的可能是空的）。
    private var loaded: Bool {
        settings.rankKind == .industries ? store.industries != nil : store.rank[settings.rankKind] != nil
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
                Text(L("A 股涨跌榜"))
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .glassCard(prominent: true)
    }

    private var subtitle: String {
        var text = settings.rankKind == .industries ? L("申万一级行业") : L("沪深京全部 A 股")
        if let updated = store.rankUpdated[settings.rankKind] {
            text += " · " + L("%@ 更新", String(QuoteFormatter.time(updated).prefix(5)))
        }
        return text
    }

    @ViewBuilder
    private var content: some View {
        let count = Self.count(store: store, settings: settings)
        if count == 0 {
            Text(!loaded ? (store.rankError.map { L("取不到榜单：%@", $0) } ?? L("正在加载…")) : L("榜上暂时没有"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .glassCard()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if settings.rankKind == .industries {
                        let industries = store.industries ?? []
                        ForEach(Array(industries.enumerated()), id: \.element.id) { index, industry in
                            industryRow(index, industry)
                            if index < industries.count - 1 {
                                Divider()
                            }
                        }
                    } else {
                        let entries = Self.entries(store: store, settings: settings)
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(index, entry)
                            if index < entries.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            // 上面还有一排榜单切换，比编辑页的滚动区再矮一些。
            .frame(height: min(CGFloat(count) * Self.rowHeight + 4, Self.listMaxHeight, router.pageMaxHeight - 34))
            .glassCard()
        }
    }

    /// 行业榜的一行：行业名和涨跌幅，下面写领涨的那只。点一下加的是领涨股。
    private func industryRow(_ index: Int, _ industry: IndustryEntry) -> some View {
        let leader = industry.leader
        let added = leader.map { store.contains($0.symbol) } ?? false
        return Button {
            guard let leader else { return }
            if added {
                reveal(leader.symbol)
            } else {
                store.add(leader.symbol, name: leader.name)
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(industry.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if let leader {
                        Text(L("领涨 %@ %@", leader.name, QuoteFormatter.percent(leader.changePercent)))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                pill(industry.changePercent, direction: industry.direction)
                Image(systemName: leader == nil ? "minus" : (added ? "checkmark" : "plus"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(added || leader == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 14)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(leader == nil)
        .help(leader.map { added ? L("%@已在自选里，点一下回到列表并展开", $0.name) : L("把领涨的%@加到自选", $0.name) } ?? "")
        .accessibilityLabel("\(index + 1) \(industry.name) \(QuoteFormatter.percent(industry.changePercent))")
    }

    /// 涨跌幅色块。
    private func pill(_ percent: Double, direction: PriceDirection) -> some View {
        Text(QuoteFormatter.percent(percent))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.pillForeground(convention: settings.colorConvention))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 66, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.pillBackground(for: direction, convention: settings.colorConvention)))
    }

    private func row(_ index: Int, _ entry: RankEntry) -> some View {
        let added = store.contains(entry.symbol)
        return Button {
            if added {
                reveal(entry.symbol)
            } else {
                store.add(entry.symbol, name: entry.name)
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(detail(entry))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(QuoteFormatter.price(entry.price, decimals: 2))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.priceColor(for: entry.direction, convention: settings.colorConvention))
                pill(entry.changePercent, direction: entry.direction)
                Image(systemName: added ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(added ? Color.secondary : Color.accentColor)
                    .frame(width: 14)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(added ? L("已在自选里，点一下回到列表并展开") : L("加到自选"))
        .accessibilityLabel("\(index + 1) \(entry.name) \(QuoteFormatter.percent(entry.changePercent))")
    }

    /// 代码，成交额榜上再写成交额，别的榜写换手率。
    private func detail(_ entry: RankEntry) -> String {
        var text = entry.symbol.displayCode
        if settings.rankKind == .turnover {
            text += L(" · 成交 ") + QuoteFormatter.largeNumber(entry.amount)
        } else if let rate = entry.turnoverRate {
            text += L(" · 换手 ") + QuoteFormatter.fixed(rate, decimals: 2) + "%"
        }
        return text
    }

    /// 回到列表并展开这一只；筛选着看不到时先回到“全部”。
    private func reveal(_ symbol: Symbol) {
        router.route = .list
        if !WatchlistView.visibleItems(store: store, settings: settings).contains(where: { $0.symbol == symbol }) {
            settings.listFilter = .all
        }
        router.expanded = symbol
    }
}
