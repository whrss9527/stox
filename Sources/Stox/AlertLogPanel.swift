import SwiftUI
import StoxCore

/// 最近的提醒：价格提醒、涨跌停、异动和收盘小结，最新的在前面。点一条回到列表并展开那一只。
@MainActor
struct AlertLogPanel: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter

    /// 列表最多这么高，多了在里面滚动。
    private static let listMaxHeight: CGFloat = 380

    var body: some View {
        VStack(spacing: 10) {
            header
            if store.alertLog.entries.isEmpty {
                Text(L("还没有发过提醒"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                    .glassCard()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.alertLog.entries) { entry in
                            row(entry)
                            if entry.id != store.alertLog.entries.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .frame(height: min(CGFloat(store.alertLog.entries.count) * 52 + 8, Self.listMaxHeight, router.pageMaxHeight))
                .glassCard()
            }
            HStack {
                Button(L("清空")) { store.clearAlertLog() }
                    .disabled(store.alertLog.entries.isEmpty)
                Spacer()
                Button(L("返回")) { router.route = .list }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            .padding(.horizontal, 2)
        }
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
                Text(L("最近的提醒"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L("最多留 %@ 条，只在这台 Mac 上", AlertLog.limit))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .glassCard(prominent: true)
    }

    private func row(_ entry: AlertLogEntry) -> some View {
        Button {
            open(entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(timeText(entry.time))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(entry.body)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.symbol.map { !store.contains($0) } ?? false)
        .help(entry.symbol == nil ? L("回到列表") : L("回到列表并展开这一只"))
    }

    /// 今天的只写时刻，别的日子写月日和时刻。
    private func timeText(_ time: Date) -> String {
        let calendar = Calendar.current
        let clock = String(QuoteFormatter.time(time).prefix(5))
        if calendar.isDateInToday(time) { return clock }
        let c = calendar.dateComponents([.month, .day], from: time)
        return String(format: "%02d-%02d ", c.month ?? 0, c.day ?? 0) + clock
    }

    /// 回到列表；是某一只的提醒就展开它，筛选着看不到时先回到“全部”。
    private func open(_ entry: AlertLogEntry) {
        router.route = .list
        guard let symbol = entry.symbol, store.contains(symbol) else { return }
        if !WatchlistView.visibleItems(store: store, settings: settings).contains(where: { $0.symbol == symbol }) {
            settings.listFilter = .all
        }
        router.expanded = symbol
    }
}
