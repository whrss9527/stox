import XCTest
@testable import StoxCore

final class AlertEngineTests: XCTestCase {
    private let symbol = Symbol("sh600519")!

    private func quote(price: Double, previousClose: Double = 100, day: Int = 28, hour: Int = 10) -> Quote {
        let time = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        return Quote(symbol: symbol, name: "贵州茅台", price: price, previousClose: previousClose,
                     open: previousClose, volume: 100, timestamp: time)
    }

    private func item(_ alert: PriceAlert) -> WatchItem {
        WatchItem(symbol: symbol, name: "贵州茅台", alert: alert)
    }

    func testFiresOncePerDay() {
        var engine = AlertEngine()
        let items = [item(PriceAlert(priceAbove: 105))]
        let now = Date()

        XCTAssertTrue(engine.evaluate(items: items, quotes: [symbol: quote(price: 104)], now: now).isEmpty)

        let fired = engine.evaluate(items: items, quotes: [symbol: quote(price: 106)], now: now)
        XCTAssertEqual(fired.map(\.condition), [.priceAbove])
        XCTAssertEqual(fired.first?.title, "贵州茅台 价格涨到 105.00")
        XCTAssertEqual(fired.first?.body, "现价 106.00，涨跌 +6.00（+6.00%）")

        // 同一天价格回落再突破，不再重复提醒。
        XCTAssertTrue(engine.evaluate(items: items, quotes: [symbol: quote(price: 104)], now: now).isEmpty)
        XCTAssertTrue(engine.evaluate(items: items, quotes: [symbol: quote(price: 107)], now: now).isEmpty)

        // 下一个交易日可以再次提醒。
        let nextDay = engine.evaluate(items: items, quotes: [symbol: quote(price: 107, day: 29)], now: now)
        XCTAssertEqual(nextDay.count, 1)
    }

    func testAllConditions() {
        var engine = AlertEngine()
        let alert = PriceAlert(priceAbove: 200, priceBelow: 95, riseAbove: 3, fallBelow: 4)
        let down = engine.evaluate(items: [item(alert)], quotes: [symbol: quote(price: 94)], now: Date())
        XCTAssertEqual(Set(down.map(\.condition)), [.priceBelow, .fallBelow])
        XCTAssertEqual(down.first(where: { $0.condition == .fallBelow })?.title, "贵州茅台 跌幅达到 4.00%")

        var engine2 = AlertEngine()
        let up = engine2.evaluate(items: [item(alert)], quotes: [symbol: quote(price: 103)], now: Date())
        XCTAssertEqual(up.map(\.condition), [.riseAbove])
    }

    func testResetAllowsRefire() {
        var engine = AlertEngine()
        let items = [item(PriceAlert(priceAbove: 105))]
        XCTAssertEqual(engine.evaluate(items: items, quotes: [symbol: quote(price: 106)], now: Date()).count, 1)
        engine.reset(symbol)
        XCTAssertEqual(engine.evaluate(items: items, quotes: [symbol: quote(price: 106)], now: Date()).count, 1)
    }

    func testSkipsQuotesWithoutTrades() {
        var engine = AlertEngine()
        let suspended = Quote(symbol: symbol, name: "贵州茅台", price: 100, previousClose: 100)
        let items = [item(PriceAlert(priceBelow: 101))]
        XCTAssertTrue(engine.evaluate(items: items, quotes: [symbol: suspended], now: Date()).isEmpty)
    }

    func testCodableRoundTrip() throws {
        var engine = AlertEngine()
        _ = engine.evaluate(items: [item(PriceAlert(priceAbove: 1))], quotes: [symbol: quote(price: 106)], now: Date())
        let decoded = try JSONDecoder().decode(AlertEngine.self, from: JSONEncoder().encode(engine))
        XCTAssertEqual(decoded, engine)
        XCTAssertEqual(decoded.firedDays["sh600519|priceAbove"], "2026-09-28")
    }
}

final class HoldingAlertTests: XCTestCase {
    private let symbol = Symbol("sh600519")!

    private func quote(price: Double) -> Quote {
        let time = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 10))!
        return Quote(symbol: symbol, name: "贵州茅台", price: price, previousClose: price, open: price, volume: 100, timestamp: time)
    }

    func testTakeProfitAndStopLoss() throws {
        var engine = AlertEngine()
        let holding = Holding(shares: 100, cost: 1000)
        let items = [WatchItem(symbol: symbol, name: "贵州茅台", alert: PriceAlert(profitAbove: 20, lossBelow: 10), holding: holding)]

        XCTAssertTrue(engine.evaluate(items: items, quotes: [symbol: quote(price: 1100)], now: Date()).isEmpty, "赚 10% 还不到")
        let profit = engine.evaluate(items: items, quotes: [symbol: quote(price: 1200)], now: Date())
        XCTAssertEqual(profit.map(\.condition), [.profitAbove])
        let trigger = try XCTUnwrap(profit.first)
        XCTAssertEqual(trigger.title, "贵州茅台 持仓盈利达到 20.00%")
        XCTAssertEqual(trigger.body, "现价 1200.00，成本 1000.00，持仓盈亏 +20000.00（+20.00%）")

        var fresh = AlertEngine()
        let loss = fresh.evaluate(items: items, quotes: [symbol: quote(price: 899)], now: Date())
        XCTAssertEqual(loss.map(\.condition), [.lossBelow])
        XCTAssertEqual(loss.first?.title, "贵州茅台 持仓亏损达到 10.00%")
    }

    func testNeedsAHoldingWithCost() {
        var engine = AlertEngine()
        let alert = PriceAlert(profitAbove: 5, lossBelow: 5)
        let noHolding = [WatchItem(symbol: symbol, name: "贵州茅台", alert: alert)]
        XCTAssertTrue(engine.evaluate(items: noHolding, quotes: [symbol: quote(price: 5000)], now: Date()).isEmpty)
        let free = [WatchItem(symbol: symbol, name: "贵州茅台", alert: alert, holding: Holding(shares: 100, cost: 0))]
        XCTAssertTrue(engine.evaluate(items: free, quotes: [symbol: quote(price: 5000)], now: Date()).isEmpty, "成本为 0 没有比例")
        XCTAssertFalse(alert.isEmpty)
        XCTAssertTrue(PriceAlert().isEmpty)
    }

    func testOldAlertsStillDecode() throws {
        let json = #"{"priceAbove":105,"fallBelow":3}"#
        let alert = try JSONDecoder().decode(PriceAlert.self, from: Data(json.utf8))
        XCTAssertEqual(alert, PriceAlert(priceAbove: 105, fallBelow: 3))
        XCTAssertNil(alert.profitAbove)
    }
}
