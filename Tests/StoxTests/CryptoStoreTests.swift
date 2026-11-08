import XCTest
import StoxCore
@testable import Stox

final class CryptoStoreTests: XCTestCase {
    private let stock = Symbol("usAAPL")!
    private let bitcoin = Symbol("ccBTCUSDT")!

    @MainActor
    func testMixedFailureRetainsCryptoTimestampAndUpdatesStocks() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let stocks = FakeQuoteProvider(), crypto = FakeQuoteProvider()
        await stocks.configure(values: [stock: context.quote(stock)])
        let old = context.quote(bitcoin, price: 65000)
        await crypto.configure(values: [bitcoin: old])
        let store = try context.store(provider: stocks, cryptoProvider: crypto, items: [WatchItem(symbol: stock), WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        await store.refresh()
        XCTAssertNil(store.lastError)
        context.date.addTimeInterval(30)
        await stocks.configure(values: [stock: context.quote(stock, price: 120)])
        await crypto.configure(fails: true)
        await store.refresh()
        XCTAssertEqual(store.quotes[stock]?.price, 120)
        XCTAssertEqual(store.quotes[bitcoin], old)
        XCTAssertEqual(store.quotes[bitcoin]?.timestamp, old.timestamp)
        XCTAssertEqual(store.unavailableSymbols, [bitcoin])
        XCTAssertTrue(store.quoteIsStale(bitcoin))
        XCTAssertNotNil(store.lastError)
        await crypto.configure(values: [bitcoin: context.quote(bitcoin, price: 65100)])
        await store.refresh()
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.unavailableSymbols.isEmpty)
        XCTAssertFalse(store.quoteIsStale(bitcoin))
    }

    @MainActor
    func testCryptoSuccessDoesNotHideStockFailover() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let primary = FakeQuoteProvider(), backup = FakeQuoteProvider(), crypto = FakeQuoteProvider()
        await primary.configure(fails: true)
        await backup.configure(values: [stock: context.quote(stock)])
        await crypto.configure(values: [bitcoin: context.quote(bitcoin, price: 65000)])
        let store = try context.store(provider: primary, backup: backup, cryptoProvider: crypto,
                                      items: [WatchItem(symbol: stock), WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        await store.refresh()
        XCTAssertTrue(store.usingBackup)
        XCTAssertNotNil(store.quotes[stock])
        XCTAssertNotNil(store.quotes[bitcoin])
        XCTAssertNil(store.lastError)
        let primaryCounts = await primary.counts(), backupCounts = await backup.counts(), cryptoCounts = await crypto.counts()
        XCTAssertEqual(primaryCounts.quotes, 1)
        XCTAssertEqual(backupCounts.quotes, 1)
        XCTAssertEqual(cryptoCounts.quotes, 1)
    }

    @MainActor
    func testCryptoOnlyDoesNotCallStockSourcesAndRemainsLiveOnSunday() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.date = ISO8601DateFormatter().date(from: "2026-11-08T04:00:00Z")!
        context.settings.slowWhenIdle = true
        context.settings.refreshInterval = 5
        let stocks = FakeQuoteProvider(), backup = FakeQuoteProvider(), crypto = FakeQuoteProvider()
        await crypto.configure(values: [bitcoin: context.quote(bitcoin, price: 65000)])
        let store = try context.store(provider: stocks, backup: backup, cryptoProvider: crypto, items: [WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        await store.refresh()
        XCTAssertEqual(store.activeRegions, [.crypto])
        XCTAssertEqual(store.phase(for: .crypto), .trading)
        XCTAssertEqual(store.effectiveInterval, 5)
        XCTAssertFalse(store.usingBackup)
        let stocksCount = await stocks.counts(), backupCount = await backup.counts()
        XCTAssertEqual(stocksCount.quotes, 0)
        XCTAssertEqual(backupCount.quotes, 0)
        context.date.addTimeInterval(86400 * 7)
        XCTAssertEqual(store.phase(for: .crypto), .trading)
        XCTAssertTrue(store.quoteIsStale(bitcoin))
    }

    @MainActor
    func testStocksUnavailableStillPublishesCryptoWithWarning() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let stocks = FakeQuoteProvider(), crypto = FakeQuoteProvider()
        await stocks.configure(fails: true)
        await crypto.configure(values: [bitcoin: context.quote(bitcoin, price: 65000)])
        let store = try context.store(provider: stocks, cryptoProvider: crypto,
                                      items: [WatchItem(symbol: stock), WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        await store.refresh()
        XCTAssertEqual(store.quotes[bitcoin]?.price, 65000)
        XCTAssertNil(store.quotes[stock])
        XCTAssertEqual(store.unavailableSymbols, [stock])
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testAllSourcesFailBacksOffAndRecoveryClearsUnavailableState() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.settings.refreshInterval = 5
        let crypto = FakeQuoteProvider()
        await crypto.configure(fails: true)
        let store = try context.store(provider: FakeQuoteProvider(), cryptoProvider: crypto, items: [WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        await store.refresh()
        XCTAssertEqual(store.effectiveInterval, 10)
        await store.refresh()
        XCTAssertEqual(store.effectiveInterval, 20)
        XCTAssertEqual(store.unavailableSymbols, [bitcoin])
        await crypto.configure(values: [bitcoin: context.quote(bitcoin)])
        await store.refresh()
        XCTAssertEqual(store.effectiveInterval, 5)
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.unavailableSymbols.isEmpty)
    }

    @MainActor
    func testMissingCryptoIsNotUsedForNewAlertsAndRemoveClearsState() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.settings.alertsEnabled = false
        let crypto = FakeQuoteProvider()
        await crypto.configure(values: [bitcoin: context.quote(bitcoin)])
        let item = WatchItem(symbol: bitcoin, alert: PriceAlert(priceAbove: 105))
        let store = try context.store(provider: FakeQuoteProvider(), cryptoProvider: crypto, items: [item])
        defer { store.stop() }
        await store.refresh()
        context.settings.alertsEnabled = true
        await crypto.configure(fails: true)
        await store.refresh()
        // Even changing alert settings cannot trigger an old cached quote.
        store.update(item)
        XCTAssertEqual(store.firedAlertCount, 0)
        store.remove(bitcoin)
        XCTAssertFalse(store.unavailableSymbols.contains(bitcoin))
        XCTAssertNil(store.quotes[bitcoin])
    }

    @MainActor
    func testPreviewDoesNotPublishUnavailableOrAddCryptoToWatchlist() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let crypto = FakeQuoteProvider()
        await crypto.configure(values: [bitcoin: context.quote(bitcoin)])
        let store = try context.store(provider: FakeQuoteProvider(), cryptoProvider: crypto, items: [WatchItem(symbol: stock)])
        defer { store.stop() }
        let values = try await store.previewQuotes(for: [bitcoin])
        XCTAssertEqual(values[bitcoin]?.symbol, bitcoin)
        XCTAssertFalse(store.contains(bitcoin))
        XCTAssertTrue(store.quotes.isEmpty)
        XCTAssertTrue(store.unavailableSymbols.isEmpty)
        XCTAssertNil(store.lastUpdated)
    }

    @MainActor
    func testCryptoChartUsesCryptoProviderAndFiveDayDoesNotRequest() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let stocks = FakeQuoteProvider(), crypto = FakeQuoteProvider()
        let store = try context.store(provider: stocks, cryptoProvider: crypto, items: [WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        let task = Task { await store.trackIntraday(bitcoin) }
        for _ in 0..<1000 {
            if await crypto.counts().intraday > 0 { break }
            await Task.yield()
        }
        task.cancel()
        await task.value
        await store.trackFiveDay(bitcoin)
        let stocksCount = await stocks.counts(), cryptoCount = await crypto.counts()
        XCTAssertEqual(stocksCount.intraday, 0)
        XCTAssertEqual(cryptoCount.intraday, 1)
        XCTAssertTrue(store.fiveDay.isEmpty)
    }

    @MainActor
    func testSlowCryptoDoesNotDelayStocksAndRemovedMembershipCannotReturn() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let stocks = FakeQuoteProvider()
        await stocks.configure(values: [stock: context.quote(stock, price: 123)])
        let crypto = HeldCryptoQuotes(old: context.quote(bitcoin, price: 60000), replacement: context.quote(bitcoin, price: 65000))
        let store = try context.store(provider: stocks, cryptoProvider: crypto,
                                      items: [WatchItem(symbol: stock), WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        let first = Task { await store.refresh() }
        for _ in 0..<2000 {
            if store.quotes[stock]?.price == 123, await crypto.isHeld() { break }
            await Task.yield()
        }
        XCTAssertEqual(store.quotes[stock]?.price, 123, "快的股票行情无需等待数字货币接口超时")
        XCTAssertTrue(store.isRefreshing)
        store.remove(bitcoin)
        store.add(bitcoin)
        for _ in 0..<2000 {
            if store.quotes[bitcoin]?.price == 65000 { break }
            await Task.yield()
        }
        await crypto.release()
        await first.value
        XCTAssertEqual(store.quotes[bitcoin]?.price, 65000, "删除再添加后旧请求不能覆盖新成员的报价")
        XCTAssertFalse(store.unavailableSymbols.contains(bitcoin))
    }

    @MainActor
    func testMixedSearchNetworkFailureDoesNotMarkKnownPairAsNonexistent() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let sameTicker = Symbol("usBTC")!, unknown = Symbol("usFAKE")!
        let stocks = CryptoSearchStocks(quote: context.quote(sameTicker), other: unknown)
        let crypto = FakeQuoteProvider()
        await crypto.configure(fails: true)
        let store = try context.store(provider: stocks, cryptoProvider: crypto, items: [])
        defer { store.stop() }
        let router = PanelRouter()
        router.searchText = "BTC"
        await router.runSearch(using: store)
        XCTAssertTrue(router.searchResults.contains { $0.symbol == bitcoin })
        XCTAssertTrue(router.searchResults.contains { $0.symbol == sameTicker })
        XCTAssertFalse(router.searchResultMissing(bitcoin))
        XCTAssertTrue(router.searchResultMissing(unknown), "原股票缺报价判断保持不变")
        XCTAssertEqual(router.submissionCandidate(excluding: { _ in false })?.symbol, bitcoin)
    }

    @MainActor
    func testPartialBatchKeepsSuccessfulStocksAndReportsUnavailableCryptoAsError() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let stocks = FakeQuoteProvider(), crypto = FakeQuoteProvider()
        await stocks.configure(values: [stock: context.quote(stock)])
        await crypto.configure(fails: true)
        let store = try context.store(provider: stocks, cryptoProvider: crypto, items: [])
        defer { store.stop() }
        do {
            _ = try await store.addMany([stock, bitcoin])
            XCTFail("已知交易对接口失败应报告可重试错误，不应作为不存在的代码返回")
        } catch { XCTAssertEqual(error as? ProviderError, .emptyResponse) }
        XCTAssertTrue(store.contains(stock))
        XCTAssertFalse(store.contains(bitcoin))
    }

    @MainActor
    func testPreviewKeepsItsOwnLifetimeAcrossBackgroundRefresh() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let stocks = HeldCryptoQuotes(old: context.quote(stock, price: 120), replacement: context.quote(stock, price: 125))
        let store = try context.store(provider: stocks, items: [WatchItem(symbol: stock)])
        defer { store.stop() }
        let preview = Task { try await store.previewQuotes(for: [stock]) }
        for _ in 0..<2000 {
            if await stocks.isHeld() { break }
            await Task.yield()
        }
        await store.refresh()
        XCTAssertEqual(store.quotes[stock]?.price, 125)
        await stocks.release()
        let values = try await preview.value
        XCTAssertEqual(values[stock]?.price, 120, "独立搜索预览不能被后台轮询generation取消")
        XCTAssertEqual(store.quotes[stock]?.price, 125, "预览仍不覆盖自选实时行情")
    }

    @MainActor
    func testAutomaticCryptoRefreshKeepsClosedStocksOnIdleCadence() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.date = ISO8601DateFormatter().date(from: "2026-11-08T04:00:00Z")!
        context.settings.slowWhenIdle = true
        context.settings.refreshInterval = 5
        let stocks = FakeQuoteProvider(), crypto = FakeQuoteProvider()
        await stocks.configure(values: [stock: context.quote(stock)])
        await crypto.configure(values: [bitcoin: context.quote(bitcoin)])
        let store = try context.store(provider: stocks, cryptoProvider: crypto,
                                      items: [WatchItem(symbol: stock), WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        await store.refresh(forceStock: false)
        context.date.addTimeInterval(5)
        await store.refresh(forceStock: false)
        var stockCount = await stocks.counts(), cryptoCount = await crypto.counts()
        XCTAssertEqual(stockCount.quotes, 1)
        XCTAssertEqual(cryptoCount.quotes, 2)
        XCTAssertEqual(store.effectiveInterval, 5)
        let updated = store.lastUpdated
        context.date.addTimeInterval(5)
        await crypto.configure(fails: true)
        await store.refresh(forceStock: false)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.lastUpdated, updated, "仅复用休市缓存不能把失败的一轮标成刚更新")
        context.date.addTimeInterval(50)
        await crypto.configure(values: [bitcoin: context.quote(bitcoin)])
        await store.refresh(forceStock: false)
        stockCount = await stocks.counts()
        XCTAssertEqual(stockCount.quotes, 2)
        await store.refresh()
        stockCount = await stocks.counts()
        XCTAssertEqual(stockCount.quotes, 3, "手动刷新立即请求股票，不受闲时缓存限制")
    }

    @MainActor
    func testIdleReuseCannotTurnFailedStockQuoteIntoSuccessfulData() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.date = ISO8601DateFormatter().date(from: "2026-11-08T04:00:00Z")!
        context.settings.slowWhenIdle = true
        let stocks = FakeQuoteProvider(), crypto = FakeQuoteProvider()
        await stocks.configure(values: [stock: context.quote(stock)])
        await crypto.configure(values: [bitcoin: context.quote(bitcoin)])
        let store = try context.store(provider: stocks, cryptoProvider: crypto,
                                      items: [WatchItem(symbol: stock), WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        await store.refresh(forceStock: false)
        let timestamp = store.quotes[stock]?.timestamp
        context.date.addTimeInterval(60)
        await stocks.configure(fails: true)
        await store.refresh(forceStock: false)
        XCTAssertEqual(store.unavailableSymbols, [stock])
        context.date.addTimeInterval(5)
        await store.refresh(forceStock: false)
        let count = await stocks.counts()
        XCTAssertEqual(count.quotes, 2)
        XCTAssertEqual(store.unavailableSymbols, [stock])
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.quotes[stock]?.timestamp, timestamp)
        await stocks.configure(values: [stock: context.quote(stock)])
        await store.refresh()
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.unavailableSymbols.isEmpty)
    }

    @MainActor
    func testCancelledStockRequestDoesNotStartIdleCooldown() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.date = ISO8601DateFormatter().date(from: "2026-11-08T04:00:00Z")!
        context.settings.slowWhenIdle = true
        let stocks = CancelledStockQuotes(), crypto = FakeQuoteProvider()
        await crypto.configure(values: [bitcoin: context.quote(bitcoin)])
        let store = try context.store(provider: stocks, cryptoProvider: crypto,
                                      items: [WatchItem(symbol: stock), WatchItem(symbol: bitcoin)])
        defer { store.stop() }
        await store.refresh(forceStock: false)
        context.date.addTimeInterval(5)
        await store.refresh(forceStock: false)
        let requests = await stocks.count()
        XCTAssertEqual(requests, 2, "取消不应当作已完成的休市轮询，下一次可重新请求")
        XCTAssertNotNil(store.quotes[bitcoin])
    }
}

private actor CancelledStockQuotes: QuoteProvider {
    private var requests = 0
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        requests += 1
        throw URLError(.cancelled)
    }
    func search(_ query: String) async throws -> [SearchResult] { [] }
    func count() -> Int { requests }
}

private struct CryptoSearchStocks: QuoteProvider {
    let quote: Quote
    let other: Symbol
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        symbols.contains(quote.symbol) ? [quote.symbol: quote] : [:]
    }
    func search(_ query: String) async throws -> [SearchResult] {
        [SearchResult(symbol: quote.symbol, name: "Stock BTC", typeCode: "GP"),
         SearchResult(symbol: other, name: "Missing stock", typeCode: "GP")]
    }
}

private actor HeldCryptoQuotes: QuoteProvider {
    let old: Quote
    let replacement: Quote
    private var requests = 0
    private var hold = true
    private var waiter: CheckedContinuation<Void, Never>?
    init(old: Quote, replacement: Quote) { self.old = old; self.replacement = replacement }
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        requests += 1
        let initial = requests == 1
        if initial, hold { await withCheckedContinuation { waiter = $0 } }
        let value = initial ? old : replacement
        return symbols.contains(value.symbol) ? [value.symbol: value] : [:]
    }
    func search(_ query: String) async throws -> [SearchResult] { [] }
    func isHeld() -> Bool { waiter != nil }
    func release() { hold = false; waiter?.resume(); waiter = nil }
}
