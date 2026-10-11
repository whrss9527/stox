import XCTest
import StoxCore

final class TraditionalChineseLocalizationTests: XCTestCase {
    func testTraditionalBundleSelectsLanguageLocaleAndRealTranslations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let resources = folder.appendingPathComponent("Contents/Resources/zh-Hant.lproj")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/zh-Hant.lproj/Localizable.strings"),
                                        to: resources.appendingPathComponent("Localizable.strings"))
        let info = ["CFBundleIdentifier": "stox.tests.\(UUID().uuidString)",
                    "CFBundleDevelopmentRegion": "zh-Hant", "CFBundleLocalizations": ["zh-Hant"]] as [String: Any]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Contents/Info.plist"))
        let original = AppLanguage.bundle
        defer { AppLanguage.bundle = original }
        AppLanguage.bundle = try XCTUnwrap(Bundle(path: folder.path))
        XCTAssertEqual(AppLanguage.bundle.localizations, ["zh-Hant"])
        XCTAssertTrue(AppLanguage.isTraditionalChinese)
        XCTAssertFalse(AppLanguage.isEnglish)
        XCTAssertEqual(AppLanguage.locale.identifier, "zh_Hant_HK")
        XCTAssertEqual(L("设置…"), "設定…")
        XCTAssertEqual(L("名称\t代码\t币种\t持有\t成本价\t现价\t市值\t持仓盈亏\t盈亏比例\t今日盈亏\t分组").components(separatedBy: "\t")[1], "代號")
        XCTAssertEqual(L("第 %@ 行", 3), "第 3 行")
        XCTAssertEqual(WatchItem(symbol: Symbol("hkHSI")!, name: "恒生指数").displayName, "恆生指數")
        XCTAssertEqual(AppLanguage.monthTitle(year: 2026, month: 9), "2026年9月")
    }

    func testSystemLocalizationMatchesTraditionalRegionalPreferences() {
        for code in ["zh-Hant", "zh-Hant-TW", "zh-TW", "zh-HK"] {
            XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "zh-Hans", "zh-Hant"], forPreferences: [code]).first, "zh-Hant")
        }
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "zh-Hans", "zh-Hant"], forPreferences: ["zh-CN"]).first, "zh-Hans")
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "zh-Hans", "zh-Hant"], forPreferences: ["en-US"]).first, "en")
    }
}
