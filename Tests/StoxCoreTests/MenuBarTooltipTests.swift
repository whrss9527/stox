import XCTest
@testable import StoxCore

final class MenuBarTooltipTests: XCTestCase {
    private let maotai = Symbol("sh600519")!
    private let tencent = Symbol("hk00700")!
    private let apple = Symbol("usAAPL")!

    func testShowsAllPinsInWatchlistOrderWithFullNames() {
        let items = [
            WatchItem(symbol: tencent, name: "旧名字", alias: "腾讯", pinned: true),
            WatchItem(symbol: apple, name: "苹果"),
            WatchItem(symbol: maotai, name: "贵州茅台", alias: "茅台", pinned: true),
        ]
        let quotes = [
            tencent: Quote(symbol: tencent, name: "腾讯控股", price: 613.5, previousClose: 620,
                           changePercent: -1.05, priceDecimals: 3),
            maotai: Quote(symbol: maotai, name: "贵州茅台", price: 1239.58, previousClose: 1237,
                          changePercent: 0.21),
        ]
        XCTAssertEqual(MenuBarTicker.toolTip(items: items, quotes: quotes, english: false),
                       "腾讯控股 (00700)  613.500  -1.05%\n贵州茅台 (600519)  1239.58  +0.21%")
    }

    func testMissingQuotesUseCachedNamesAndCodes() {
        let items = [
            WatchItem(symbol: maotai, name: "贵州茅台", pinned: true),
            WatchItem(symbol: apple, pinned: true),
        ]
        XCTAssertEqual(MenuBarTicker.toolTip(items: items, quotes: [:], english: false),
                       "贵州茅台 (600519)  --  --\nAAPL  --  --")
    }

    func testPartialQuotesKeepEveryPinAndDoNotInventPrices() {
        let items = [
            WatchItem(symbol: maotai, name: "贵州茅台", pinned: true),
            WatchItem(symbol: tencent, name: "腾讯控股", pinned: true),
            WatchItem(symbol: apple, name: "苹果", pinned: true),
        ]
        let quotes = [
            maotai: Quote(symbol: maotai, name: "贵州茅台", price: 0, previousClose: 1200),
            tencent: Quote(symbol: tencent, name: "腾讯控股", price: 600, previousClose: 600),
        ]
        XCTAssertEqual(MenuBarTicker.toolTip(items: items, quotes: quotes, english: false),
                       "贵州茅台 (600519)  --  --\n腾讯控股 (00700)  600.00  0.00%\n苹果 (AAPL)  --  --")
    }

    func testInvalidNumbersUsePlaceholders() {
        let item = WatchItem(symbol: maotai, name: "贵州茅台", pinned: true)
        for price in [Double.nan, .infinity, -.infinity, -1, 0] {
            let quote = Quote(symbol: maotai, name: "贵州茅台", price: price, previousClose: 1200)
            XCTAssertEqual(MenuBarTicker.toolTip(items: [item], quotes: [maotai: quote], english: false),
                           "贵州茅台 (600519)  --  --")
        }
        let quote = Quote(symbol: maotai, name: "贵州茅台", price: 1200, previousClose: 1200,
                          changePercent: .nan)
        XCTAssertEqual(MenuBarTicker.toolTip(items: [item], quotes: [maotai: quote], english: false),
                       "贵州茅台 (600519)  1200.00  --")
    }

    func testEnglishUsesDisplayNamesInsteadOfTickerAliases() {
        let item = WatchItem(symbol: apple, name: "苹果", alias: "果", pinned: true)
        let quote = Quote(symbol: apple, name: "苹果", price: 250, previousClose: 250,
                          englishName: "Apple Inc.")
        XCTAssertEqual(MenuBarTicker.toolTip(items: [item], quotes: [apple: quote], english: true),
                       "Apple (AAPL)  250.00  0.00%")
        XCTAssertEqual(MenuBarTicker.toolTip(items: [item], quotes: [:], english: true),
                       "AAPL  --  --")
    }

    func testEmptyAndManuallyHiddenKeepHelpWithoutExposingPins() {
        let help = "Stox 行情\n左键：打开 / 关闭行情面板\n右键：隐藏 / 显示菜单栏行情"
        let item = WatchItem(symbol: maotai, name: "贵州茅台", pinned: true)
        XCTAssertEqual(MenuBarTicker.toolTip(items: [], quotes: [:]), help)
        XCTAssertEqual(MenuBarTicker.toolTip(items: [WatchItem(symbol: maotai)], quotes: [:]), help)
        XCTAssertEqual(MenuBarTicker.toolTip(items: [item], quotes: [:], manuallyHidden: true), help)
        XCTAssertEqual(MenuBarTicker.toolTip(items: [item], quotes: [:], manuallyHidden: false, english: false),
                       "贵州茅台 (600519)  --  --")
    }

    func testPinAndQuoteChangesReplacePreviousContent() {
        var items = [WatchItem(symbol: maotai, name: "贵州茅台", pinned: true),
                     WatchItem(symbol: tencent, name: "腾讯控股", pinned: true)]
        var quotes: [Symbol: Quote] = [:]
        XCTAssertEqual(MenuBarTicker.toolTip(items: items, quotes: quotes, english: false).split(separator: "\n").count, 2)
        items[0].pinned = false
        quotes[tencent] = Quote(symbol: tencent, name: "腾讯控股", price: 600, previousClose: 600)
        XCTAssertEqual(MenuBarTicker.toolTip(items: items, quotes: quotes, english: false),
                       "腾讯控股 (00700)  600.00  0.00%")
        quotes[tencent]?.price = 612
        quotes[tencent]?.changePercent = 2
        XCTAssertEqual(MenuBarTicker.toolTip(items: items, quotes: quotes, english: false),
                       "腾讯控股 (00700)  612.00  +2.00%")
    }

    func testNeverIncludesHoldingsNotesOrGroups() {
        let item = WatchItem(symbol: maotai, name: "贵州茅台", pinned: true,
                             holding: Holding(shares: 123456, cost: 9876), note: "private note", group: "private")
        let quote = Quote(symbol: maotai, name: "贵州茅台", price: 1200, previousClose: 1200)
        XCTAssertEqual(MenuBarTicker.toolTip(items: [item], quotes: [maotai: quote], english: false),
                       "贵州茅台 (600519)  1200.00  0.00%")
    }
}
