import XCTest
import StoxCore
@testable import Stox

final class ProfitBackfillStoreTests: XCTestCase {
    private let symbol = Symbol("sh600519")!
    private var bars: KlineSeries {
        KlineSeries(symbol: symbol, period: .day, candles: [
            Candle(date: "2026-10-05", open: 100, close: 100, high: 100, low: 100),
            Candle(date: "2026-10-06", open: 100, close: 105, high: 105, low: 100),
            Candle(date: "2026-10-07", open: 105, close: 110, high: 110, low: 105),
        ])
    }

    @MainActor
    func testOnlyExplicitCalendarRequestFetchesKlinesAndHistoryPersists() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = FakeQuoteProvider()
        await provider.configure(values: [symbol: context.quote(symbol)])
        await provider.configureKlines([symbol: bars])
        let items = [WatchItem(symbol: symbol, holding: Holding(shares: 10, cost: 90))]
        let store = try context.store(provider: provider, items: items)
        defer { store.stop() }
        await store.refresh()
        var requests = await provider.requestedKlines()
        XCTAssertTrue(requests.isEmpty, "行情轮询不取历史 K 线")
        await store.backfillProfitHistory()
        requests = await provider.requestedKlines()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.period, .day)
        XCTAssertEqual(requests.first?.count, 62)
        XCTAssertEqual(store.profitHistory.records.map(\.day), ["2026-10-06", "2026-10-07"])
        XCTAssertTrue(store.profitHistory.records[0].estimated)
        XCTAssertEqual(store.profitHistory.records[0].dayProfit, 50)
        XCTAssertFalse(store.profitHistory.records[1].estimated, "今天的实际收盘记录保留")
        let restored = try context.store(provider: provider, items: items)
        defer { restored.stop() }
        XCTAssertEqual(restored.profitHistory, store.profitHistory)
    }

    @MainActor
    func testHoldingEditDuringFetchDiscardsStaleEstimateAndNextOpenRetries() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = FakeQuoteProvider()
        await provider.configureKlines([symbol: bars], suspended: true)
        let store = try context.store(provider: provider, items: [WatchItem(symbol: symbol, holding: Holding(shares: 10, cost: 90))])
        defer { store.stop() }
        let task = Task { await store.backfillProfitHistory() }
        for _ in 0..<1000 {
            if !(await provider.requestedKlines()).isEmpty { break }
            await Task.yield()
        }
        XCTAssertTrue(store.isBackfillingProfitHistory)
        await store.backfillProfitHistory()
        let requests = await provider.requestedKlines()
        XCTAssertEqual(requests.count, 1, "并发打开只发一份请求")
        var changed = store.items[0]
        changed.holding?.shares = 20
        store.update(changed)
        await provider.releaseKline()
        await task.value
        XCTAssertTrue(store.profitHistory.records.isEmpty)
        XCTAssertFalse(store.isBackfillingProfitHistory)
        await store.backfillProfitHistory()
        XCTAssertEqual(store.profitHistory.records.first?.dayProfit, 100)
    }

    @MainActor
    func testClosingCalendarCancelsWriteAndMissingDataCanRetry() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = FakeQuoteProvider()
        await provider.configureKlines([symbol: bars], suspended: true)
        let store = try context.store(provider: provider, items: [WatchItem(symbol: symbol, holding: Holding(shares: 10, cost: 90))])
        defer { store.stop() }
        let task = Task { await store.backfillProfitHistory() }
        for _ in 0..<1000 {
            if !(await provider.requestedKlines()).isEmpty { break }
            await Task.yield()
        }
        task.cancel()
        await provider.releaseKline()
        await task.value
        XCTAssertTrue(store.profitHistory.records.isEmpty)
        XCTAssertFalse(store.isBackfillingProfitHistory)
        await provider.configureKlines([:])
        await store.backfillProfitHistory()
        XCTAssertTrue(store.profitHistory.records.isEmpty)
        await provider.configureKlines([symbol: bars])
        await store.backfillProfitHistory()
        XCTAssertEqual(store.profitHistory.records.count, 1)
    }
}
