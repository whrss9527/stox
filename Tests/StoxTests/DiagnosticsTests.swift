import XCTest
import StoxCore
@testable import Stox

final class DiagnosticsTests: XCTestCase {
    @MainActor
    func testSnapshotUsesSourceAndSyncStateWithoutReadingHoldings() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let symbol = Symbol("sh600519")!
        let primary = FakeQuoteProvider(), backup = FakeQuoteProvider()
        await primary.configure(fails: true)
        await backup.configure(values: [symbol: context.quote(symbol)])
        let item = WatchItem(symbol: symbol, name: "private-name", holding: Holding(shares: 867531, cost: 945623))
        let store = try context.store(provider: primary, backup: backup, items: [item])
        defer { store.stop() }
        let sync = SyncManager(store: store, settings: context.settings, defaults: context.defaults,
                               clock: context.clock, watchesChanges: false)
        await store.refresh()
        let report = Diagnostics.report(Diagnostics.snapshot(store: store, sync: sync), logs: [])
        XCTAssertTrue(report.contains("Quote source: Sina"))
        XCTAssertTrue(report.contains("Sync: disabled · off"))
        for value in ["867531", "945623", "private-name", "sh600519"] { XCTAssertFalse(report.contains(value)) }
    }

    func testReportLimitsLogsAndRedactsNumbersFinancialTextPathsAndLinks() {
        let snapshot = Diagnostics.Snapshot(version: "0.50.6", channel: "App Store", osVersion: "26.0",
                                            syncEnabled: true, syncState: "error", source: "Tencent")
        var logs = (0..<205).map { "2026-10-08 09:00:00 INFO earlier-message-\($0)" }
        logs += [
            "2026-10-08 09:01:00 ERROR 持仓三百股，金额六万",
            "2026-10-08 09:01:01 ERROR {\"shares\":867531,\"cost\":945623}",
            "2026-10-08 09:01:02 ERROR unknown value 867531.25 at /Users/private-name/holdings.json",
            "2026-10-08 09:01:03 ERROR https://example.com/?amount=945623",
            "867531.25",
            "2026-10-08 09:01:05 INFO 腾讯行情取不到，改用新浪行情",
        ]
        let report = Diagnostics.report(snapshot, logs: logs)
        XCTAssertTrue(report.contains("Stox 0.50.6 · App Store"))
        XCTAssertTrue(report.contains("Sync: enabled · error"))
        XCTAssertTrue(report.contains("Quote source: Tencent"))
        XCTAssertTrue(report.contains("2026-10-08 09:01:05 INFO 腾讯行情取不到，改用新浪行情"))
        XCTAssertEqual(report.components(separatedBy: .newlines).count, 205)
        for value in ["867531", "945623", "三百", "六万", "private-name", "example.com"] {
            XCTAssertFalse(report.contains(value), value)
        }
        XCTAssertEqual(Diagnostics.redactLog("quantity: 一千"), "[financial data redacted]")
        XCTAssertEqual(Diagnostics.redactLog("value １２３４.５０"), "value [redacted]")
    }

    func testFeedbackPrefillsTheBugTemplateAndRoundTripsVersionAndOS() throws {
        let url = Diagnostics.feedbackURL(version: "0.50.6-beta.1", osVersion: "26.0 (Build 25A+123)")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/whrss9527/stox/issues/new")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "template" })?.value, "bug.yml")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "version" })?.value,
                       "Stox 0.50.6-beta.1; macOS 26.0 (Build 25A+123)")
    }
}
