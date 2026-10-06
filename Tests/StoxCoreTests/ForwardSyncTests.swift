import XCTest
@testable import StoxCore

final class ForwardSyncTests: XCTestCase {
    private func sample() throws -> SyncDocument {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "future-sync", withExtension: "json", subdirectory: "Fixtures"))
        return try SyncDocument.decode(Data(contentsOf: fixture))
    }

    func testUnknownWatchItemsAndTradesKeepTheirPositionsAndJSON() throws {
        let document = try sample()
        XCTAssertEqual(document.content.watchlist.map(\.symbol.rawValue), ["usAAPL", "usMSFT"])
        XCTAssertEqual(document.content.unknownWatchItems.map(\.index), [1, 3])
        XCTAssertEqual(document.content.watchlist[0].trades.count, 2)
        XCTAssertEqual(document.content.watchlist[0].unknownTrades.map(\.index), [1])
        let roundTrip = try SyncDocument.decode(document.encoded())
        XCTAssertEqual(roundTrip, document)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: roundTrip.encoded()) as? [String: Any])
        let content = try XCTUnwrap(json["content"] as? [String: Any])
        let items = try XCTUnwrap(content["watchlist"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["symbol"] as? String }, ["usAAPL", "future:bond", "usMSFT", "future:option"])
        let trades = try XCTUnwrap(items[0]["trades"] as? [[String: Any]])
        XCTAssertEqual(trades.map { $0["side"] as? String }, ["buy", "future-split", "sell"])
        XCTAssertEqual((items[1]["faceValue"] as? NSNumber)?.uint64Value, UInt64.max)
    }

    func testEditingKnownContentAndRebuildingAppStateKeepsUnknownRecords() throws {
        let original = try sample().content
        var edited = SyncContent(watchlist: original.watchlist, settings: original.settings,
                                 unknownWatchItems: original.unknownWatchItems)
        edited.watchlist[0].note = "Local note"
        edited.watchlist[0].trades = edited.watchlist[0].trades.appending([
            Trade(side: .buy, shares: 1, price: 90, day: "2026-10-04")
        ])
        edited.settings.showPrice = false
        let data = try JSONEncoder().encode(edited)
        let result = try JSONDecoder().decode(SyncContent.self, from: data)
        XCTAssertEqual(result.unknownWatchItems, original.unknownWatchItems)
        XCTAssertEqual(result.watchlist[0].unknownTrades, original.watchlist[0].unknownTrades)
        XCTAssertEqual(result.watchlist[0].note, "Local note")
        XCTAssertEqual(result.watchlist[0].trades.count, 3)
    }

    func testThreeWayMergeKeepsFutureDataAlongsideIndependentEdits() throws {
        let base = try sample()
        var local = base, remote = base
        local.content.watchlist[0].note = "Mac A"
        local.updatedAt.addTimeInterval(10)
        remote.content.watchlist[1].alias = "MS"
        remote.updatedAt.addTimeInterval(20)
        let merged = SyncMerge.threeWay(base: base.content, local: local, remote: remote)
        XCTAssertEqual(merged.content.unknownWatchItems, base.content.unknownWatchItems)
        XCTAssertEqual(merged.content.watchlist[0].unknownTrades, base.content.watchlist[0].unknownTrades)
        XCTAssertEqual(merged.content.watchlist[0].note, "Mac A")
        XCTAssertEqual(merged.content.watchlist[1].alias, "MS")
        XCTAssertEqual(try SyncDocument.decode(merged.encoded()).content, merged.content)
    }

    func testExplicitFutureItemDeletionAndImportArePreserved() throws {
        let base = try sample()
        var remote = base
        remote.updatedAt.addTimeInterval(10)
        remote.content.unknownWatchItems.removeFirst()
        let merged = SyncMerge.threeWay(base: base.content, local: base, remote: remote)
        XCTAssertEqual(merged.content.unknownWatchItems, remote.content.unknownWatchItems)
        let empty = SyncContent(watchlist: [], settings: SyncedSettings())
        XCTAssertEqual(empty.importing(base.content).unknownWatchItems, base.content.unknownWatchItems)
    }

    func testRemovingKnownItemsClampsOpaquePositionsWithoutLosingThem() throws {
        var content = try sample().content
        content.watchlist = []
        let result = try JSONDecoder().decode(SyncContent.self, from: JSONEncoder().encode(content))
        XCTAssertEqual(result.unknownWatchItems.map(\.value), content.unknownWatchItems.map(\.value))
        XCTAssertEqual(result.unknownWatchItems.map(\.index), [0, 1])
    }

    func testStructuralFutureFormatStillFailsClosed() throws {
        var document = try sample()
        document.format = SyncDocument.currentFormat + 1
        XCTAssertThrowsError(try SyncDocument.decode(document.encoded()))
    }
}
