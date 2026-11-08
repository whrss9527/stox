import XCTest
@testable import StoxCore

final class CryptoWatchlistTests: XCTestCase {
    func testCryptoFilterHasStableSettingsIdentityAndKeepsOriginalOrder() throws {
        let stock = WatchItem(symbol: Symbol("usAAPL")!, name: "Apple")
        let btc = WatchItem(symbol: Symbol("ccBTCUSDT")!, name: "Bitcoin", group: "Mixed")
        let doge = WatchItem(symbol: Symbol("ccDOGEUSDT")!, name: "Dogecoin")
        let items = [stock, btc, doge]
        XCTAssertEqual(WatchlistFilter(id: "crypto"), .crypto)
        XCTAssertEqual(WatchlistFilter.crypto.id, "crypto")
        XCTAssertEqual(WatchlistFilter.crypto.apply(items).map(\.symbol), [btc.symbol, doge.symbol])
        XCTAssertEqual(WatchlistFilter.us.apply(items).map(\.symbol), [stock.symbol])
        XCTAssertEqual(WatchlistFilter.available(for: items), [.all, .us, .crypto, .group("Mixed")])
        XCTAssertEqual(WatchlistFilter.effective(.crypto, items: items), .crypto)
        XCTAssertEqual(WatchlistFilter.effective(.crypto, items: [stock]), .all)
        XCTAssertEqual(WatchlistFilter.available(for: [doge]), [])
    }

    func testCryptoLinksUseAnAllowlistedSpotPairAndStockLinksStayUnchanged() throws {
        for entry in CryptoCatalog.entries {
            let link = try XCTUnwrap(QuoteLinks.web(entry.symbol))
            XCTAssertEqual(link.title, "Binance")
            XCTAssertEqual(link.url.absoluteString,
                           "https://www.binance.com/en/trade/\(entry.baseAsset)_USDT?type=spot")
            XCTAssertNil(QuoteLinks.xueqiu(entry.symbol))
        }
        XCTAssertEqual(QuoteLinks.web(Symbol("usBTC")!)?.url.absoluteString, "https://xueqiu.com/S/BTC")
        XCTAssertEqual(QuoteLinks.web(Symbol("sh600519")!)?.url.absoluteString, "https://xueqiu.com/S/SH600519")
    }

    func testAutomaticCryptoTickerKeepsQuoteAssetInEveryLanguageAndTooltipIncludesPair() {
        let bitcoin = Symbol("ccBTCUSDT")!
        var item = WatchItem(symbol: bitcoin, name: "Bitcoin", pinned: true)
        for english in [false, true] {
            XCTAssertEqual(item.automaticTickerName(with: nil, english: english), "BTC/USDT")
            XCTAssertEqual(item.automaticTickerName(with: nil, english: english, traditional: true), "BTC/USDT")
            XCTAssertTrue(MenuBarTicker.toolTip(items: [item], quotes: [:], english: english).contains("BTC/USDT"))
        }
        let quote = Quote(symbol: bitcoin, name: "Bitcoin", price: 76543.21, previousClose: 75000,
                          open: 75000, high: 78000, low: 74000, volume: 10, amount: 765432.1)
        let tooltip = MenuBarTicker.toolTip(items: [item], quotes: [bitcoin: quote], english: true)
        XCTAssertTrue(tooltip.contains("76543.21 USDT"))
        XCTAssertTrue(tooltip.contains("24h"))
        XCTAssertTrue(tooltip.contains("Binance"))
        item.alias = "BTC"
        XCTAssertEqual(item.tickerName(with: nil, english: false), "BTC", "Preserve the explicit user alias")
        XCTAssertTrue(MenuBarTicker.toolTip(items: [item], quotes: [:], english: false).contains("BTC/USDT"))
        let doge = WatchItem(symbol: Symbol("ccDOGEUSDT")!, name: "Dogecoin")
        XCTAssertEqual(doge.automaticTickerName(with: nil, english: false), "DOGE/USDT", "Do not truncate the quote asset")
    }

    func testMixedWatchlistRoundTripKeepsCryptoWithoutInventingHoldings() throws {
        let items = [WatchItem(symbol: Symbol("ccBTCUSDT")!, name: "Bitcoin", pinned: true, group: "Mixed"),
                     WatchItem(symbol: Symbol("usAAPL")!, name: "Apple", holding: Holding(shares: 2, cost: 100))]
        let restored = try XCTUnwrap(Watchlist.decode(JSONEncoder().encode(items)))
        XCTAssertEqual(restored, items)
        XCTAssertNil(restored[0].holding)
        XCTAssertEqual(WatchlistFilter.holdings.apply(restored).map(\.symbol.rawValue), ["usAAPL"])
        XCTAssertEqual(WatchlistFilter.group("Mixed").apply(restored).map(\.symbol.rawValue), ["ccBTCUSDT"])
    }
}
