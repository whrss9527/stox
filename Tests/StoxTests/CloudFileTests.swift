import Foundation
import XCTest
import StoxCore
@testable import Stox

/// 真实 Foundation 呈现者，模拟编辑器尚未落盘的修改；不依赖 iCloud 账号。
private final class SyncSavingPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue
    }()
    private let lock = NSLock()
    private var pending: Data?
    private var saved = false
    private var deleted = false
    init(url: URL, unsaved: Data) { presentedItemURL = url; pending = unsaved }
    var events: (saved: Bool, deleted: Bool) {
        lock.lock(); defer { lock.unlock() }; return (saved, deleted)
    }
    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        lock.lock(); let data = pending; lock.unlock()
        guard let data, let url = presentedItemURL else { completionHandler(nil); return }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: self).coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if coordinationError == nil && writeError == nil {
            lock.lock(); pending = nil; saved = true; lock.unlock()
        }
        if let coordinationError { completionHandler(coordinationError) }
        else { completionHandler(writeError) }
    }
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        lock.lock(); deleted = true; lock.unlock(); completionHandler(nil)
    }
}

final class CloudFileTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func document(_ settings: SyncedSettings, time: Double) -> SyncDocument {
        SyncDocument(updatedAt: Date(timeIntervalSince1970: time), device: "fixture-\(time)",
                     content: SyncContent(watchlist: [], settings: settings))
    }

    func testConflictMergeIncludesLatestPresentedEditAndUsesOneCommonBaseline() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let base = document(SyncedSettings(refreshInterval: 5, showName: false, showPrice: false), time: 1)
        try base.encoded().write(to: url)
        // 三个设备各改一个字段；最新版本的基线值不能覆盖其他设备的独立改动。
        let first = document(SyncedSettings(refreshInterval: 10, showName: false, showPrice: false), time: 2)
        let second = document(SyncedSettings(refreshInterval: 5, showName: true, showPrice: false), time: 3)
        let unsaved = document(SyncedSettings(refreshInterval: 5, showName: false, showPrice: true), time: 4)
        let presenter = SyncSavingPresenter(url: url, unsaved: try unsaved.encoded())
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let result = try XCTUnwrap(CloudFile.mergeConflictDocuments([first, second], base: base.content, at: url))
        XCTAssertEqual(result.content.settings.refreshInterval, 10)
        XCTAssertEqual(result.content.settings.showName, true)
        XCTAssertEqual(result.content.settings.showPrice, true)
        XCTAssertEqual(try SyncDocument.decode(Data(contentsOf: url)), result)
        XCTAssertTrue(presenter.events.saved)
        XCTAssertFalse(presenter.events.deleted)
    }

    func testNormalMergePreservesUnsavedPresentedEdits() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let base = document(SyncedSettings(refreshInterval: 5, showName: false), time: 1)
        try base.encoded().write(to: url)
        let pending = document(SyncedSettings(refreshInterval: 10, showName: false), time: 2)
        let presenter = SyncSavingPresenter(url: url, unsaved: try pending.encoded())
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let proposed = document(SyncedSettings(refreshInterval: 5, showName: true), time: 3)
        let result = try CloudFile.merge(proposed, base: base.content, at: url)
        XCTAssertEqual(result.content.settings.refreshInterval, 10)
        XCTAssertEqual(result.content.settings.showName, true)
        XCTAssertTrue(presenter.events.saved)
        XCTAssertFalse(presenter.events.deleted)
    }

    func testUnreadableCurrentDocumentIsRetainedInsteadOfResolvingCapturedVersions() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let proposed = document(SyncedSettings(showName: true), time: 2)
        for data in [Data("broken-json".utf8), try SyncDocument(format: 2, updatedAt: Date(), device: "future", content: proposed.content).encoded()] {
            try data.write(to: url)
            XCTAssertThrowsError(try CloudFile.mergeConflictDocuments([proposed], base: nil, at: url))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testFailedAtomicWritePreservesExistingDocument() throws {
        let root = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("sync.json")
        let original = document(SyncedSettings(showName: false), time: 1)
        try original.encoded().write(to: url)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try CloudFile.mergeConflictDocuments([document(SyncedSettings(showName: true), time: 2)], base: original.content, at: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testConcurrentCoordinatedMergesKeepEveryIndependentAddition() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let base = SyncContent(watchlist: [], settings: SyncedSettings())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let item = WatchItem(symbol: Symbol("usTEST\(index)")!, name: "fixture-\(index)")
                let proposed = SyncDocument(updatedAt: Date(timeIntervalSince1970: Double(index)), device: "fixture",
                                            content: SyncContent(watchlist: [item], settings: SyncedSettings()))
                group.addTask { _ = try CloudFile.merge(proposed, base: base, at: url) }
            }
            try await group.waitForAll()
        }
        let result = try XCTUnwrap(CloudFile.read(at: url))
        XCTAssertEqual(Set(result.content.watchlist.map(\.symbol.rawValue)), Set((0..<20).map { "usTEST\($0)" }))
    }
}
