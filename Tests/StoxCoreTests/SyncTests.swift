import XCTest
@testable import StoxCore

final class SyncTests: XCTestCase {
    private func item(_ raw: String, _ name: String, pinned: Bool = false, above: Double? = nil) -> WatchItem {
        WatchItem(symbol: Symbol(raw)!, name: name, pinned: pinned, alert: PriceAlert(priceAbove: above))
    }

    private var sampleContent: SyncContent {
        SyncContent(
            watchlist: [item("sh600519", "贵州茅台", pinned: true, above: 1300), item("hk00700", "腾讯控股")],
            settings: SyncedSettings(refreshInterval: 5, slowWhenIdle: true, colorScheme: "neutral", showName: true,
                                     showPrice: false, showPercent: true, rotateTicker: false, alertsEnabled: true)
        )
    }

    func testDocumentRoundTrip() throws {
        let document = SyncDocument(updatedAt: Date(timeIntervalSince1970: 1_790_000_000), device: "办公室的 Mac", content: sampleContent)
        let data = try document.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"sh600519\""))
        XCTAssertTrue(text.contains("2026-"))
        XCTAssertEqual(try SyncDocument.decode(data), document)
    }

    func testLenientDecoding() throws {
        let json = #"""
        {"content":{"watchlist":[{"symbol":"sh600519","name":"贵州茅台"},{"symbol":"bogus"},{"symbol":"sh600519"}],
                    "settings":{"colorScheme":"greenUp","someFutureSetting":1}}}
        """#
        let document = try SyncDocument.decode(Data(json.utf8))
        XCTAssertEqual(document.format, SyncDocument.currentFormat)
        XCTAssertEqual(document.device, "未知设备")
        XCTAssertEqual(document.updatedAt, .distantPast)
        XCTAssertEqual(document.content.watchlist.map(\.symbol.rawValue), ["sh600519"])
        XCTAssertEqual(document.content.settings.colorScheme, "greenUp")
        XCTAssertNil(document.content.settings.refreshInterval)
    }

    func testNewerFormatIsRejected() {
        let json = #"{"format":2,"device":"新版本","content":{"watchlist":[]}}"#
        XCTAssertThrowsError(try SyncDocument.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? SyncError, .newerFormat(2))
        }
    }

    func testMergeKeepsCloudOrderAndAppendsLocalOnlyItems() {
        let cloud = SyncContent(
            watchlist: [item("hk00700", "腾讯控股", pinned: true), item("sh600519", "贵州茅台", above: 1500)],
            settings: SyncedSettings(refreshInterval: 10, colorScheme: "redUp")
        )
        let local = SyncContent(
            watchlist: [item("sh600519", "贵州茅台", above: 1200), item("usAAPL", "苹果")],
            settings: SyncedSettings(refreshInterval: 3, slowWhenIdle: false, colorScheme: "neutral")
        )
        let merged = local.merging(cloud: cloud)
        XCTAssertEqual(merged.watchlist.map(\.symbol.rawValue), ["hk00700", "sh600519", "usAAPL"])
        XCTAssertEqual(merged.watchlist[1].alert.priceAbove, 1500, "同一只证券以 iCloud 的设置为准")
        XCTAssertEqual(merged.settings.refreshInterval, 10)
        XCTAssertEqual(merged.settings.colorScheme, "redUp")
        XCTAssertEqual(merged.settings.slowWhenIdle, false, "iCloud 没有的设置保留本机的")
    }

    func testRules() {
        let a = sampleContent
        var b = sampleContent
        b.watchlist.append(item("usAAPL", "苹果"))

        // 别的 Mac 改了：云端 b，本机和上次同步都是 a。
        XCTAssertTrue(SyncRules.shouldApply(remote: b, local: a, lastSynced: a))
        // 云端是本机刚写上去的内容。
        XCTAssertFalse(SyncRules.shouldApply(remote: b, local: b, lastSynced: b))
        // 本机改了还没写上去，云端仍是上次同步的内容：不要用旧内容覆盖本机。
        XCTAssertFalse(SyncRules.shouldApply(remote: a, local: b, lastSynced: a))
        XCTAssertTrue(SyncRules.shouldPush(local: b, lastSynced: a))
        XCTAssertFalse(SyncRules.shouldPush(local: a, lastSynced: a))
        XCTAssertTrue(SyncRules.shouldPush(local: a, lastSynced: nil))

        XCTAssertFalse(SyncRules.needsChoice(remote: nil, local: a))
        XCTAssertFalse(SyncRules.needsChoice(remote: a, local: a))
        XCTAssertTrue(SyncRules.needsChoice(remote: b, local: a))
        XCTAssertFalse(SyncRules.needsChoice(remote: SyncContent(watchlist: [], settings: SyncedSettings()), local: a),
                       "云端是空的就不必询问，直接用本机的")
    }

    func testNewestDocument() {
        let older = SyncDocument(updatedAt: Date(timeIntervalSince1970: 100), device: "A", content: sampleContent)
        let newer = SyncDocument(updatedAt: Date(timeIntervalSince1970: 200), device: "B", content: sampleContent)
        XCTAssertEqual(SyncDocument.newest([older, newer])?.device, "B")
        XCTAssertNil(SyncDocument.newest([]))
    }
}

final class BackupTests: XCTestCase {
    func testImportingKeepsLocalAndAddsTheRest() throws {
        let moutai = WatchItem(symbol: Symbol("sh600519")!, name: "贵州茅台", group: "白酒")
        let tencent = WatchItem(symbol: Symbol("hk00700")!, name: "腾讯控股")
        let apple = WatchItem(symbol: Symbol("usAAPL")!, name: "苹果", holding: Holding(shares: 10, cost: 300))
        var backupMoutai = moutai
        backupMoutai.group = "消费"
        let local = SyncContent(watchlist: [moutai, tencent], settings: SyncedSettings(refreshInterval: 5))
        let backup = SyncContent(watchlist: [apple, backupMoutai], settings: SyncedSettings(refreshInterval: 30))

        let merged = local.importing(backup)
        XCTAssertEqual(merged.watchlist.map(\.symbol.rawValue), ["sh600519", "hk00700", "usAAPL"], "本机的在前，备份里多出来的追加在后面")
        XCTAssertEqual(merged.watchlist[0].group, "白酒", "本机已有的保持本机的设置")
        XCTAssertEqual(merged.watchlist[2].holding, Holding(shares: 10, cost: 300), "新加的带着备份里的持仓")
        XCTAssertEqual(merged.settings.refreshInterval, 5, "设置用本机的")

        // 备份文件就是同步文件的格式，写出去再读回来一样。
        let document = SyncDocument(updatedAt: Date(timeIntervalSince1970: 1_790_000_000), device: "MacBook", content: backup)
        XCTAssertEqual(try SyncDocument.decode(document.encoded()), document)
        let noon = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(SyncContent.backupFileName(on: noon, timeZone: TimeZone(identifier: "Asia/Shanghai")!), "Stox 自选 2026-09-21.json")
    }
}
