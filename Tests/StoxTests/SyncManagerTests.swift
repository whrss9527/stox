import XCTest
import StoxCore
@testable import Stox

final class SyncManagerTests: XCTestCase {
    @MainActor
    func testRemoteApplyDoesNotEchoAndLocalEditPushes() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let symbol = Symbol("sh600519")!
        let provider = FakeQuoteProvider()
        let store = try context.store(provider: provider, items: [WatchItem(symbol: symbol, name: "Local")])
        defer { store.stop() }
        let sync = SyncManager(store: store, settings: context.settings, defaults: context.defaults,
                               clock: context.clock, location: .override(folder), watchesChanges: false)
        defer { sync.disable() }
        await sync.enable()
        XCTAssertTrue(sync.enabled)
        let file = folder.appendingPathComponent("sync.json")
        let initial = try XCTUnwrap(CloudFile.read(at: file))
        XCTAssertEqual(initial.content.watchlist, store.items)
        let localStamp = context.defaults.object(forKey: "sync.localUpdatedAt") as? Date
        context.date.addTimeInterval(60)
        var remoteSettings = context.settings.syncedSettings
        remoteSettings.refreshInterval = 10
        let remote = SyncDocument(updatedAt: context.date, device: "Fixture Mac",
                                  content: SyncContent(watchlist: [WatchItem(symbol: symbol, name: "Cloud", note: "remote")],
                                                       settings: remoteSettings))
        try CloudFile.write(remote, to: file)
        let beforePull = try Data(contentsOf: file)
        await sync.pull()
        XCTAssertEqual(store.items.first?.note, "remote")
        XCTAssertEqual(context.settings.refreshInterval, 10)
        XCTAssertEqual(context.defaults.object(forKey: "sync.localUpdatedAt") as? Date, localStamp,
                       "applying remote settings and watchlist must not become a local edit")
        XCTAssertEqual(try Data(contentsOf: file), beforePull, "unchanged cloud data must not be pushed back")
        await sync.pull()
        XCTAssertEqual(try Data(contentsOf: file), beforePull)
        context.date.addTimeInterval(60)
        var edited = try XCTUnwrap(store.items.first)
        edited.note = "local edit"
        store.update(edited)
        XCTAssertEqual(context.defaults.object(forKey: "sync.localUpdatedAt") as? Date, context.date)
        await sync.push()
        let pushed = try XCTUnwrap(CloudFile.read(at: file))
        XCTAssertEqual(pushed.content.watchlist.first?.note, "local edit")
        XCTAssertEqual(pushed.content.settings.refreshInterval, 10)
        XCTAssertEqual(pushed.updatedAt, context.date)
    }

    @MainActor
    func testInitialConflictWaitsForChoiceAndUseCloudDoesNotPushLocalData() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = FakeQuoteProvider()
        let store = try context.store(provider: provider, items: [WatchItem(symbol: Symbol("sh600519")!, name: "Local")])
        defer { store.stop() }
        let remote = SyncDocument(updatedAt: context.date, device: "Fixture Mac",
                                  content: SyncContent(watchlist: [WatchItem(symbol: Symbol("usAAPL")!, name: "Cloud")],
                                                       settings: context.settings.syncedSettings))
        let file = folder.appendingPathComponent("sync.json")
        try CloudFile.write(remote, to: file)
        let data = try Data(contentsOf: file)
        let sync = SyncManager(store: store, settings: context.settings, defaults: context.defaults,
                               clock: context.clock, location: .override(folder), watchesChanges: false)
        defer { sync.disable() }
        await sync.enable()
        XCTAssertFalse(sync.enabled)
        XCTAssertEqual(sync.pending, remote)
        XCTAssertEqual(try Data(contentsOf: file), data)
        sync.resolve(.useCloud)
        for _ in 0..<1000 {
            if sync.enabled { break }
            await Task.yield()
        }
        XCTAssertTrue(sync.enabled)
        XCTAssertEqual(store.items.map(\.symbol), remote.content.watchlist.map(\.symbol))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}
