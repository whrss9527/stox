import XCTest
@testable import StoxCore

final class WidgetSnapshotTests: XCTestCase {
    private let symbol = Symbol("sh600519")!
    private let now = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10))!

    private func snapshot(timestamp: Date? = nil) -> WidgetSnapshot {
        let item = WatchItem(symbol: symbol, name: "Test", holding: Holding(shares: 100, cost: 99), note: "PRIVATE")
        let quote = Quote(symbol: symbol, name: "Test", price: 100, previousClose: 99, timestamp: timestamp ?? now)
        return WidgetSnapshot(items: [item], quotes: [symbol: quote], now: now)
    }

    func testRoundTripExcludesPrivateDataAndWritesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = snapshot()
        try WidgetSnapshotFile.write(value, in: directory)
        XCTAssertEqual(WidgetSnapshotFile.read(in: directory), value)
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for privateKey in ["holding", "trades", "note", "alert", "PRIVATE"] {
            XCTAssertFalse(text.contains(privateKey))
        }
        try WidgetSnapshotFile.write(WidgetSnapshot(items: [], quotes: [:], now: now), in: directory)
        XCTAssertEqual(WidgetSnapshotFile.read(in: directory)?.quotes, [])
    }

    func testConfigurationOrderDeduplicationAndDeletedSymbols() {
        let other = Symbol("usAAPL")!
        let value = WidgetSnapshot(items: [WatchItem(symbol: symbol), WatchItem(symbol: other), WatchItem(symbol: symbol)], quotes: [:], now: now)
        XCTAssertEqual(value.quotes.count, 2)
        XCTAssertEqual(value.selected(ids: [other.rawValue, "deleted", other.rawValue, symbol.rawValue], limit: 2).map(\.symbol), [other, symbol])
        XCTAssertTrue(value.selected(ids: ["deleted"], limit: 6).isEmpty)
        XCTAssertEqual(value.selected(ids: [], limit: 1).map(\.symbol), [symbol])
        XCTAssertTrue(value.selected(ids: [], limit: -1).isEmpty)
    }

    func testOldQuotesAndOldSnapshotsAreMarkedStale() {
        let value = snapshot()
        XCTAssertFalse(value.quotes[0].isStale(at: now, snapshotDate: now))
        XCTAssertTrue(value.quotes[0].isStale(at: now.addingTimeInterval(901), snapshotDate: now))
        XCTAssertTrue(snapshot(timestamp: now.addingTimeInterval(-901)).quotes[0].isStale(at: now, snapshotDate: now))
        XCTAssertTrue(value.quotes[0].isStale(at: now, snapshotDate: now.addingTimeInterval(120)))
        let missing = WidgetSnapshot(items: [WatchItem(symbol: symbol)], quotes: [:], now: now)
        XCTAssertTrue(missing.quotes[0].isStale(at: now, snapshotDate: now))
    }

    func testRecentSnapshotMayShowLastClosingQuoteDuringClosedMarket() {
        let close = now.addingTimeInterval(6 * 3600)
        XCTAssertFalse(snapshot().quotes[0].isStale(at: close, snapshotDate: close))
    }

    func testCorruptOversizedUnknownVersionAndDuplicateSnapshotAreRejected() throws {
        XCTAssertNil(WidgetSnapshot.decode(Data("broken".utf8)))
        XCTAssertNil(WidgetSnapshot.decode(Data(repeating: 0, count: 1_048_577)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        json["schemaVersion"] = 2
        XCTAssertNil(WidgetSnapshot.decode(try JSONSerialization.data(withJSONObject: json)))
        json["schemaVersion"] = 1
        let rows = try XCTUnwrap(json["quotes"] as? [Any])
        json["quotes"] = rows + rows
        XCTAssertNil(WidgetSnapshot.decode(try JSONSerialization.data(withJSONObject: json)))
    }

    func testInvalidPriceIsNotExportedAndLinkCarriesOnlySymbol() throws {
        let quote = Quote(symbol: symbol, name: "Test", price: .infinity, previousClose: 99, changePercent: .nan)
        let value = WidgetSnapshot(items: [WatchItem(symbol: symbol)], quotes: [symbol: quote], now: now)
        XCTAssertNil(value.quotes[0].price)
        XCTAssertNil(value.quotes[0].changePercent)
        XCTAssertNotNil(WidgetSnapshot.decode(try JSONEncoder().encode(value)))
        XCTAssertEqual(value.quotes[0].link.absoluteString, "stox://widget?symbol=sh600519")
    }
}
