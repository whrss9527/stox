import XCTest
@testable import StoxCore

final class ExchangeRatesTests: XCTestCase {
    // 2026-09-28 从腾讯接口抓取的外汇行情。
    private let sample = #"""
    v_whUSDCNY="310~美元人民币~USDCNY~6.7101~~20260929005206~6.7121~6.7077~6.7164~6.7077~6.7101~6.7121~-0.0020~-0.03~0.20~0.05~-0.29~-1.00~-3.96~7.1430~6.6950~2026-09-28";
    v_whHKDCNY="310~港元人民币~HKDCNY~0.8551~~20260929005158~0.8554~0.8555~0.8559~0.8550~0.8551~0.8557~-0.0003~-0.04~0.20~0.02~-0.35~-1.02~-4.71~0.9183~0.8529~2026-09-28";
    """#

    func testParsesTencentRates() throws {
        let rates = try XCTUnwrap(TencentFXParser.parse(sample))
        XCTAssertEqual(rates, ExchangeRates(hkdCNY: 0.8551, usdCNY: 6.7101))
        XCTAssertEqual(rates.toCNY(.cn), 1)
        XCTAssertEqual(rates.toCNY(.hk), 0.8551)
        XCTAssertEqual(rates.toCNY(.us), 6.7101)
        XCTAssertEqual(TencentFXParser.url.absoluteString, "https://qt.gtimg.cn/utf8/q=whUSDCNY,whHKDCNY")
    }

    func testMissingOrBrokenRates() {
        let onlyDollar = #"v_whUSDCNY="310~美元人民币~USDCNY~6.7101~~20260929005206";"#
        XCTAssertNil(TencentFXParser.parse(onlyDollar), "少了港币就不折算")
        let zero = sample.replacingOccurrences(of: "HKDCNY~0.8551", with: "HKDCNY~0")
        XCTAssertNil(TencentFXParser.parse(zero))
        XCTAssertNil(TencentFXParser.parse("v_pv_none_match=\"1\";"))
        XCTAssertNil(TencentFXParser.parse(""))
    }

    func testCombinesCurrenciesIntoYuan() throws {
        let rates = ExchangeRates(hkdCNY: 0.85, usdCNY: 7)
        let summaries = [
            PortfolioSummary(region: .cn, marketValue: 1000, costValue: 800, dayProfit: 10, count: 2),
            PortfolioSummary(region: .hk, marketValue: 2000, costValue: 2200, dayProfit: -100, count: 1),
            PortfolioSummary(region: .us, marketValue: 100, costValue: 50, dayProfit: 1, count: 1),
        ]
        let total = try XCTUnwrap(Portfolio.combined(summaries, rates: rates))
        XCTAssertEqual(total.region, .cn)
        XCTAssertEqual(total.count, 4)
        XCTAssertEqual(total.marketValue, 1000 + 1700 + 700, accuracy: 1e-9)
        XCTAssertEqual(total.costValue, 800 + 1870 + 350, accuracy: 1e-9)
        XCTAssertEqual(total.dayProfit, 10 - 85 + 7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(total.totalProfitPercent), (3400.0 - 3020) / 3020 * 100, accuracy: 1e-9)

        XCTAssertNil(Portfolio.combined(Array(summaries.prefix(1)), rates: rates), "只有一种货币不用折算")
        XCTAssertNil(Portfolio.combined(summaries, rates: nil), "还没有汇率")
    }

    func testMenuBarShowsOneTotalWithRates() {
        let summaries = [
            PortfolioSummary(region: .cn, marketValue: 147_000, costValue: 145_000, dayProfit: 688, count: 2),
            PortfolioSummary(region: .us, marketValue: 3_404, costValue: 3_000, dayProfit: 5.2, count: 1),
        ]
        let parts = MenuBarTicker.dayProfitParts(summaries, rates: ExchangeRates(hkdCNY: 0.85, usdCNY: 7))
        XCTAssertEqual(parts.map(\.text), ["今日", "+¥724"])
        XCTAssertEqual(parts.last?.direction, .up)
        XCTAssertEqual(MenuBarTicker.dayProfitParts(summaries).map(\.text), ["今日", "+¥688", "+$5.20"], "没有汇率时按货币分开")
    }
}
