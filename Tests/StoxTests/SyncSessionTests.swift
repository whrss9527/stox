import XCTest
import Combine
import StoxCore
@testable import Stox

/// 真正读写隔离文件，再暂停结果返回；不假设可以撤销已完成的协调写入。
private actor HeldSyncFiles {
    private var nextID = 0
    private var holdReads = 0
    private var holdWrites = 0
    private var holdLookups = 0
    private var reads: [Int: (CheckedContinuation<SyncDocument?, Error>, SyncDocument?)] = [:]
    private var writes: [Int: (CheckedContinuation<SyncDocument, Error>, SyncDocument)] = [:]
    private var lookups: [Int: (CheckedContinuation<URL?, Never>, URL?)] = [:]
    private var waiters: [(String, Int, XCTestExpectation)] = []
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private var root: URL?

    func access(requiresContainer: Bool = false) -> SyncFileAccess {
        SyncFileAccess(requiresContainer: requiresContainer, containerRoot: { await self.lookup() },
                       read: { url, _ in try await self.read(url) },
                       merge: { document, base, url in try await self.merge(document, base: base, at: url) })
    }
    func holdRead() { holdReads += 1 }
    func holdWrite() { holdWrites += 1 }
    func holdLookup(root: URL) { self.root = root; holdLookups += 1 }
    func setRoot(_ root: URL) { self.root = root }

    private func read(_ url: URL) async throws -> SyncDocument? {
        readCount += 1
        let value = try CloudFile.read(at: url)
        guard holdReads > 0 else { return value }
        holdReads -= 1
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            reads[id] = (continuation, value)
            notify("read", id: id)
        }
    }
    private func merge(_ document: SyncDocument, base: SyncContent?, at url: URL) async throws -> SyncDocument {
        writeCount += 1
        let value = try CloudFile.merge(document, base: base, at: url)
        guard holdWrites > 0 else { return value }
        holdWrites -= 1
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            writes[id] = (continuation, value)
            notify("write", id: id)
        }
    }
    private func lookup() async -> URL? {
        let value = root
        guard holdLookups > 0 else { return value }
        holdLookups -= 1
        nextID += 1
        let id = nextID
        return await withCheckedContinuation { continuation in
            lookups[id] = (continuation, value)
            notify("lookup", id: id)
        }
    }
    private enum GateError: Error { case operationDidNotStart }
    func waitForRead(after: Int = 0) async throws -> Int { try await wait("read", after: after) }
    func waitForWrite() async throws -> Int { try await wait("write", after: 0) }
    func waitForLookup() async throws -> Int { try await wait("lookup", after: 0) }
    private func ids(_ kind: String) -> [Int] {
        switch kind {
        case "read": return Array(reads.keys)
        case "write": return Array(writes.keys)
        default: return Array(lookups.keys)
        }
    }
    private func wait(_ kind: String, after: Int) async throws -> Int {
        if let id = ids(kind).filter({ $0 > after }).min() { return id }
        let ready = XCTestExpectation(description: "held \(kind) started")
        waiters.append((kind, after, ready))
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        guard result == .completed, let id = ids(kind).filter({ $0 > after }).min() else {
            throw GateError.operationDidNotStart
        }
        return id
    }
    private func notify(_ kind: String, id: Int) {
        let ready = waiters.filter { $0.0 == kind && id > $0.1 }
        waiters.removeAll { $0.0 == kind && id > $0.1 }
        for waiter in ready { waiter.2.fulfill() }
    }
    func releaseRead(_ id: Int, fail: Bool = false) {
        guard let (continuation, value) = reads.removeValue(forKey: id) else { return }
        if fail { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
        else { continuation.resume(returning: value) }
    }
    func releaseWrite(_ id: Int, fail: Bool = false) {
        guard let (continuation, value) = writes.removeValue(forKey: id) else { return }
        if fail { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
        else { continuation.resume(returning: value) }
    }
    func releaseLookup(_ id: Int) {
        guard let (continuation, value) = lookups.removeValue(forKey: id) else { return }
        continuation.resume(returning: value)
    }
}

@MainActor
private final class SyncSessionFixture {
    let context = AppTestContext()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let io = HeldSyncFiles()
    let clock: QuoteStoreClock
    let store: QuoteStore
    let symbol = Symbol("usAAPL")!
    var file: URL { folder.appendingPathComponent("sync.json") }
    init() throws {
        // 取消的轮询可能还在退出；专用 clock 保留 context，避免共享 helper 的 unowned 引用悬空。
        let state = context
        clock = QuoteStoreClock(now: { state.date }, sleep: { interval in
            state.delays.append(interval)
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
        let items = [
            WatchItem(symbol: symbol, name: "Local", holding: Holding(shares: 1, cost: 100))
        ]
        context.defaults.set(try JSONEncoder().encode(items), forKey: "watchlist.v1")
        store = QuoteStore(settings: context.settings, provider: FakeQuoteProvider(), backup: nil,
                           defaults: context.defaults, clock: clock)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func manager(requiresContainer: Bool = false, watchesChanges: Bool = false) async -> SyncManager {
        let access = await io.access(requiresContainer: requiresContainer)
        return SyncManager(store: store, settings: context.settings, defaults: context.defaults,
                           clock: clock, location: .override(folder), watchesChanges: watchesChanges, files: access)
    }
    func writeRemote(note: String, interval: Double = 10) throws -> SyncDocument {
        var settings = context.settings.syncedSettings
        settings.refreshInterval = interval
        var item = store.items[0]
        item.note = note
        let document = SyncDocument(updatedAt: context.date.addingTimeInterval(60), device: "Fixture Cloud",
                                    content: SyncContent(watchlist: [item], settings: settings))
        try CloudFile.write(document, to: file)
        return document
    }
    func savedBaseline() throws -> SyncContent? {
        try context.defaults.data(forKey: "sync.lastSynced").map { try JSONDecoder().decode(SyncContent.self, from: $0) }
    }
    func cleanup(_ sync: SyncManager) {
        sync.disable()
        store.stop()
        context.cleanup()
        try? FileManager.default.removeItem(at: folder)
    }
}

final class SyncSessionTests: XCTestCase {
    @MainActor
    func testStartupSelfWriteNotificationKeepsFileCheckpointAndWatcher() async throws {
        let fixture = try SyncSessionFixture()
        let sync = await fixture.manager(watchesChanges: true)
        defer { fixture.cleanup(sync) }
        fixture.context.settings.syncEnabled = true
        await fixture.io.holdWrite()
        let startup = sync.start()
        let id = try await fixture.io.waitForWrite()
        // Held merge 已完成真实协调写入，目录通知可在该返回仍暂停时触发新 pull。
        XCTAssertEqual(try CloudFile.read(at: fixture.file)?.content.watchlist, fixture.store.items)
        let checkpoint = expectation(description: "startup reaches a synced checkpoint after its own write notification")
        var checked = false
        let status = sync.$status.sink { value in
            if case .synced = value, !checked { checked = true; checkpoint.fulfill() }
        }
        let result = await XCTWaiter.fulfillment(of: [checkpoint], timeout: 5)
        await fixture.io.releaseWrite(id)
        await startup.value
        status.cancel()
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(try fixture.savedBaseline()?.watchlist, fixture.store.items)
        guard case .synced = sync.status else { return XCTFail("startup must leave a synced checkpoint") }

        let changed = expectation(description: "external write is still observed after startup self-write")
        var observed = false
        let items = fixture.store.$items.sink { value in
            if value.first?.note == "after self-write", !observed { observed = true; changed.fulfill() }
        }
        _ = try fixture.writeRemote(note: "after self-write")
        let watchResult = await XCTWaiter.fulfillment(of: [changed], timeout: 5)
        items.cancel()
        XCTAssertEqual(watchResult, .completed, "own write notification must not remove the external watcher")
        XCTAssertEqual(fixture.store.items.first?.note, "after self-write")
    }

    @MainActor
    func testOpeningPanelDuringStartupKeepsExternalFileWatcher() async throws {
        let fixture = try SyncSessionFixture()
        let sync = await fixture.manager(watchesChanges: true)
        defer { fixture.cleanup(sync) }
        fixture.context.settings.syncEnabled = true
        let checkpoint = expectation(description: "startup plus immediate panel check creates a synced file")
        var checked = false
        let status = sync.$status.sink { value in
            if case .synced = value, !checked { checked = true; checkpoint.fulfill() }
        }
        let startup = sync.start()
        sync.panelWillOpen()
        let result = await XCTWaiter.fulfillment(of: [checkpoint], timeout: 5)
        await startup.value
        status.cancel()
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(try CloudFile.read(at: fixture.file)?.content.watchlist, fixture.store.items)
        XCTAssertEqual(try fixture.savedBaseline()?.watchlist, fixture.store.items)

        let changed = expectation(description: "external write after immediate startup panel open is observed")
        var observed = false
        let items = fixture.store.$items.sink { value in
            if value.first?.note == "after startup panel", !observed { observed = true; changed.fulfill() }
        }
        _ = try fixture.writeRemote(note: "after startup panel")
        let watchResult = await XCTWaiter.fulfillment(of: [changed], timeout: 5)
        items.cancel()
        XCTAssertEqual(watchResult, .completed, "opening the panel must not cancel required watcher setup")
        XCTAssertEqual(fixture.store.items.first?.note, "after startup panel")
    }

    @MainActor
    func testLateReadAndErrorAfterDisableCannotApplyOrStartWrite() async throws {
        for fail in [false, true] {
            let fixture = try SyncSessionFixture()
            let sync = await fixture.manager()
            defer { fixture.cleanup(sync) }
            await sync.enable()
            let before = fixture.store.items
            let interval = fixture.context.settings.refreshInterval
            _ = try fixture.writeRemote(note: "obsolete")
            await fixture.io.holdRead()
            let operation = Task { await sync.syncNow() }
            let id = try await fixture.io.waitForRead()
            let writes = await fixture.io.writeCount
            sync.disable()
            await fixture.io.releaseRead(id, fail: fail)
            await operation.value
            XCTAssertEqual(fixture.store.items, before)
            XCTAssertEqual(fixture.context.settings.refreshInterval, interval)
            XCTAssertEqual(sync.status, .off)
            XCTAssertFalse(sync.enabled)
            XCTAssertNil(try fixture.savedBaseline())
            let after = await fixture.io.writeCount
            XCTAssertEqual(after, writes, "stale syncNow must not launch a follow-up write")
        }
    }

    @MainActor
    func testLateWriteAndErrorKeepOffAfterAlreadyCommittedFileWrite() async throws {
        for fail in [false, true] {
            let fixture = try SyncSessionFixture()
            let sync = await fixture.manager()
            defer { fixture.cleanup(sync) }
            await sync.enable()
            var edited = fixture.store.items[0]
            edited.note = "committed before stopping"
            fixture.store.update(edited)
            await fixture.io.holdWrite()
            let operation = Task { await sync.push() }
            let id = try await fixture.io.waitForWrite()
            XCTAssertEqual(try CloudFile.read(at: fixture.file)?.content.watchlist[0].note, edited.note)
            sync.disable()
            await fixture.io.releaseWrite(id, fail: fail)
            let applied = await operation.value
            XCTAssertFalse(applied)
            XCTAssertEqual(fixture.store.items[0], edited)
            XCTAssertEqual(sync.status, .off)
            XCTAssertNil(try fixture.savedBaseline())
            XCTAssertEqual(try CloudFile.read(at: fixture.file)?.content.watchlist[0].note, edited.note,
                           "stopping does not undo a completed coordinated write")
        }
    }

    @MainActor
    func testOldReadAndWriteDoNotOverwriteRestartedSession() async throws {
        for write in [false, true] {
            let fixture = try SyncSessionFixture()
            let sync = await fixture.manager()
            defer { fixture.cleanup(sync) }
            await sync.enable()
            let operation: Task<Bool, Never>
            let id: Int
            if write {
                var edited = fixture.store.items[0]
                edited.note = "old write"
                fixture.store.update(edited)
                await fixture.io.holdWrite()
                operation = Task { await sync.push() }
                id = try await fixture.io.waitForWrite()
            } else {
                _ = try fixture.writeRemote(note: "old read")
                await fixture.io.holdRead()
                operation = Task { await sync.pull() }
                id = try await fixture.io.waitForRead()
            }
            sync.disable()
            fixture.context.date.addTimeInterval(120)
            var current = fixture.store.items[0]
            current.note = "new session"
            fixture.store.update(current)
            fixture.context.settings.refreshInterval = 30
            try? FileManager.default.removeItem(at: fixture.file)
            await sync.enable()
            let status = sync.status
            let baseline = try fixture.savedBaseline()
            if write { await fixture.io.releaseWrite(id) }
            else { await fixture.io.releaseRead(id) }
            let applied = await operation.value
            XCTAssertFalse(applied)
            XCTAssertTrue(sync.enabled)
            XCTAssertEqual(sync.status, status)
            XCTAssertEqual(try fixture.savedBaseline(), baseline)
            XCTAssertEqual(fixture.store.items[0].note, "new session")
            XCTAssertEqual(fixture.context.settings.refreshInterval, 30)
        }
    }

    @MainActor
    func testNewReadInSameSessionSupersedesOldResultAndError() async throws {
        for fail in [false, true] {
            let fixture = try SyncSessionFixture()
            let sync = await fixture.manager()
            defer { fixture.cleanup(sync) }
            await sync.enable()
            _ = try fixture.writeRemote(note: "older")
            await fixture.io.holdRead()
            let old = Task { await sync.pull() }
            let id = try await fixture.io.waitForRead()
            _ = try fixture.writeRemote(note: "newer", interval: 30)
            let applied = await sync.pull()
            XCTAssertTrue(applied)
            let status = sync.status
            let baseline = try fixture.savedBaseline()
            await fixture.io.releaseRead(id, fail: fail)
            let stale = await old.value
            XCTAssertFalse(stale)
            XCTAssertEqual(fixture.store.items[0].note, "newer")
            XCTAssertEqual(fixture.context.settings.refreshInterval, 30)
            XCTAssertEqual(sync.status, status)
            XCTAssertEqual(try fixture.savedBaseline(), baseline)
        }
    }

    @MainActor
    func testInitialEnableCancellationDropsDelayedDiscoveryAndRead() async throws {
        for discover in [false, true] {
            let fixture = try SyncSessionFixture()
            let sync = await fixture.manager(requiresContainer: discover)
            defer { fixture.cleanup(sync) }
            _ = try fixture.writeRemote(note: "first-enable remote")
            if discover { await fixture.io.holdLookup(root: fixture.folder) }
            else { await fixture.io.holdRead() }
            let operation = Task { await sync.enable() }
            let id: Int
            if discover { id = try await fixture.io.waitForLookup() }
            else { id = try await fixture.io.waitForRead() }
            sync.cancelEnable()
            if discover { await fixture.io.releaseLookup(id) }
            else { await fixture.io.releaseRead(id) }
            await operation.value
            XCTAssertFalse(sync.enabled)
            XCTAssertFalse(fixture.context.settings.syncEnabled)
            XCTAssertNil(sync.pending)
            XCTAssertEqual(sync.status, .off)
            XCTAssertNil(try fixture.savedBaseline())
            let writes = await fixture.io.writeCount
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testCanceledChoiceCannotReenableOrApplyRemote() async throws {
        let fixture = try SyncSessionFixture()
        let sync = await fixture.manager()
        defer { fixture.cleanup(sync) }
        _ = try fixture.writeRemote(note: "discarded choice")
        await sync.enable()
        XCTAssertNotNil(sync.pending)
        let before = fixture.store.items
        let operation = try XCTUnwrap(sync.resolve(.useCloud))
        sync.cancelEnable()
        await operation.value
        XCTAssertEqual(fixture.store.items, before)
        XCTAssertFalse(sync.enabled)
        XCTAssertEqual(sync.status, .off)
        XCTAssertNil(try fixture.savedBaseline())
    }

    @MainActor
    func testChoiceWriteFinishingAfterDisableKeepsOff() async throws {
        for choice in [SyncManager.Choice.useLocal, .merge] {
            let fixture = try SyncSessionFixture()
            let sync = await fixture.manager()
            defer { fixture.cleanup(sync) }
            _ = try fixture.writeRemote(note: "choice remote")
            await sync.enable()
            await fixture.io.holdWrite()
            let operation = try XCTUnwrap(sync.resolve(choice))
            let id = try await fixture.io.waitForWrite()
            let before = fixture.store.items
            sync.disable()
            await fixture.io.releaseWrite(id)
            await operation.value
            XCTAssertEqual(fixture.store.items, before)
            XCTAssertFalse(sync.enabled)
            XCTAssertEqual(sync.status, .off)
            XCTAssertNil(try fixture.savedBaseline())
        }
    }

    @MainActor
    func testStartupDiscoveryCannotResumeIntoRestartedSession() async throws {
        let fixture = try SyncSessionFixture()
        let sync = await fixture.manager(requiresContainer: true)
        defer { fixture.cleanup(sync) }
        let oldRoot = fixture.folder.appendingPathComponent("old-container")
        let newRoot = fixture.folder.appendingPathComponent("new-container")
        await fixture.io.holdLookup(root: oldRoot)
        fixture.context.settings.syncEnabled = true
        let startup = sync.start()
        let id = try await fixture.io.waitForLookup()
        sync.disable()
        await fixture.io.setRoot(newRoot)
        await sync.enable()
        let status = sync.status
        let baseline = try fixture.savedBaseline()
        let reads = await fixture.io.readCount
        await fixture.io.releaseLookup(id)
        await startup.value
        XCTAssertEqual(sync.containerRoot, newRoot)
        XCTAssertEqual(sync.status, status)
        XCTAssertEqual(try fixture.savedBaseline(), baseline)
        let after = await fixture.io.readCount
        XCTAssertEqual(after, reads)
    }

    @MainActor
    func testStartupStillDiscoversContainerWhenSyncIsOff() async throws {
        let fixture = try SyncSessionFixture()
        let sync = await fixture.manager(requiresContainer: true)
        defer { fixture.cleanup(sync) }
        await fixture.io.holdLookup(root: fixture.folder)
        let startup = sync.start()
        let id = try await fixture.io.waitForLookup()
        await fixture.io.releaseLookup(id)
        await startup.value
        XCTAssertEqual(sync.containerRoot, fixture.folder)
        XCTAssertFalse(sync.enabled)
        XCTAssertEqual(sync.status, .off)
        let reads = await fixture.io.readCount
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testNewWriteInSameSessionSupersedesHeldRead() async throws {
        let fixture = try SyncSessionFixture()
        let sync = await fixture.manager()
        defer { fixture.cleanup(sync) }
        await sync.enable()
        _ = try fixture.writeRemote(note: "older read")
        await fixture.io.holdRead()
        let old = Task { await sync.pull() }
        let id = try await fixture.io.waitForRead()
        fixture.context.date.addTimeInterval(120)
        var edited = fixture.store.items[0]
        edited.note = "newer local write"
        fixture.store.update(edited)
        let applied = await sync.push()
        XCTAssertTrue(applied)
        let status = sync.status
        let baseline = try fixture.savedBaseline()
        await fixture.io.releaseRead(id)
        let stale = await old.value
        XCTAssertFalse(stale)
        XCTAssertEqual(fixture.store.items[0].note, edited.note)
        XCTAssertEqual(sync.status, status)
        XCTAssertEqual(try fixture.savedBaseline(), baseline)
        XCTAssertEqual(try CloudFile.read(at: fixture.file)?.content.watchlist[0].note, edited.note)
    }
}
