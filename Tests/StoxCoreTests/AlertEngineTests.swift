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

    func testLimitAlertsNeedTheSwitch() {
        var engine = AlertEngine()
        let items = [WatchItem(symbol: symbol, name: "贵州茅台"), WatchItem(symbol: Symbol("sh000001")!, name: "上证指数")]
        let time = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 10))!
        let sealed = Quote(symbol: symbol, name: "贵州茅台", price: 110, previousClose: 100, open: 101, volume: 100,
                           limitUp: 110, limitDown: 90, timestamp: time)
        let quotes = [symbol: sealed]

        XCTAssertTrue(engine.evaluate(items: items, quotes: quotes, now: time).isEmpty, "没打开开关时不提醒")
        let fired = engine.evaluate(items: items, quotes: quotes, now: time, limitAlerts: true)
        XCTAssertEqual(fired.map(\.condition), [.limitUp])
        XCTAssertEqual(fired.first?.title, "贵州茅台 涨停")
        XCTAssertEqual(fired.first?.body, "现价 110.00，涨跌 +10.00（+10.00%）")
        XCTAssertTrue(engine.evaluate(items: items, quotes: quotes, now: time, limitAlerts: true).isEmpty, "开板再封板当天不再提醒")

        var down = sealed
        down.price = 90
        down.change = -10
        down.changePercent = -10
        XCTAssertEqual(engine.evaluate(items: items, quotes: [symbol: down], now: time, limitAlerts: true).map(\.condition), [.limitDown])
        XCTAssertTrue(PriceAlert().isEmpty, "涨停跌停不算单只的提醒条件")
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

final class RapidMoveTests: XCTestCase {
    private let symbol = Symbol("sh600519")!
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func quote(_ price: Double) -> Quote {
        Quote(symbol: symbol, name: "贵州茅台", price: price, previousClose: 100)
    }

    func testRiseWithinTheWindow() throws {
        var detector = RapidMoveDetector()
        XCTAssertNil(detector.record(quote(100), at: start, threshold: 2))
        XCTAssertNil(detector.record(quote(101), at: start.addingTimeInterval(60), threshold: 2))
        let move = try XCTUnwrap(detector.record(quote(102.5), at: start.addingTimeInterval(120), threshold: 2))
        XCTAssertEqual(move.direction, .up)
        XCTAssertEqual(move.percent, 2.5, accuracy: 1e-9)
        // 还在涨，但冷却中，不再提醒。
        XCTAssertNil(detector.record(quote(104), at: start.addingTimeInterval(180), threshold: 2))

        let trigger = AlertTrigger(symbol: symbol, name: "贵州茅台", condition: .rapidRise, threshold: move.percent, quote: quote(102.5))
        XCTAssertEqual(trigger.title, "贵州茅台 5 分钟内拉升 2.50%")
    }

    func testSlowMovesDoNotCount() {
        var detector = RapidMoveDetector()
        // 每 4 分钟涨 1%，窗口里最多差 1%，不算异动。
        for step in 0..<6 {
            let price = 100 * pow(1.01, Double(step))
            XCTAssertNil(detector.record(quote(price), at: start.addingTimeInterval(Double(step) * 240), threshold: 2))
        }
    }

    func testFallAfterFlatAndCooldown() throws {
        var detector = RapidMoveDetector()
        // 一直不动，然后一次刷新跌了 3%。
        for step in 0..<10 {
            XCTAssertNil(detector.record(quote(100), at: start.addingTimeInterval(Double(step) * 30), threshold: 2))
        }
        let fall = try XCTUnwrap(detector.record(quote(97), at: start.addingTimeInterval(300), threshold: 2))
        XCTAssertEqual(fall.direction, .down)
        XCTAssertEqual(fall.percent, -3, accuracy: 1e-9)
        XCTAssertEqual(
            AlertTrigger(symbol: symbol, name: "贵州茅台", condition: .rapidFall, threshold: fall.percent, quote: quote(97)).title,
            "贵州茅台 5 分钟内下跌 3.00%"
        )

        // 冷却过了以后再跌才会再提醒。
        XCTAssertNil(detector.record(quote(94), at: start.addingTimeInterval(600), threshold: 2), "冷却中")
        let later = start.addingTimeInterval(300 + RapidMoveDetector.cooldown)
        XCTAssertNil(detector.record(quote(94), at: later, threshold: 2), "前面的记录已经出了窗口，只有这一笔")
        XCTAssertNotNil(detector.record(quote(91), at: later.addingTimeInterval(60), threshold: 2))

        // 阈值为 0 表示关闭；删掉以后记录清空。
        XCTAssertNil(detector.record(quote(50), at: start.addingTimeInterval(5000), threshold: 0))
        detector.forget(symbol)
        XCTAssertNil(detector.record(quote(80), at: start.addingTimeInterval(5010), threshold: 2), "清空以后只有一笔，没有比较的对象")
    }
}
