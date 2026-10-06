import XCTest
@testable import StoxCore

final class SyncMergeTests: XCTestCase {
    private func item(_ code: String, note: String = "") -> WatchItem {
        var item = WatchItem(symbol: Symbol(code)!, name: code)
        item.note = note
        return item
    }
    private var base: SyncContent {
        SyncContent(watchlist: [item("sh600519"), item("usAAPL")], settings: SyncedSettings(refreshInterval: 5, showName: true))
    }
    private func document(_ content: SyncContent, time: Double, device: String = "Mac") -> SyncDocument {
        SyncDocument(updatedAt: Date(timeIntervalSince1970: time), device: device, content: content)
    }
    private func merge(_ local: SyncContent, _ remote: SyncContent, localTime: Double = 10, remoteTime: Double = 20) -> SyncContent {
        SyncMerge.threeWay(base: base, local: document(local, time: localTime), remote: document(remote, time: remoteTime)).content
    }

    func testSingleSidedChangesSurviveRegardlessOfDocumentTime() {
        var local = base
        local.watchlist[0].note = "本机备注"
        XCTAssertEqual(merge(local, base), local)
        XCTAssertEqual(merge(base, local), local)
    }

    func testDifferentSymbolsAndSettingFieldsAreBothKept() {
        var local = base
        local.watchlist[0].holding = Holding(shares: 100, cost: 1200)
        local.settings.refreshInterval = 10
        var remote = base
        remote.watchlist[1].note = "云端备注"
        remote.settings.showName = false
        let result = merge(local, remote)
        XCTAssertEqual(result.watchlist[0].holding, local.watchlist[0].holding)
        XCTAssertEqual(result.watchlist[1].note, remote.watchlist[1].note)
        XCTAssertEqual(result.settings.refreshInterval, 10)
        XCTAssertEqual(result.settings.showName, false)
    }

    func testSameSymbolAndFieldUseNewestChangedDocument() {
        var local = base
        local.watchlist[0].note = "本机"
        local.settings.refreshInterval = 10
        var remote = base
        remote.watchlist[0].note = "云端"
        remote.settings.refreshInterval = 20
        XCTAssertEqual(merge(local, remote).watchlist[0].note, "云端")
        XCTAssertEqual(merge(local, remote, localTime: 30).settings.refreshInterval, 10)
    }

    func testDeletionDoesNotResurrectAnUnchangedItem() {
        var local = base
        local.watchlist.removeFirst()
        XCTAssertEqual(merge(local, base).watchlist, local.watchlist)
        XCTAssertEqual(merge(base, local).watchlist, local.watchlist)
        var changed = base
        changed.watchlist[0].note = "更新"
        XCTAssertEqual(merge(local, changed).watchlist.first(where: { $0.symbol == Symbol("sh600519")! })?.note, "更新")
        XCTAssertEqual(merge(local, changed, localTime: 30).watchlist, local.watchlist)
    }

    func testAdditionsAndReorderingArePreserved() {
        var local = base
        local.watchlist.reverse()
        local.watchlist.append(item("hk00700"))
        var remote = base
        remote.watchlist.append(item("usTSLA"))
        let result = merge(local, remote, localTime: 30)
        XCTAssertEqual(result.watchlist.map(\.symbol), ["usAAPL", "sh600519", "hk00700", "usTSLA"].map { Symbol($0)! })
    }

    func testMultipleConflictVersionsUseOriginalBaselineForEveryItem() throws {
        var first = base
        first.watchlist[0].note = "早期备注"
        var second = base
        second.watchlist[1].note = "较晚的其他证券"
        var third = base
        third.watchlist[0].note = "中间的备注"
        let result = try XCTUnwrap(SyncMerge.resolving(base: base, documents: [document(first, time: 10), document(second, time: 30), document(third, time: 20)]))
        XCTAssertEqual(result.content.watchlist[0].note, "中间的备注")
        XCTAssertEqual(result.content.watchlist[1].note, "较晚的其他证券")
    }

    func testEqualTimesConvergeAndMissingSettingsKeepBaseline() {
        var a = base
        a.watchlist[0].note = "A"
        var b = base
        b.watchlist[0].note = "B"
        b.settings = SyncedSettings(showName: false)
        let da = document(a, time: 10, device: "A")
        let db = document(b, time: 10, device: "B")
        let forward = SyncMerge.threeWay(base: base, local: da, remote: db)
        XCTAssertEqual(forward, SyncMerge.threeWay(base: base, local: db, remote: da))
        XCTAssertEqual(forward.content.settings.refreshInterval, 5)
        XCTAssertEqual(forward.content.settings.showName, false)
    }
}
