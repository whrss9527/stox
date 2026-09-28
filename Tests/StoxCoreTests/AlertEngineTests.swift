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
