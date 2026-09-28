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
        XCTAssertEqual(q.high52Week, 1539.98)
        XCTAssertEqual(q.low52Week, 1151.01)
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
        XCTAssertEqual(index.peRatio, 16.70, "A 股指数带平均市盈率")
        XCTAssertEqual(index.high52Week, 4258.86)
        XCTAssertEqual(index.low52Week, 3741.11)
        XCTAssertNil(index.limitUp)
        XCTAssertNil(index.marketCap)
        XCTAssertEqual(index.amount, 678_213_668_263)

        let etf = try XCTUnwrap(quotes[Symbol("sh510300")!])
        XCTAssertEqual(etf.priceDecimals, 3)
        XCTAssertEqual(QuoteFormatter.price(etf.price, decimals: etf.priceDecimals), "4.417")
        XCTAssertNil(etf.peRatio)
        XCTAssertEqual(etf.high52Week, 5.095)
        XCTAssertEqual(etf.low52Week, 4.397)
    }

    func testSuspendedStockHasNoTrades() throws {
        let q = try XCTUnwrap(TencentQuoteParser.parse(Fixtures.aShares)[Symbol("bj830799")!])
        XCTAssertFalse(q.hasTraded)
        XCTAssertEqual(q.direction, .flat)
        XCTAssertEqual(q.price, 34.28)
        XCTAssertNil(q.high52Week, "停牌、没有 52 周数据时不显示")
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
        XCTAssertEqual(q.turnoverRate, 0.11, "港股的换手率在第 59 位")
        XCTAssertEqual(q.peRatio, 16.08)
        XCTAssertEqual(q.high52Week, 677.7)
        XCTAssertEqual(q.low52Week, 411)
        XCTAssertNil(q.limitUp)
        XCTAssertEqual(q.timestamp, date(2026, 9, 28, 13, 55, 11, .hk))

        let hsi = try XCTUnwrap(quotes[Symbol("hkHSI")!])
        XCTAssertEqual(hsi.name, "恒生指数")
        XCTAssertEqual(hsi.priceDecimals, 2)
        XCTAssertEqual(hsi.volume, 0)
        XCTAssertEqual(hsi.amount, 117_523_943_780, accuracy: 1)
        XCTAssertEqual(QuoteFormatter.largeNumber(hsi.amount), "1175.24亿")
        XCTAssertTrue(hsi.hasTraded)
        XCTAssertNil(hsi.marketCap)
        XCTAssertNil(hsi.peRatio)
        XCTAssertNil(hsi.turnoverRate)
        XCTAssertEqual(hsi.high52Week, 28056.1)
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
        XCTAssertEqual(q.turnoverRate, 0.21)
        XCTAssertEqual(q.high52Week, 345.34)
        XCTAssertEqual(q.low52Week, 242.76)
        XCTAssertEqual(q.timestamp, date(2026, 9, 25, 16, 0, 1, .us))

        XCTAssertEqual(quotes[Symbol("usBRK.B")!]?.name, "伯克希尔B")
        let ixic = try XCTUnwrap(quotes[Symbol("us.IXIC")!])
        XCTAssertEqual(ixic.name, "纳斯达克")
        XCTAssertEqual(ixic.price, 27068.72)
        XCTAssertEqual(ixic.volume, 6_299_972_751)
        XCTAssertEqual(ixic.amount, 0)
        XCTAssertNil(ixic.marketCap)
        XCTAssertNil(ixic.peRatio)
        XCTAssertEqual(ixic.high52Week, 27288.79)
        XCTAssertEqual(ixic.low52Week, 20690.25)
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

final class ExtendedHoursTests: XCTestCase {
    // pandata 是 2026-09-28 美东 16:03 从 usfqkline 抓取的原样，那一根 K 线按同一时刻的行情补上。
    static let afterHours = #"""
    {"code":0,"msg":"","data":{"usAAPL.OQ":{"qfqday":[["2026-09-28","340.370","338.400","342.990","338.040","31448642.000"]],"pandata":{"last":"338.43","volume":"31458547","pct":"-0.77","netchange":"-2.64","time":"2026-09-28 16:03:14","tag":"after","season":"EST"},"version":"12"}}}
    """#

    private func usTime(_ text: String) -> Date? {
        TencentQuoteParser.parseTimestamp(text, timeZone: MarketRegion.us.timeZone)
    }

    /// 2026-09-28（周一）收盘时苹果的行情。
    private var appleClose: Quote {
        Quote(symbol: Symbol("usAAPL")!, name: "苹果", price: 338.40, previousClose: 341.07, timestamp: usTime("2026-09-28 16:00:01"))
    }

    func testParsesAfterHours() throws {
        let extended = try XCTUnwrap(TencentExtendedHoursParser.parse(Data(Self.afterHours.utf8)))
        XCTAssertEqual(extended.session, .afterHours)
        XCTAssertEqual(extended.session.displayName, "盘后")
        XCTAssertEqual(extended.price, 338.43)
        XCTAssertEqual(extended.time, usTime("2026-09-28 16:03:14"))

        // 涨跌相对当天的收盘价，不用接口里相对前一天收盘的 pct。
        let change = try XCTUnwrap(extended.change(from: appleClose))
        XCTAssertEqual(change.change, 0.03, accuracy: 1e-9)
        XCTAssertEqual(change.percent, 0.03 / 338.40 * 100, accuracy: 1e-9)
    }

    func testRegularHoursHaveNone() {
        let numeric = #"{"data":{"usAAPL.OQ":{"pandata":{"last":-1,"volume":"","pct":"","netchange":"","time":"","tag":"","season":""}}}}"#
        XCTAssertNil(TencentExtendedHoursParser.parse(Data(numeric.utf8)), "常规交易时段里 last 是 -1")
        let text = #"{"data":{"usAAPL.OQ":{"pandata":{"last":"-1","time":"","tag":""}}}}"#
        XCTAssertNil(TencentExtendedHoursParser.parse(Data(text.utf8)))
        XCTAssertNil(TencentExtendedHoursParser.parse(Data(#"{"data":{"usAAPL.OQ":{"qfqday":[]}}}"#.utf8)))
        XCTAssertNil(TencentExtendedHoursParser.parse(Data("<html>".utf8)))
    }

    func testSessionFromTagOrTime() throws {
        func parse(_ pandata: [String: Any]) -> ExtendedHoursQuote? { TencentExtendedHoursParser.parse(pandata: pandata) }
        XCTAssertEqual(parse(["last": "339.1", "tag": "pre", "time": "2026-09-29 07:30:00"])?.session, .preMarket)
        XCTAssertEqual(parse(["last": 339.1, "tag": "after"])?.session, .afterHours, "数字也认")
        XCTAssertEqual(parse(["last": "339.1", "tag": "", "time": "2026-09-29 07:30:00"])?.session, .preMarket, "没有标签时上午算盘前")
        XCTAssertEqual(parse(["last": "339.1", "time": "2026-09-28 17:45:00"])?.session, .afterHours, "下午算盘后")
        XCTAssertNil(parse(["last": "339.1", "tag": "?"]), "标签和时间都没有时不知道是盘前还是盘后")
        XCTAssertEqual(ExtendedHoursQuote.Session.preMarket.displayName, "盘前")
    }

    func testOnlyFollowingTradesCount() {
        let quote = appleClose
        func trade(_ session: ExtendedHoursQuote.Session, _ time: String) -> ExtendedHoursQuote {
            ExtendedHoursQuote(session: session, price: 339, time: usTime(time))
        }
        XCTAssertTrue(trade(.afterHours, "2026-09-28 19:59:58").follows(quote))
        XCTAssertTrue(trade(.preMarket, "2026-09-29 04:01:00").follows(quote), "第二天盘前，行情还是前一天收盘的")
        XCTAssertFalse(trade(.afterHours, "2026-09-25 19:59:58").follows(quote), "上周五的盘后价不能和周一的收盘比")
        XCTAssertFalse(trade(.preMarket, "2026-09-28 09:29:00").follows(quote), "当天盘前的已经过时了")
        XCTAssertNil(trade(.afterHours, "2026-09-25 19:59:58").change(from: quote))
        XCTAssertTrue(ExtendedHoursQuote(session: .afterHours, price: 339).follows(quote), "没有时间时不检查")
        var noPrice = quote
        noPrice.price = 0
        XCTAssertNil(trade(.afterHours, "2026-09-28 17:00:00").change(from: noPrice))
    }

    func testURLAndSkippedSymbols() async throws {
        XCTAssertEqual(
            TencentProvider.extendedHoursURL(for: Symbol("usAAPL")!, exchangeCode: "AAPL.OQ")?.absoluteString,
            "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usAAPL.OQ,day,,,1,qfq"
        )
        XCTAssertEqual(
            TencentProvider.extendedHoursURL(for: Symbol("usBRK.B")!, exchangeCode: "BRK.B.N")?.absoluteString,
            "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usBRK.B.N,day,,,1,qfq"
        )
        // A 股、美股指数没有盘前盘后，不发请求。
        let provider = TencentProvider(timeout: 0.01)
        let aShare = try await provider.fetchExtendedHours(for: Symbol("sh600519")!, exchangeCode: nil)
        XCTAssertNil(aShare)
        let index = try await provider.fetchExtendedHours(for: Symbol("us.IXIC")!, exchangeCode: nil)
        XCTAssertNil(index)
    }
}
