import XCTest
@testable import StoxCore

final class FormattingTests: XCTestCase {
    func testPriceAndChange() {
        XCTAssertEqual(QuoteFormatter.price(1239.58, decimals: 2), "1239.58")
        XCTAssertEqual(QuoteFormatter.price(440, decimals: 3), "440.000")
        XCTAssertEqual(QuoteFormatter.price(0, decimals: 2), "--")
        XCTAssertEqual(QuoteFormatter.change(2.58, decimals: 2), "+2.58")
        XCTAssertEqual(QuoteFormatter.change(-0.098, decimals: 3), "-0.098")
        XCTAssertEqual(QuoteFormatter.change(-0.001, decimals: 2), "0.00")
        XCTAssertEqual(QuoteFormatter.percent(-1.61), "-1.61%")
        XCTAssertEqual(QuoteFormatter.percent(0.21), "+0.21%")
        XCTAssertEqual(QuoteFormatter.percent(0), "0.00%")
    }

    func testLargeNumbers() {
        XCTAssertEqual(QuoteFormatter.largeNumber(2_783_140_281), "27.83亿")
        XCTAssertEqual(QuoteFormatter.largeNumber(9_925_676), "992.57万")
        XCTAssertEqual(QuoteFormatter.largeNumber(4_977_636_973_000), "4.98万亿")
        XCTAssertEqual(QuoteFormatter.largeNumber(9_999), "9999")
        XCTAssertEqual(QuoteFormatter.volume(2_253_700, market: .sh), "2.25万手")
        XCTAssertEqual(QuoteFormatter.volume(9_925_676, market: .hk), "992.57万股")
        XCTAssertEqual(QuoteFormatter.volume(0, market: .us), "--")
    }

    func testTime() {
        let date = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9, minute: 5, second: 3))!
        XCTAssertEqual(QuoteFormatter.time(date, timeZone: MarketRegion.cn.timeZone), "09:05:03")
        XCTAssertEqual(QuoteFormatter.time(date, timeZone: MarketRegion.us.timeZone), "21:05:03")
    }

    func testAbbreviation() {
        XCTAssertEqual(NameAbbreviator.abbreviate("贵州茅台"), "贵州茅台")
        XCTAssertEqual(NameAbbreviator.abbreviate("沪深300ETF华泰柏瑞"), "沪深300E")
        XCTAssertEqual(NameAbbreviator.abbreviate("Berkshire Hathaway"), "Berkshir")
        XCTAssertEqual(NameAbbreviator.abbreviate("阿里巴巴-W", maxWidth: 4), "阿里")
    }
}

final class WatchlistTests: XCTestCase {
    func testDefaultsAreValidAndUnique() {
        XCTAssertEqual(Set(Watchlist.defaults.map(\.symbol)).count, Watchlist.defaults.count)
        XCTAssertEqual(Watchlist.defaults.filter(\.pinned).map(\.tickerName), ["上证"])
    }

    func testPersistenceIsLossy() throws {
        let json = #"""
        [{"symbol":"sh600519","name":"贵州茅台","pinned":true,"alert":{"priceAbove":1300}},
         {"symbol":"bogus"},
         {"symbol":"hk00700"},
         {"symbol":"sh600519","name":"重复"}]
        """#
        let items = try XCTUnwrap(Watchlist.decode(Data(json.utf8)))
        XCTAssertEqual(items.map(\.symbol.rawValue), ["sh600519", "hk00700"])
        XCTAssertEqual(items[0].alert.priceAbove, 1300)
        XCTAssertTrue(items[0].pinned)
        XCTAssertFalse(items[1].pinned)
        XCTAssertEqual(items[1].displayName, "00700")

        let roundTrip = try XCTUnwrap(Watchlist.decode(try XCTUnwrap(Watchlist.encode(items))))
        XCTAssertEqual(roundTrip, items)
    }

    func testTickerEntries() {
        let maotai = Symbol("sh600519")!
        let items = [
            WatchItem(symbol: maotai, name: "贵州茅台", alias: "茅台", pinned: true),
            WatchItem(symbol: Symbol("hk00700")!, name: "腾讯控股", pinned: true),
            WatchItem(symbol: Symbol("usAAPL")!, name: "苹果"),
        ]
        let quotes = [maotai: Quote(symbol: maotai, name: "贵州茅台", price: 1239.58, previousClose: 1237, change: 2.58, changePercent: 0.21)]
        let entries = MenuBarTicker.entries(items: items, quotes: quotes, options: TickerOptions())
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].map(\.text), ["茅台", "1239.58", "+0.21%"])
        XCTAssertEqual(entries[0].last?.direction, .up)
        XCTAssertEqual(entries[1].map(\.text), ["腾讯控股", "--", "--"])

        let percentOnly = MenuBarTicker.entries(items: items, quotes: quotes, options: TickerOptions(showName: false, showPrice: false))
        XCTAssertEqual(percentOnly[0].map(\.text), ["+0.21%"])
        XCTAssertTrue(MenuBarTicker.entries(items: items, quotes: quotes, options: TickerOptions(showName: false, showPrice: false, showPercent: false)).isEmpty)
    }

    func testXueqiuLinks() {
        XCTAssertEqual(QuoteLinks.xueqiu(Symbol("sh600519")!)?.absoluteString, "https://xueqiu.com/S/SH600519")
        XCTAssertEqual(QuoteLinks.xueqiu(Symbol("hk00700")!)?.absoluteString, "https://xueqiu.com/S/00700")
        XCTAssertEqual(QuoteLinks.xueqiu(Symbol("hkHSI")!)?.absoluteString, "https://xueqiu.com/S/HKHSI")
        XCTAssertEqual(QuoteLinks.xueqiu(Symbol("us.IXIC")!)?.absoluteString, "https://xueqiu.com/S/.IXIC")
        XCTAssertEqual(QuoteLinks.xueqiu(Symbol("usAAPL")!)?.absoluteString, "https://xueqiu.com/S/AAPL")
    }
}
