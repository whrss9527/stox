import XCTest
import StoxCore
@testable import Stox

final class TableImportStoreTests: XCTestCase {
    @MainActor
    func testPreviewDoesNotWriteAndConfirmedImportPersistsAndPushes() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = FakeQuoteProvider()
        let original = WatchItem(symbol: Symbol("usAAPL")!, pinned: true, note: "keep")
        let store = try context.store(provider: provider, items: [original])
        defer { store.stop() }
        let sync = SyncManager(store: store, settings: context.settings, defaults: context.defaults,
                               clock: context.clock, location: .override(folder), watchesChanges: false)
        defer { sync.disable() }
        await sync.enable()
        let file = folder.appendingPathComponent("sync.json")
        let before = try Data(contentsOf: file)
        let preview = TableImport.parse("代码\t持有\t成本价\nAAPL\t10\t100")
        let planned = try preview.applying(to: store.items, mode: .merge)
        XCTAssertEqual(store.items, [original])
        XCTAssertEqual(try Data(contentsOf: file), before)
        context.date.addTimeInterval(60)
        store.replaceWatchlist(planned)
        XCTAssertEqual(context.defaults.object(forKey: "sync.localUpdatedAt") as? Date, context.date)
        let restored = Watchlist.decode(try XCTUnwrap(context.defaults.data(forKey: "watchlist.v1")))
        XCTAssertEqual(restored, planned)
        await sync.push()
        XCTAssertEqual(try XCTUnwrap(CloudFile.read(at: file)).content.watchlist, planned)
        XCTAssertEqual(store.items[0].note, "keep")
    }
}
