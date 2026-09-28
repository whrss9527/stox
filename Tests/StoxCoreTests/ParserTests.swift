import XCTest
@testable import StoxCore

final class TencentQuoteParserTests: XCTestCase {
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, _ region: MarketRegion) -> Date {
        region.calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testAShareStock() throws {
        let quotes = TencentQuoteParser.parse(Fixtures.aShares)
        XCTAssertEqual(quotes.count, 5)
        let q = try XCTUnwrap(quotes[Symbol("sh600519")!])
        XCTAssertEqual(q.name, "贵州茅台")
        XCTAssertEqual(q.price, 1239.58)
        XCTAssertEqual(q.previousClose, 1237.00)
        XCTAssertEqual(q.open, 1236.00)
        XCTAssertEqual(q.high, 1241.75)
        XCTAssertEqual(q.low, 1228.10)
        XCTAssertEqual(q.change, 2.58)
        XCTAssertEqual(q.changePercent, 0.21)
        XCTAssertEqual(q.volume, 2_253_700)
        XCTAssertEqual(q.amount, 2_783_140_281)
        XCTAssertEqual(q.turnoverRate, 0.18)
        XCTAssertEqual(q.peRatio, 19.03)
        XCTAssertEqual(try XCTUnwrap(q.marketCap), 1_549_576_000_000, accuracy: 1)
        XCTAssertEqual(q.limitUp, 1360.70)
        XCTAssertEqual(q.limitDown, 1113.30)
        XCTAssertEqual(q.priceDecimals, 2)
        XCTAssertEqual(q.direction, .up)
        XCTAssertEqual(q.timestamp, date(2026, 9, 28, 14, 10, 19, .cn))
        XCTAssertTrue(q.hasTraded)
    }

    func testAShareIndexAndETF() throws {
        let quotes = TencentQuoteParser.parse(Fixtures.aShares)
        let index = try XCTUnwrap(quotes[Symbol("sh000001")!])
        XCTAssertEqual(index.name, "上证指数")
        XCTAssertEqual(index.changePercent, -1.61)
        XCTAssertEqual(index.direction, .down)
        XCTAssertNil(index.peRatio)
        XCTAssertNil(index.limitUp)
        XCTAssertEqual(index.amount, 678_213_668_263)

        let etf = try XCTUnwrap(quotes[Symbol("sh510300")!])
        XCTAssertEqual(etf.priceDecimals, 3)
        XCTAssertEqual(QuoteFormatter.price(etf.price, decimals: etf.priceDecimals), "4.417")
        XCTAssertNil(etf.peRatio)
    }

    func testSuspendedStockHasNoTrades() throws {
        let q = try XCTUnwrap(TencentQuoteParser.parse(Fixtures.aShares)[Symbol("bj830799")!])
        XCTAssertFalse(q.hasTraded)
        XCTAssertEqual(q.direction, .flat)
        XCTAssertEqual(q.price, 34.28)
    }

    func testHongKong() throws {
        let quotes = TencentQuoteParser.parse(Fixtures.hongKong)
        let q = try XCTUnwrap(quotes[Symbol("hk00700")!])
        XCTAssertEqual(q.name, "腾讯控股")
        XCTAssertEqual(q.price, 440)
        XCTAssertEqual(q.priceDecimals, 3)
        XCTAssertEqual(q.change, 3.4)
        XCTAssertEqual(q.volume, 9_925_676)
        XCTAssertEqual(q.amount, 4_392_125_513.9)
        XCTAssertNil(q.turnoverRate)
        XCTAssertNil(q.limitUp)
        XCTAssertEqual(q.timestamp, date(2026, 9, 28, 13, 55, 11, .hk))

        let hsi = try XCTUnwrap(quotes[Symbol("hkHSI")!])
        XCTAssertEqual(hsi.name, "恒生指数")
        XCTAssertEqual(hsi.priceDecimals, 2)
        XCTAssertEqual(QuoteFormatter.price(hsi.price, decimals: hsi.priceDecimals), "24643.59")
    }

    func testUnitedStates() throws {
        let quotes = TencentQuoteParser.parse(Fixtures.unitedStates)
        XCTAssertEqual(quotes.count, 3)
        let q = try XCTUnwrap(quotes[Symbol("usAAPL")!])
        XCTAssertEqual(q.name, "苹果")
        XCTAssertEqual(q.price, 341.07)
        XCTAssertEqual(q.changePercent, 1.53)
        XCTAssertEqual(q.volume, 30_002_507)
        XCTAssertEqual(q.amount, 10_179_398_058)
        XCTAssertEqual(q.peRatio, 39.11)
        XCTAssertEqual(q.timestamp, date(2026, 9, 25, 16, 0, 1, .us))

        XCTAssertEqual(quotes[Symbol("usBRK.B")!]?.name, "伯克希尔B")
        let ixic = try XCTUnwrap(quotes[Symbol("us.IXIC")!])
        XCTAssertEqual(ixic.name, "纳斯达克")
        XCTAssertEqual(ixic.price, 27068.72)
        XCTAssertNil(ixic.marketCap)
    }

    func testIgnoresGarbage() {
        XCTAssertTrue(TencentQuoteParser.parse("").isEmpty)
        XCTAssertTrue(TencentQuoteParser.parse(#"v_pv_none_match="1";"#).isEmpty)
        XCTAssertTrue(TencentQuoteParser.parse("<html>502 Bad Gateway</html>").isEmpty)
        XCTAssertTrue(TencentQuoteParser.parse(#"v_sh600519="1~贵州茅台~600519";"#).isEmpty)
    }

    func testComputesChangeWhenMissing() {
        let q = Quote(symbol: Symbol("sh600519")!, name: "x", price: 110, previousClose: 100)
        XCTAssertEqual(q.change, 10)
        XCTAssertEqual(q.changePercent, 10)
    }
}

final class TencentSearchParserTests: XCTestCase {
    func testPinyinSearch() {
        let results = TencentSearchParser.parse(Fixtures.searchGzmt)
        XCTAssertEqual(results.map(\.symbol.rawValue), ["sh600519"])
        XCTAssertEqual(results.first?.name, "贵州茅台")
        XCTAssertEqual(results.first?.typeLabel, "股票")
    }

    func testMixedMarketsAndFiltersWarrants() {
        let results = TencentSearchParser.parse(Fixtures.searchTencent)
        XCTAssertEqual(results.map(\.symbol.rawValue), [
            "sh000847", "hk00700", "hk80700", "hk01698", "usTCEHY", "usTCTZF", "usTME",
        ])
        XCTAssertEqual(results[1].name, "腾讯控股")
        XCTAssertEqual(results[0].typeLabel, "指数")
    }

    func testUSIndexCodes() {
        let results = TencentSearchParser.parse(Fixtures.searchNasdaq)
        XCTAssertEqual(results.map(\.symbol.rawValue), ["us.HXC", "us.IXIC", "usNDAQ", "us.NDX"])
    }

    func testSkipsUnsupportedMarkets() {
        let results = TencentSearchParser.parse(Fixtures.search00700)
        XCTAssertEqual(results.map(\.symbol.rawValue), ["hk00700", "sz000700", "sz300700", "sh600700"])
        XCTAssertEqual(results.last?.name, "*ST数码")
    }

    func testEmpty() {
        XCTAssertTrue(TencentSearchParser.parse(Fixtures.searchEmpty).isEmpty)
        XCTAssertTrue(TencentSearchParser.parse("").isEmpty)
    }

    func testUnicodeEscapes() {
        XCTAssertEqual(TencentSearchParser.decodeUnicodeEscapes(#"贵州"#), "贵州")
        XCTAssertEqual(TencentSearchParser.decodeUnicodeEscapes(#"a😀b"#), "a😀b")
        XCTAssertEqual(TencentSearchParser.decodeUnicodeEscapes(#"\u12"#), #"\u12"#)
    }

    func testSearchURLEncoding() {
        XCTAssertEqual(
            TencentProvider.searchURL(for: "腾讯")?.absoluteString,
            "https://smartbox.gtimg.cn/s3/?v=2&t=all&c=1&q=%E8%85%BE%E8%AE%AF"
        )
        XCTAssertEqual(
            TencentProvider.quoteURL(for: [Symbol("sh600519")!, Symbol("us.IXIC")!])?.absoluteString,
            "https://qt.gtimg.cn/utf8/q=sh600519,us.IXIC"
        )
    }
}
