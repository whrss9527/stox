import XCTest
@testable import StoxCore

final class CryptoAlertCoreTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!

    func testRollingHighAndLowCannotTriggerCurrentPriceThresholds() throws {
        let symbol = try XCTUnwrap(Symbol("ccBTCUSDT"))
        let item = WatchItem(symbol: symbol, alert: PriceAlert(priceAbove: 150, priceBelow: 75))
        var quote = Quote(symbol: symbol, name: "Bitcoin", price: 100, previousClose: 100,
                          high: 200, low: 50, timestamp: now)
        var engine = AlertEngine()
        XCTAssertTrue(engine.evaluate(items: [item], quotes: [symbol: quote], now: now).isEmpty,
                      "滚动24h中触达过阈值不代表当前突破")
        quote.price = 150
        XCTAssertEqual(engine.evaluate(items: [item], quotes: [symbol: quote], now: now).map(\.condition), [.priceAbove])
        quote.price = 75
        XCTAssertEqual(engine.evaluate(items: [item], quotes: [symbol: quote], now: now).map(\.condition), [.priceBelow])
    }

    func testUnsupportedStockAndHoldingAlertsAreIgnoredEvenWithImportedFields() throws {
        let symbol = try XCTUnwrap(Symbol("ccBTCUSDT"))
        var item = WatchItem(symbol: symbol, alert: PriceAlert(riseAbove: 5, fallBelow: 5, profitAbove: 1, lossBelow: 1))
        item.holding = Holding(shares: 1, cost: 50)
        var quote = Quote(symbol: symbol, name: "Bitcoin", price: 100, previousClose: 90,
                          high: 200, low: 50, changePercent: 10,
                          limitUp: 100, limitDown: 100, high52Week: 100, low52Week: 100, timestamp: now)
        var engine = AlertEngine()
        XCTAssertEqual(engine.evaluate(items: [item], quotes: [symbol: quote], now: now,
                                       limitAlerts: true, yearAlerts: true).map(\.condition), [.riseAbove])
        quote.changePercent = -10
        var falling = AlertEngine()
        XCTAssertEqual(falling.evaluate(items: [item], quotes: [symbol: quote], now: now,
                                        limitAlerts: true, yearAlerts: true).map(\.condition), [.fallBelow])
        XCTAssertFalse(AlertCondition.profitAbove.isMet(by: quote, holding: Holding(shares: 1, cost: 50), threshold: 1))
        XCTAssertFalse(AlertCondition.lossBelow.isMet(by: quote, holding: Holding(shares: 1, cost: 200), threshold: 1))
    }

    func testCryptoNotificationStatesRollingChangeAndQuoteCurrency() throws {
        let symbol = try XCTUnwrap(Symbol("ccBTCUSDT"))
        let quote = Quote(symbol: symbol, name: "Bitcoin", price: 150, previousClose: 100,
                          high: 200, low: 50, timestamp: now)
        for condition in [AlertCondition.priceAbove, .priceBelow, .riseAbove, .fallBelow] {
            let body = AlertTrigger(symbol: symbol, name: "Bitcoin", condition: condition, threshold: 150, quote: quote).body
            XCTAssertTrue(body.contains(L("24小时涨跌 %@", "+50.00 USDT")))
            XCTAssertTrue(body.contains("150.00 USDT"))
            XCTAssertFalse(body.contains(L("今天最高 %@，", "200.00")))
            XCTAssertFalse(body.contains(L("今天最低 %@，", "50.00")))
        }
    }

    func testImportedCryptoTradeProfitIsPreservedButExcludedFromTotals() throws {
        var crypto = WatchItem(symbol: try XCTUnwrap(Symbol("ccBTCUSDT")))
        let legacy = Trade(side: .sell, shares: 1, price: 200, day: "2026-11-08", profit: 100)
        crypto.trades = [legacy]
        var stock = WatchItem(symbol: try XCTUnwrap(Symbol("usAAPL")))
        stock.trades = [Trade(side: .sell, shares: 1, price: 50, day: "2026-11-08", profit: 5)]
        let totals = Portfolio.realizedProfit(items: [crypto, stock], since: "2026-01-01")
        XCTAssertEqual(totals.map(\.region), [.us])
        XCTAssertEqual(totals.map(\.profit), [5])
        let roundTrip = try JSONDecoder().decode(WatchItem.self, from: JSONEncoder().encode(crypto))
        XCTAssertEqual(roundTrip.trades, [legacy], "不支持计算不代表可以删除旧/外部客户端保存的记录")
    }
}
