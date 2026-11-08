import XCTest
import StoxCore
@testable import Stox

@MainActor
final class CryptoPresentationTests: XCTestCase {
    func testCryptoOnlyOffersRollingIntradayAndNaturalPeriodCandles() {
        let quote = Self.quote(Symbol("ccDOGEUSDT")!, price: 0.087654)
        XCTAssertEqual(ChartPeriod.available(for: quote), [.intraday, .day, .week, .month])
        XCTAssertEqual(ChartPeriod.fiveDay.effective(for: quote), .intraday)
        XCTAssertEqual(ChartPeriod.intraday.moved(by: 1, for: quote), .day)
        XCTAssertEqual(ChartPeriod.day.moved(by: -1, for: quote), .intraday)
        XCTAssertTrue(ChartPeriod.available(for: Self.quote(Symbol("usAAPL")!, price: 100)).contains(.fiveDay))
    }

    func testCryptoReadoutUsesBaseAssetInsteadOfStockUnits() {
        let text = CryptoPresentation.volume(123.45, symbol: Symbol("ccDOGEUSDT")!)
        XCTAssertTrue(text.hasSuffix(" DOGE"))
        XCTAssertFalse(text.contains("股"))
        XCTAssertFalse(text.contains("手"))
        XCTAssertEqual(CryptoPresentation.baseAsset(Symbol("ccBTCUSDT")!), "BTC")
        XCTAssertEqual(QuoteFormatter.price(0.087654, decimals: 6), "0.087654")
    }

    func testFractionalCryptoQuantitiesKeepUpToEightDecimalsAndTrimOnlyFractionalZeros() {
        let bitcoin = Symbol("ccBTCUSDT")!
        XCTAssertEqual(CryptoPresentation.volume(0.1234, symbol: bitcoin), "0.1234 BTC")
        XCTAssertEqual(CryptoPresentation.quantity(0.00000001), "0.00000001")
        XCTAssertEqual(CryptoPresentation.quantity(12.34000001), "12.34000001")
        XCTAssertEqual(CryptoPresentation.quantity(1000), "1000")
        XCTAssertEqual(CryptoPresentation.quantity(0), "0")
        XCTAssertEqual(CryptoPresentation.quantity(-0.0), "0")
        XCTAssertEqual(CryptoPresentation.quantity(10_000), QuoteFormatter.largeNumber(10_000))
    }

    func testInvalidCryptoQuantitiesDoNotProduceNumbersOrAssetUnits() {
        let bitcoin = Symbol("ccBTCUSDT")!
        for value in [Double.nan, .infinity, -.infinity, -0.1] {
            XCTAssertEqual(CryptoPresentation.quantity(value), "--")
            XCTAssertEqual(CryptoPresentation.volume(value, symbol: bitcoin), "--")
        }
    }

    func testRollingReadoutCrossesMidnightInUTCWithoutChangingGlobalTimeZone() {
        let start = ISO8601DateFormatter().date(from: "2026-11-07T23:00:00Z")!
        XCTAssertEqual(CryptoPresentation.timestamp(start), "11-07 23:00:00 UTC")
        XCTAssertEqual(CryptoPresentation.intradayTime(minute: 120, start: start), "11-08 01:00:00 UTC")
        XCTAssertEqual(CryptoPresentation.intradayTime(minute: 1440, start: start), "11-08 23:00:00 UTC")
        XCTAssertEqual(CryptoPresentation.intradayTime(minute: 60, start: nil), "01:00 UTC")
    }

    func testCryptoAlertEditorExplainsRollingWindowPriceUnitsAndUTCDailyLimit() {
        let symbol = Symbol("ccBTCUSDT")!
        let text = StockEditorPanel.alertFooter(for: symbol, quote: Self.quote(symbol, price: 76543.21))
        XCTAssertTrue(text.contains("USDT"))
        XCTAssertTrue(text.contains("UTC"))
        XCTAssertTrue(text.contains("24"))
        XCTAssertFalse(text.contains("今日"))
        XCTAssertFalse(text.contains("交易日"))
        let stockText = StockEditorPanel.alertFooter(for: Symbol("usAAPL")!, quote: nil)
        XCTAssertEqual(stockText, L("留空表示不提醒。每个条件每个交易日最多提醒一次。"))
    }

    func testFilterSelectionRestoresFromIsolatedPreferences() {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.settings.listFilter = .crypto
        let restored = SettingsStore(defaults: context.defaults)
        XCTAssertEqual(restored.listFilter, .crypto)
        restored.listFilter = .group("Mixed")
        XCTAssertEqual(SettingsStore(defaults: context.defaults).listFilter, .group("Mixed"))
    }

    private static func quote(_ symbol: Symbol, price: Double) -> Quote {
        Quote(symbol: symbol, name: "Fixture", price: price, previousClose: price, open: price,
              high: price, low: price, volume: 1, amount: price, priceDecimals: CryptoCatalog.priceDecimals(for: price))
    }
}
