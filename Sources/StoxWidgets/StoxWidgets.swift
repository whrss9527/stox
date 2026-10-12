import AppIntents
import StoxCore
import SwiftUI
import WidgetKit

private enum WidgetData {
    static func snapshot() -> WidgetSnapshot? {
        AppLanguage.bundle = .main
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.io.github.whrss9527.stox.widgets"
        ) else { return nil }
        return WidgetSnapshotFile.read(in: directory)
    }
}

struct WidgetStock: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "证券") // l10n-ignore
    static var defaultQuery = WidgetStockQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)", subtitle: "\(id)") }
}

struct WidgetStockQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetStock] {
        let rows = WidgetData.snapshot()?.selected(ids: identifiers, limit: 6) ?? []
        return rows.map { WidgetStock(id: $0.id, name: AppLanguage.isEnglish ? $0.englishName : $0.name) }
    }

    func suggestedEntities() async throws -> [WidgetStock] {
        (WidgetData.snapshot()?.quotes ?? []).map {
            WidgetStock(id: $0.id, name: AppLanguage.isEnglish ? $0.englishName : $0.name)
        }
    }
}

struct QuotesConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "自选行情" // l10n-ignore
    @Parameter(title: "证券") var stocks: [WidgetStock]? // l10n-ignore
}

struct QuotesEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let ids: [String]
}

struct QuotesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotesEntry {
        let symbol = Symbol("sh000001")!
        let now = Date()
        let quote = Quote(symbol: symbol, name: "Stox", price: 3500, previousClose: 3470, timestamp: now)
        return QuotesEntry(date: now, snapshot: WidgetSnapshot(items: [WatchItem(symbol: symbol, name: "Stox")], quotes: [symbol: quote], now: now), ids: [])
    }

    func snapshot(for configuration: QuotesConfiguration, in context: Context) async -> QuotesEntry {
        QuotesEntry(date: Date(), snapshot: WidgetData.snapshot(), ids: configuration.stocks?.map(\.id) ?? [])
    }

    func timeline(for configuration: QuotesConfiguration, in context: Context) async -> Timeline<QuotesEntry> {
        let entry = await snapshot(for: configuration, in: context)
        let later = entry.date.addingTimeInterval(15 * 60 + 1)
        // 无新快照时，预先安排一条标注旧数据的 entry；不依靠频繁启动扩展计时。
        let expired = QuotesEntry(date: later, snapshot: entry.snapshot, ids: entry.ids)
        return Timeline(entries: [entry, expired], policy: .after(later))
    }
}

struct QuotesWidgetView: View {
    let entry: QuotesEntry
    @Environment(\.widgetFamily) private var family

    private var rows: [WidgetQuote] {
        entry.snapshot?.selected(ids: entry.ids, limit: family == .systemSmall ? 1 : 6) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Stox", systemImage: "chart.line.uptrend.xyaxis").font(.caption.bold())
                Spacer()
                if rows.contains(where: { $0.isStale(at: entry.date, snapshotDate: entry.snapshot!.capturedAt) }) {
                    Text(L("缓存行情")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Spacer()
                Text(L("打开 Stox 获取自选行情")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if family == .systemSmall, let row = rows.first {
                single(row)
            } else {
                ForEach(rows) { row in
                    Link(destination: row.link) {
                        HStack {
                            Text(AppLanguage.isEnglish ? row.englishName : row.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(MarketClock.effectivePhase(for: row.symbol.market.region, at: entry.date, latestQuoteTime: row.quoteTime).displayName)
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                            Text(row.price.map { QuoteFormatter.price($0, decimals: row.priceDecimals) } ?? "—")
                            Text(row.changePercent.map(QuoteFormatter.percent) ?? "—").frame(width: 64, alignment: .trailing)
                        }.font(.caption).monospacedDigit()
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if let earliest = rows.compactMap(\.quoteTime).min() { timestamp(earliest) }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(rows.first?.link ?? URL(string: "stox://widget")!)
    }

    private func single(_ row: WidgetQuote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLanguage.isEnglish ? row.englishName : row.name).font(.headline).lineLimit(1)
            Text(row.symbol.displayCode).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(row.price.map { QuoteFormatter.price($0, decimals: row.priceDecimals) } ?? "—").font(.title2.bold()).monospacedDigit()
            HStack {
                Text(row.changePercent.map(QuoteFormatter.percent) ?? "—").monospacedDigit()
                Spacer(minLength: 0)
                Text(MarketClock.effectivePhase(for: row.symbol.market.region, at: entry.date, latestQuoteTime: row.quoteTime).displayName)
            }.font(.caption)
            if let date = row.quoteTime { timestamp(date) }
        }
    }

    private func timestamp(_ date: Date) -> some View {
        HStack(spacing: 3) {
            Text(L("行情时间"))
            Text(date, style: .date)
            Text(date, style: .time)
        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
    }
}

@main
struct StoxWidgets: Widget {
    let kind = "StoxQuotes"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: QuotesConfiguration.self, provider: QuotesProvider()) { entry in
            QuotesWidgetView(entry: entry)
        }
        .configurationDisplayName(L("自选行情"))
        .description(L("查看单只证券或自选列表，点击打开 Stox。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
