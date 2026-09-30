import XCTest
@testable import StoxCore

final class SyncLocationTests: XCTestCase {
    private let container = URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/iCloud~io~github~whrss9527~stox", isDirectory: true)
    private let drive = URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)

    func testOverrideWins() {
        let location = SyncLocation.resolve(override: "/tmp/fake-icloud", containerRoot: container, driveRoot: drive)
        XCTAssertEqual(location, .override(URL(fileURLWithPath: "/tmp/fake-icloud", isDirectory: true)))
        XCTAssertEqual(location?.fileURL.path, "/tmp/fake-icloud/sync.json")
        XCTAssertEqual(location?.kind, "override")
    }

    func testEmptyOverrideIsIgnored() {
        let location = SyncLocation.resolve(override: "", containerRoot: nil, driveRoot: drive)
        XCTAssertEqual(location?.kind, "drive")
    }

    func testContainerBeatsDrive() {
        let location = SyncLocation.resolve(override: nil, containerRoot: container, driveRoot: drive)
        XCTAssertEqual(location?.kind, "container")
        XCTAssertEqual(location?.folderURL.lastPathComponent, "Documents")
        XCTAssertEqual(location?.fileURL.path, container.path + "/Documents/sync.json")
    }

    /// GitHub 版没有容器：和以前一样用 iCloud 云盘/Stox/sync.json。
    func testDriveFallbackKeepsTheOldPath() {
        let location = SyncLocation.resolve(override: nil, containerRoot: nil, driveRoot: drive)
        XCTAssertEqual(location, .drive(drive.appendingPathComponent("Stox", isDirectory: true)))
        XCTAssertEqual(location?.fileURL.path, drive.path + "/Stox/sync.json")
    }

    func testNothingAvailable() {
        XCTAssertNil(SyncLocation.resolve(override: nil, containerRoot: nil, driveRoot: nil))
    }

    func testEntitlementCheck() {
        XCTAssertTrue(SyncLocation.hasContainer(entitlementValue: ["iCloud.io.github.whrss9527.stox"]))
        XCTAssertTrue(SyncLocation.hasContainer(entitlementValue: ["iCloud.other", "iCloud.io.github.whrss9527.stox"] as [Any]))
        XCTAssertFalse(SyncLocation.hasContainer(entitlementValue: ["iCloud.other"]))
        XCTAssertFalse(SyncLocation.hasContainer(entitlementValue: nil))
        XCTAssertFalse(SyncLocation.hasContainer(entitlementValue: "iCloud.io.github.whrss9527.stox"))
        XCTAssertFalse(SyncLocation.hasContainer(entitlementValue: [] as [String]))
    }

    func testMobileDocumentsFolderName() {
        XCTAssertEqual(SyncLocation.mobileDocumentsFolderName(), "iCloud~io~github~whrss9527~stox")
        XCTAssertEqual(SyncLocation.containerIdentifier, "iCloud.io.github.whrss9527.stox")
    }

    /// 两个版本写的是同一种文件：一边写到容器里的文件，另一边照样读得懂。
    func testBothEditionsShareTheDocumentFormat() throws {
        let content = SyncContent(
            watchlist: [WatchItem(symbol: Symbol("sh600519")!, name: "贵州茅台", pinned: true)],
            settings: SyncedSettings(colorScheme: "greenUp")
        )
        let written = SyncDocument(updatedAt: Date(timeIntervalSince1970: 1_790_000_000), device: "App Store 版", content: content)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stox-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for location in [SyncLocation.container(directory), .drive(directory)] {
            try FileManager.default.createDirectory(at: location.folderURL, withIntermediateDirectories: true)
            try written.encoded().write(to: location.fileURL)
            XCTAssertEqual(try SyncDocument.decode(Data(contentsOf: location.fileURL)), written)
        }
    }
}
