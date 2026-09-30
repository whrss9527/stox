import XCTest
@testable import StoxCore

final class LocalizationTests: XCTestCase {
    func testWithoutTablesTheChineseSourceIsShown() {
        // 单元测试里没有翻译表，原样返回中文，所以别的测试里比较的还是中文。
        XCTAssertEqual(L("设置…"), "设置…")
        XCTAssertEqual(L("%@ 涨停", "贵州茅台"), "贵州茅台 涨停")
        XCTAssertEqual(L("还有 %@ 个更早的版本，见发布页", 3), "还有 3 个更早的版本，见发布页")
        XCTAssertFalse(AppLanguage.isEnglish)
    }

    func testPlaceholders() {
        XCTAssertEqual(AppLanguage.format("%@ is up %@%", ["AAPL", "5.00"]), "AAPL is up 5.00%")
        XCTAssertEqual(AppLanguage.format("%1$@ jumped %3$@% in %2$@ minutes", ["AAPL", "5", "2.10"]), "AAPL jumped 2.10% in 5 minutes")
        XCTAssertEqual(AppLanguage.format("100% of %@", ["x"]), "100% of x")
        XCTAssertEqual(AppLanguage.format("%@ and %@", ["a"]), "a and ")
        XCTAssertEqual(AppLanguage.format("%5$@", ["a"]), "")
    }

    func testChineseMonthNames() {
        XCTAssertEqual(AppLanguage.monthName(9), "9月")
        XCTAssertEqual(AppLanguage.monthTitle(year: 2026, month: 9), "2026年9月")
    }
}
