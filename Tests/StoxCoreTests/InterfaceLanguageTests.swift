import XCTest
@testable import StoxCore

final class InterfaceLanguageTests: XCTestCase {
    func testReadsTheStoredChoice() {
        XCTAssertEqual(InterfaceLanguage(appleLanguages: nil), .system)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: [String]()), .system)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["en"]), .english)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["en-US", "zh-Hans"]), .english)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["zh-Hans"]), .simplifiedChinese)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: "en"), .english)
        // 系统设置里给 Stox 单独选了别的语言：当作跟随系统。
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["fr"]), .system)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["zh-Hant"]), .system)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: 42), .system)
    }

    func testRoundTrip() {
        for language in InterfaceLanguage.allCases {
            XCTAssertEqual(InterfaceLanguage(appleLanguages: language.appleLanguages), language)
        }
        XCTAssertNil(InterfaceLanguage.system.appleLanguages)
        XCTAssertEqual(InterfaceLanguage.simplifiedChinese.appleLanguages, ["zh-Hans"])
    }

    func testLanguagesAreNamedInTheirOwnLanguage() {
        XCTAssertEqual(InterfaceLanguage.english.title, "English")
        XCTAssertEqual(InterfaceLanguage.simplifiedChinese.title, "简体中文")
        XCTAssertEqual(InterfaceLanguage.system.title, "跟随系统")
    }

    func testRelaunchArguments() {
        XCTAssertEqual(Relaunch.pidToWait(in: ["Stox"] + Relaunch.arguments(waitingFor: 4321)), 4321)
        XCTAssertNil(Relaunch.pidToWait(in: ["Stox", "--show-panel"]))
        XCTAssertNil(Relaunch.pidToWait(in: ["Stox", "--relaunch-after"]))
        XCTAssertNil(Relaunch.pidToWait(in: ["Stox", "--relaunch-after", "x"]))
        XCTAssertNil(Relaunch.pidToWait(in: ["Stox", "--relaunch-after", "0"]))
    }
}
