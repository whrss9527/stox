import XCTest
@testable import StoxCore

final class AlertPriceInputTests: XCTestCase {
    func testCryptoPriceInputKeepsEightDecimalsWithoutAbbreviations() {
        let cases: [(Double, String)] = [
            (0.087654, "0.087654"), (0.00000001, "0.00000001"),
            (12.34000001, "12.34000001"), (1000, "1000"),
            (1234567.89123456, "1234567.89123456"), (2.5, "2.5")
        ]
        for (value, expected) in cases {
            XCTAssertEqual(QuoteFormatter.alertPriceInput(value, market: .crypto), expected)
        }
        XCTAssertEqual(QuoteFormatter.alertPriceInput(nil, market: .crypto), "")
    }

    func testCryptoAlertReloadAndResavePreservesBothThresholds() throws {
        let original = PriceAlert(priceAbove: 0.087654, priceBelow: 0.00000001)
        let loaded = try JSONDecoder().decode(PriceAlert.self, from: JSONEncoder().encode(original))
        let saved = PriceAlert(
            priceAbove: Double(QuoteFormatter.alertPriceInput(loaded.priceAbove, market: .crypto)),
            priceBelow: Double(QuoteFormatter.alertPriceInput(loaded.priceBelow, market: .crypto)))
        let reloaded = try JSONDecoder().decode(PriceAlert.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reloaded, original)
    }

    func testStocksAndGenericInputRetainExistingPrecision() {
        let stock = Symbol("usAAPL")!
        XCTAssertEqual(QuoteFormatter.alertPriceInput(0.087654, market: stock.market), "0.0877")
        XCTAssertEqual(QuoteFormatter.alertPriceInput(nil, market: stock.market), "")
        XCTAssertEqual(QuoteFormatter.plain(0.087654), "0.0877")
    }
}
