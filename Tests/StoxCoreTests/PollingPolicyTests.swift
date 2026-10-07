import XCTest
@testable import StoxCore

final class PollingPolicyTests: XCTestCase {
    func testFailoverCooldownDoesNotExtendOnEveryBackupResult() {
        var policy = FailoverPolicy()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(policy.skipsPrimary(at: start))
        policy.record(source: .backup, skippedPrimary: false, at: start)
        XCTAssertTrue(policy.skipsPrimary(at: start.addingTimeInterval(119)))
        policy.record(source: .backup, skippedPrimary: true, at: start.addingTimeInterval(119))
        XCTAssertFalse(policy.skipsPrimary(at: start.addingTimeInterval(120)))
        policy.record(source: .backup, skippedPrimary: false, at: start.addingTimeInterval(120))
        XCTAssertTrue(policy.skipsPrimary(at: start.addingTimeInterval(121)))
        policy.reset()
        XCTAssertFalse(policy.skipsPrimary(at: start.addingTimeInterval(121)))
    }

    func testTickerVisibilityKeepsEmptyAndLiveMarketsVisible() {
        XCTAssertFalse(TickerVisibility.isHidden(manuallyHidden: false, hideWhenClosed: true, hasRegions: false, marketsLive: false))
        XCTAssertFalse(TickerVisibility.isHidden(manuallyHidden: false, hideWhenClosed: true, hasRegions: true, marketsLive: true))
        XCTAssertTrue(TickerVisibility.isHidden(manuallyHidden: false, hideWhenClosed: true, hasRegions: true, marketsLive: false))
        XCTAssertTrue(TickerVisibility.isHidden(manuallyHidden: true, hideWhenClosed: false, hasRegions: true, marketsLive: true))
    }

    func testLocalizationCanUseAnIndependentBundle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let english = folder.appendingPathComponent("Resources/en.lproj")
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "\"设置…\" = \"Settings…\";".write(to: english.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let old = AppLanguage.bundle
        defer { AppLanguage.bundle = old }
        AppLanguage.bundle = try XCTUnwrap(Bundle(path: folder.path))
        XCTAssertTrue(AppLanguage.isEnglish)
        XCTAssertEqual(L("设置…"), "Settings…")
        XCTAssertEqual(AppLanguage.locale.identifier, "en")
    }
}
