import XCTest
@testable import StoxCore

final class ProfitBackfillTests: XCTestCase {
    private let symbol = Symbol("sh600519")!
    private let now = ISO8601DateFormatter().date(from: "2026-09-30T04:00:00Z")!
    private let days = ["2026-09-23", "2026-09-24", "2026-09-28", "2026-09-29", "2026-09-30"]

    private func series(_ symbol: Symbol, days: [String]? = nil) -> KlineSeries {
        KlineSeries(symbol: symbol, period: .day, candles: (days ?? self.days).enumerated().map { index, day in
            Candle(date: day, open: 10, close: 10 + Double(index), high: 15, low: 10)
        })
    }

    private func item(shares: Double = 10, trades: [Trade] = []) -> WatchItem {
        WatchItem(symbol: symbol, holding: Holding(shares: shares, cost: 8), trades: trades)
    }

    func testBackfillsAcrossWeekendAndHolidayUsingPreviousTradingClose() {
        var history = ProfitHistory()
        history.backfill(items: [item()], series: [symbol: series(symbol)], now: now)
        XCTAssertEqual(history.records.map(\.day), ["2026-09-24", "2026-09-28", "2026-09-29"])
        XCTAssertEqual(history.records.map(\.dayProfit), [10, 10, 10])
        XCTAssertTrue(history.records.allSatisfy(\.estimated))
        XCTAssertTrue(history.records.allSatisfy { $0.marketValue == nil && $0.totalProfit == nil })
        XCTAssertEqual(history.dayProfitTotal(.cn, since: "2026-09-28"), 20)
        let calendar = ProfitCalendar(history: history, region: .cn, year: 2026, month: 9)
        XCTAssertTrue(calendar.cells[27].estimated)
        XCTAssertEqual(calendar.total, 30)
        XCTAssertEqual(ProfitYear(history: history, region: .cn, year: 2026).total, 30)
        XCTAssertTrue(history.tableText.contains("2026-09-28\tCNY\t10.00\t\t\t估算"))
    }

    func testDoesNotOverwriteRecordedDayAndRealRecordCanReplaceEstimate() {
        var history = ProfitHistory()
        let real = PortfolioSummary(region: .cn, marketValue: 150, costValue: 80, dayProfit: 123, count: 1)
        history.record(real, day: "2026-09-28")
        history.backfill(items: [item()], series: [symbol: series(symbol)], now: now)
        let recorded = history.records.first { $0.day == "2026-09-28" }
        XCTAssertEqual(recorded?.dayProfit, 123)
        XCTAssertFalse(recorded?.estimated ?? true)
        let once = history
        history.backfill(items: [item()], series: [symbol: series(symbol)], now: now)
        XCTAssertEqual(history, once)
        history.record(real, day: "2026-09-24")
        XCTAssertFalse(history.records.first { $0.day == "2026-09-24" }!.estimated)
        XCTAssertEqual(history.records.count, 3)
    }

    func testReconstructsHoldingsAndSkipsTradeDaysIncludingDividends() {
        let trades = [
            Trade(side: .buy, shares: 10, price: 8, day: "2026-09-24"),
            Trade(side: .dividend, shares: 10, price: 0.5, day: "2026-09-28", bonus: 0.2),
            Trade(side: .sell, shares: 2, price: 14, day: "2026-09-30"),
        ]
        var history = ProfitHistory()
        history.backfill(items: [item(shares: 10, trades: trades)], series: [symbol: series(symbol)], now: now)
        XCTAssertEqual(history.records.map(\.day), ["2026-09-29"])
        XCTAssertEqual(history.records.first?.dayProfit, 12, "卖出前、送股后的数量")
    }

    func testInitialPurchaseDoesNotInventEarlierHoldingAndSoldOutHoldingIsRecovered() {
        let trades = [Trade(side: .buy, shares: 10, price: 10, day: "2026-09-24"),
                      Trade(side: .sell, shares: 10, price: 14, day: "2026-09-29")]
        let sold = WatchItem(symbol: symbol, trades: trades)
        var history = ProfitHistory()
        history.backfill(items: [sold], series: [symbol: series(symbol)], now: now)
        XCTAssertEqual(history.records.map(\.day), ["2026-09-28"])
        XCTAssertEqual(history.records.first?.dayProfit, 10)
    }

    func testKeepsCurrenciesSeparateAndRequiresCompleteMarketData() {
        let second = Symbol("sz000001")!, hk = Symbol("hk00700")!
        let items = [item(), WatchItem(symbol: second, holding: Holding(shares: 20, cost: 8)),
                     WatchItem(symbol: hk, holding: Holding(shares: 30, cost: 8))]
        var history = ProfitHistory()
        history.backfill(items: items, series: [symbol: series(symbol), hk: series(hk)], now: now)
        XCTAssertEqual(history.regions, [.hk], "缺一只的行情不记半份人民币合计")
        history.backfill(items: items, series: [symbol: series(symbol), second: series(second), hk: series(hk)], now: now)
        XCTAssertEqual(history.recent(.cn, limit: 3).map(\.dayProfit), [30, 30, 30])
        XCTAssertEqual(history.recent(.hk, limit: 3).map(\.dayProfit), [30, 30, 30])
    }

    func testAnyTradeInMarketPreventsPartialAggregateForThatDay() {
        let second = Symbol("sz000001")!
        var history = ProfitHistory()
        let sold = WatchItem(symbol: second, trades: [Trade(side: .sell, shares: 20, price: 11, day: "2026-09-28")])
        history.backfill(items: [item(), sold], series: [symbol: series(symbol), second: series(second)], now: now)
        XCTAssertFalse(history.records.contains { $0.day == "2026-09-28" })
    }

    func testUnknownOrInconsistentTradesPreventGuessing() {
        var unknown = item()
        unknown.unknownTrades = [PreservedJSONItem(index: 0, value: .object(["side": .string("future")]))]
        var history = ProfitHistory()
        history.backfill(items: [unknown], series: [symbol: series(symbol)], now: now)
        XCTAssertTrue(history.records.isEmpty)
        history.backfill(items: [item(trades: [Trade(side: .buy, shares: 100, price: 8, day: "2026-09-30")])],
                         series: [symbol: series(symbol)], now: now)
        XCTAssertTrue(history.records.isEmpty, "不能倒推出负股数")
    }

    func testLookbackIsAtMost60TradingDaysAndNeverToday() {
        let start = KlineCalendar.date(from: "2026-05-01", region: .cn)!
        let days = (0..<140).compactMap { offset -> String? in
            let date = start.addingTimeInterval(Double(offset) * 86400)
            let weekday = MarketRegion.cn.calendar.component(.weekday, from: date)
            return weekday == 1 || weekday == 7 ? nil : ProfitHistory.day(of: date, region: .cn)
        }
        var history = ProfitHistory()
        let bars = series(symbol, days: days)
        history.backfill(items: [item()], series: [symbol: bars], now: now)
        XCTAssertEqual(history.records.count, 60)
        XCTAssertEqual(history.records.map(\.day), Array(days.dropFirst().suffix(60)))
    }

    func testMultipleTradesOnSameDayAreReversedInRecordingOrder() {
        let trades = [Trade(side: .buy, shares: 10, price: 10, day: "2026-09-29"),
                      Trade(side: .sell, shares: 15, price: 13, day: "2026-09-29")]
        var history = ProfitHistory()
        history.backfill(items: [item(shares: 5, trades: trades)], series: [symbol: series(symbol)], now: now)
        XCTAssertEqual(history.records.map(\.day), ["2026-09-24", "2026-09-28"])
        XCTAssertEqual(history.records.map(\.dayProfit), [10, 10])
    }

    func testTruncatedTradeLogDoesNotEstimateBeforeOldestRetainedTrade() {
        let trades = (0..<Trade.limit).map { _ in Trade(side: .sell, shares: 1, price: 10, day: "2026-09-28") }
        var history = ProfitHistory()
        history.backfill(items: [item(trades: trades)], series: [symbol: series(symbol)], now: now)
        XCTAssertEqual(history.records.map(\.day), ["2026-09-29"])
        XCTAssertEqual(history.records.first?.dayProfit, 10)
    }

    func testRejectsInvalidOrDuplicateCandlesAndWrongPeriod() {
        var history = ProfitHistory()
        var bars = series(symbol)
        bars.candles.append(bars.candles[0])
        history.backfill(items: [item()], series: [symbol: bars], now: now)
        XCTAssertTrue(history.records.isEmpty)
        bars = series(symbol)
        bars.candles[0].close = .infinity
        history.backfill(items: [item()], series: [symbol: bars], now: now)
        XCTAssertTrue(history.records.isEmpty)
        bars = series(symbol)
        bars.period = .week
        history.backfill(items: [item()], series: [symbol: bars], now: now)
        XCTAssertTrue(history.records.isEmpty)
    }

    func testLegacyHistoryLoadsWithoutEstimateFlagAndEstimatePersists() throws {
        let data = Data(#"{"records":[{"day":"2026-09-28","region":"cn","dayProfit":10,"totalProfit":100,"marketValue":200}]}"#.utf8)
        var history = try JSONDecoder().decode(ProfitHistory.self, from: data)
        XCTAssertFalse(history.records[0].estimated)
        history.backfill(items: [item()], series: [symbol: series(symbol)], now: now)
        XCTAssertEqual(try JSONDecoder().decode(ProfitHistory.self, from: JSONEncoder().encode(history)), history)
    }
}
