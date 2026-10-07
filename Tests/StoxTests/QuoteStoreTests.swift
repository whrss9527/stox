import XCTest
import StoxCore
@testable import Stox

final class QuoteStoreTests: XCTestCase {
    @MainActor
    func testBackupCooldownReturnsToPrimaryAfter120Seconds() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let symbol = Symbol("sh600519")!
        let primary = FakeQuoteProvider(), backup = FakeQuoteProvider()
        await primary.configure(fails: true)
        await backup.configure(values: [symbol: context.quote(symbol)])
        let store = try context.store(provider: primary, backup: backup, items: [WatchItem(symbol: symbol)])
        defer { store.stop() }
        await store.refresh()
        XCTAssertTrue(store.usingBackup)
        await primary.configure(values: [symbol: context.quote(symbol, price: 115)])
        context.date.addTimeInterval(119)
        await store.refresh()
        XCTAssertTrue(store.usingBackup)
        var counts = await primary.counts()
        XCTAssertEqual(counts.quotes, 1)
        context.date.addTimeInterval(1)
        await store.refresh()
        XCTAssertFalse(store.usingBackup)
        XCTAssertEqual(store.quotes[symbol]?.price, 115)
        counts = await primary.counts()
        XCTAssertEqual(counts.quotes, 2)
        let backupCounts = await backup.counts()
        XCTAssertEqual(backupCounts.quotes, 2)
        XCTAssertEqual(store.lastUpdated, context.date)
    }

    @MainActor
    func testAlertsDoNotRepeatAfterRestartButCanFireNextTradingDay() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.settings.alertsEnabled = true
        let symbol = Symbol("sh600519")!
        let provider = FakeQuoteProvider()
        await provider.configure(values: [symbol: context.quote(symbol)])
        let item = WatchItem(symbol: symbol, alert: PriceAlert(priceAbove: 105))
        let first = try context.store(provider: provider, items: [item])
        await first.refresh()
        XCTAssertEqual(first.firedAlertCount, 1)
        first.stop()
        let restarted = try context.store(provider: provider, items: [item])
        defer { restarted.stop() }
        await restarted.refresh()
        XCTAssertEqual(restarted.firedAlertCount, 0)
        XCTAssertEqual(restarted.alertLog, first.alertLog)
        context.date.addTimeInterval(86400)
        await provider.configure(values: [symbol: context.quote(symbol)])
        await restarted.refresh()
        XCTAssertEqual(restarted.firedAlertCount, 1)
    }

    @MainActor
    func testProfitHistoryHasOneRecordPerMarketAndTradingDay() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let symbol = Symbol("sh600519")!
        let provider = FakeQuoteProvider()
        await provider.configure(values: [symbol: context.quote(symbol)])
        let item = WatchItem(symbol: symbol, holding: Holding(shares: 10, cost: 90))
        let store = try context.store(provider: provider, items: [item])
        defer { store.stop() }
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.profitHistory.records.count, 1)
        XCTAssertEqual(store.profitHistory.records.first?.day, "2026-10-07")
        context.date.addTimeInterval(86400)
        await provider.configure(values: [symbol: context.quote(symbol)])
        await store.refresh()
        XCTAssertEqual(store.profitHistory.records.count, 2)
        let reloaded = try context.store(provider: provider, items: [item])
        defer { reloaded.stop() }
        XCTAssertEqual(reloaded.profitHistory, store.profitHistory)
    }

    @MainActor
    func testPanelTasksGateExtendedQuotesAndSparklines() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.date = ISO8601DateFormatter().date(from: "2026-10-07T12:30:00Z")!
        context.settings.showExtendedHours = true
        let symbol = Symbol("usAAPL")!
        let provider = FakeQuoteProvider()
        await provider.configure(values: [symbol: context.quote(symbol)])
        let store = try context.store(provider: provider, items: [WatchItem(symbol: symbol)])
        defer { store.stop() }
        await store.refresh()
        var counts = await provider.counts()
        XCTAssertEqual(counts.extended, 0)
        XCTAssertEqual(counts.intraday, 0)
        let extended = Task { await store.trackExtendedHours() }
        for _ in 0..<1000 {
            if !context.delays.isEmpty { break }
            await Task.yield()
        }
        XCTAssertFalse(context.delays.isEmpty)
        extended.cancel()
        await extended.value
        counts = await provider.counts()
        XCTAssertEqual(counts.extended, 1)
        context.delays = []
        context.date = ISO8601DateFormatter().date(from: "2026-10-07T16:00:00Z")!
        let trading = Task { await store.trackExtendedHours() }
        for _ in 0..<1000 {
            if !context.delays.isEmpty { break }
            await Task.yield()
        }
        trading.cancel()
        await trading.value
        counts = await provider.counts()
        XCTAssertEqual(counts.extended, 1, "regular hours must not fetch extended quotes")
        context.delays = []
        let sparkline = Task { await store.trackSparklines([symbol]) }
        for _ in 0..<1000 {
            if !context.delays.isEmpty { break }
            await Task.yield()
        }
        sparkline.cancel()
        await sparkline.value
        counts = await provider.counts()
        XCTAssertEqual(counts.intraday, 1)
        // Already cancelled tasks cannot start another request.
        let closed = Task { await store.trackSparklines([symbol]) }
        closed.cancel()
        await closed.value
        let afterClose = await provider.counts()
        XCTAssertEqual(afterClose.intraday, counts.intraday)
    }
    @MainActor
    func testDisabledExtendedQuotesAndFundSparklinesMakeNoRequests() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.date = ISO8601DateFormatter().date(from: "2026-10-07T12:30:00Z")!
        context.settings.showExtendedHours = false
        let provider = FakeQuoteProvider()
        let fund = Symbol("jj110022")!
        let store = try context.store(provider: provider, items: [WatchItem(symbol: Symbol("usAAPL")!), WatchItem(symbol: fund)])
        defer { store.stop() }
        let extended = Task { await store.trackExtendedHours() }
        for _ in 0..<1000 {
            if !context.delays.isEmpty { break }
            await Task.yield()
        }
        extended.cancel()
        await extended.value
        context.delays = []
        let sparkline = Task { await store.trackSparklines([fund]) }
        for _ in 0..<1000 {
            if !context.delays.isEmpty { break }
            await Task.yield()
        }
        sparkline.cancel()
        await sparkline.value
        let counts = await provider.counts()
        XCTAssertEqual(counts.extended, 0)
        XCTAssertEqual(counts.intraday, 0)
    }

    @MainActor
    func testBothSourcesFailThenRecoveryResetsAppRetryInterval() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.settings.refreshInterval = 3
        let symbol = Symbol("sh600519")!
        let primary = FakeQuoteProvider(), backup = FakeQuoteProvider()
        await primary.configure(fails: true)
        await backup.configure(fails: true)
        let store = try context.store(provider: primary, backup: backup, items: [WatchItem(symbol: symbol)])
        defer { store.stop() }
        await store.refresh()
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.effectiveInterval, 6)
        await store.refresh()
        XCTAssertEqual(store.effectiveInterval, 12)
        await primary.configure(values: [symbol: context.quote(symbol)])
        await store.refresh()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.effectiveInterval, 3)
    }

}
