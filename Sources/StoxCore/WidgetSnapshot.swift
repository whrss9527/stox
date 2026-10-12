import Foundation

/// 仅给小组件的行情摘要，不包含持仓、交易、备注或提醒设置。
public struct WidgetQuote: Codable, Equatable, Sendable, Identifiable {
    public var id: String { symbol.rawValue }
    public let symbol: Symbol
    public let name: String
    public let englishName: String
    public let price: Double?
    public let changePercent: Double?
    public let priceDecimals: Int
    public let quoteTime: Date?

    public init(item: WatchItem, quote: Quote?) {
        symbol = item.symbol
        name = item.displayName(with: quote, english: false)
        englishName = item.displayName(with: quote, english: true)
        price = quote.flatMap { $0.price.isFinite && $0.price > 0 ? $0.price : nil }
        changePercent = quote.flatMap { $0.changePercent.isFinite ? $0.changePercent : nil }
        priceDecimals = min(max(quote?.priceDecimals ?? 2, 0), 6)
        quoteTime = quote?.timestamp
    }

    public func isStale(at now: Date, snapshotDate: Date) -> Bool {
        guard let quoteTime, price != nil else { return true }
        let age = now.timeIntervalSince(snapshotDate)
        guard age >= -60, age <= 15 * 60 else { return true }
        let phase = MarketClock.phase(for: symbol.market.region, at: now)
        return phase.isLive && (now.timeIntervalSince(quoteTime) > 15 * 60 || quoteTime > now.addingTimeInterval(60))
    }

    public var link: URL {
        var components = URLComponents()
        components.scheme = "stox"
        components.host = "widget"
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol.rawValue)]
        return components.url!
    }
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let version = 1
    public let schemaVersion: Int
    public let capturedAt: Date
    public let quotes: [WidgetQuote]

    public init(items: [WatchItem], quotes: [Symbol: Quote], now: Date) {
        schemaVersion = Self.version
        capturedAt = now
        var seen = Set<Symbol>()
        self.quotes = items.filter { seen.insert($0.symbol).inserted }.prefix(500).map {
            WidgetQuote(item: $0, quote: quotes[$0.symbol])
        }
    }

    /// 配置里的顺序优先；已删除的证券不被其他证券悄悄替代。
    public func selected(ids: [String], limit: Int) -> [WidgetQuote] {
        guard limit > 0 else { return [] }
        if ids.isEmpty { return Array(quotes.prefix(limit)) }
        var seen = Set<String>()
        return Array(ids.filter { seen.insert($0).inserted }.compactMap { id in quotes.first { $0.id == id } }.prefix(limit))
    }

    public static func decode(_ data: Data) -> WidgetSnapshot? {
        guard data.count <= 1_048_576,
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.schemaVersion == version, snapshot.quotes.count <= 500,
              Set(snapshot.quotes.map(\.id)).count == snapshot.quotes.count,
              snapshot.quotes.allSatisfy({
                  (0...6).contains($0.priceDecimals) && ($0.price.map { $0.isFinite && $0 > 0 } ?? true)
                    && ($0.changePercent.map(\.isFinite) ?? true)
              }) else { return nil }
        return snapshot
    }
}

public enum WidgetSnapshotFile {
    public static let name = "quotes-v1.json"

    public static func read(in directory: URL) -> WidgetSnapshot? {
        let file = directory.appendingPathComponent(name)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576, let data = try? Data(contentsOf: file) else { return nil }
        return WidgetSnapshot.decode(data)
    }

    public static func write(_ snapshot: WidgetSnapshot, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
