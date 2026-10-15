import XCTest
import StoxCore
@testable import Stox

/// Deliberately returns after cancellation, as a network dependency may do.
private actor HeldChartProvider: QuoteProvider {
    enum Kind: Hashable, Sendable {
        case intraday, fiveDay, fundFlow
        case kline(KlinePeriod)
    }
    struct Request {
        let kind: Kind
        let symbol: Symbol
        let continuation: CheckedContinuation<Void, Error>
    }
    private var requests: [Int: Request] = [:]
    private var nextStarted: XCTestExpectation?
    private var serial = 0
    private var prices: [Int: Double] = [:]

    func expectNext() -> XCTestExpectation {
        let started = XCTestExpectation(description: "chart provider entered")
        nextStarted = started
        return started
    }
    func latestID() -> Int { serial }
    func finish(_ id: Int, price: Double = 110, fails: Bool = false) {
        guard let request = requests.removeValue(forKey: id) else { return }
        prices[id] = price
        if fails { request.continuation.resume(throwing: URLError(.cannotConnectToHost)) }
        else { request.continuation.resume() }
    }
    private func enter(_ kind: Kind, _ symbol: Symbol) async throws -> Double {
        serial += 1
        let id = serial
        try await withCheckedThrowingContinuation { continuation in
            requests[id] = Request(kind: kind, symbol: symbol, continuation: continuation)
            nextStarted?.fulfill()
            nextStarted = nil
            // A failed assertion cannot leave a test task suspended indefinitely.
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.finish(id, fails: true)
            }
        }
        return prices.removeValue(forKey: id) ?? 110
    }
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] { [:] }
    func search(_ query: String) async throws -> [SearchResult] { [] }
    func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries? {
        Self.series(symbol, price: try await enter(.intraday, symbol))
    }
    func fetchKline(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String?) async throws -> KlineSeries? {
        let price = try await enter(.kline(period), symbol)
        return KlineSeries(symbol: symbol, period: period, candles: [
            Candle(date: "2026-10-07", open: price, close: price, high: price, low: price),
        ])
    }
    func fetchFiveDay(for symbol: Symbol, exchangeCode: String?) async throws -> MultiDaySeries? {
        let series = Self.series(symbol, price: try await enter(.fiveDay, symbol))
        return MultiDaySeries(symbol: symbol, days: [series], previousClose: 100, dayPreviousCloses: [100])
    }
    func fetchFundFlow(for symbol: Symbol) async throws -> FundFlow? {
        FundFlow(mainNetInflow: try await enter(.fundFlow, symbol))
    }
    nonisolated static func series(_ symbol: Symbol, price: Double) -> IntradaySeries {
        IntradaySeries(symbol: symbol, date: "20261007", points: [
            IntradayPoint(minute: 570, price: price), IntradayPoint(minute: 575, price: price + 1),
        ])
    }
}

final class ChartLifecycleTests: XCTestCase {
    private let first = Symbol("sh600519")!
    private let second = Symbol("sz000001")!

    @MainActor
    private func launch(_ kind: HeldChartProvider.Kind, symbol: Symbol, store: QuoteStore) -> Task<Void, Never> {
        Task {
            switch kind {
            case .intraday: await store.trackIntraday(symbol)
            case .kline(let period): await store.trackKline(symbol, period: period)
            case .fiveDay: await store.trackFiveDay(symbol)
            case .fundFlow: await store.trackFundFlow(symbol)
            }
        }
    }
    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            if ContinuousClock.now >= deadline { throw NSError(domain: "ChartLifecycleTests", code: 1) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private func started(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed)
        if result != .completed { throw NSError(domain: "ChartLifecycleTests", code: 2) }
    }

    @MainActor
    func testCanceledChartSuccessCannotPublishAnyChartOrLoadedState() async throws {
        for kind in [HeldChartProvider.Kind.intraday, .kline(.day), .fiveDay, .fundFlow] {
            let context = AppTestContext()
            defer { context.cleanup() }
            let provider = HeldChartProvider()
            let store = try context.store(provider: provider, items: [WatchItem(symbol: first)])
            let ready = await provider.expectNext()
            let task = launch(kind, symbol: first, store: store)
            defer { task.cancel(); store.stop() }
            try await started(ready)
            let id = await provider.latestID()
            task.cancel()
            await provider.finish(id)
            await task.value
            XCTAssertTrue(store.intraday.isEmpty)
            XCTAssertTrue(store.klines.isEmpty)
            XCTAssertTrue(store.fiveDay.isEmpty)
            XCTAssertTrue(store.fundFlows.isEmpty)
            XCTAssertTrue(store.fundFlowLoaded.isEmpty)
            XCTAssertTrue(store.sparklines.isEmpty)
        }
    }

    @MainActor
    func testCanceledFundErrorDoesNotMarkNewSessionLoaded() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldChartProvider()
        let store = try context.store(provider: provider, items: [WatchItem(symbol: first)])
        let oldReady = await provider.expectNext()
        let old = launch(.fundFlow, symbol: first, store: store)
        defer { old.cancel(); store.stop() }
        try await started(oldReady)
        let oldID = await provider.latestID()
        old.cancel()
        let newReady = await provider.expectNext()
        let current = launch(.fundFlow, symbol: first, store: store)
        defer { current.cancel() }
        try await started(newReady)
        let newID = await provider.latestID()
        await provider.finish(oldID, fails: true)
        await old.value
        XCTAssertTrue(store.fundFlowLoaded.isEmpty)
        await provider.finish(newID, price: 220)
        try await waitUntil { store.fundFlowLoaded.contains(first) }
        XCTAssertEqual(store.fundFlows[first]?.mainNetInflow, 220)
        current.cancel()
        await current.value
    }

    @MainActor
    func testReplacingWatchlistRejectsHeldResultsWithoutCancellation() async throws {
        for kind in [HeldChartProvider.Kind.intraday, .kline(.day), .fiveDay, .fundFlow] {
            let context = AppTestContext()
            defer { context.cleanup() }
            let provider = HeldChartProvider()
            let store = try context.store(provider: provider, items: [WatchItem(symbol: first)])
            let ready = await provider.expectNext()
            let task = launch(kind, symbol: first, store: store)
            defer { task.cancel(); store.stop() }
            try await started(ready)
            let id = await provider.latestID()
            store.replaceWatchlist([WatchItem(symbol: second)])
            store.stop()
            await provider.finish(id)
            await task.value
            XCTAssertTrue(store.intraday.isEmpty)
            XCTAssertTrue(store.klines.isEmpty)
            XCTAssertTrue(store.fiveDay.isEmpty)
            XCTAssertTrue(store.fundFlows.isEmpty)
            XCTAssertTrue(store.fundFlowLoaded.isEmpty)
            XCTAssertTrue(store.sparklines.isEmpty)
        }
    }

    @MainActor
    func testNewOwnerSurvivesOldReturnAndOldDefer() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldChartProvider()
        let store = try context.store(provider: provider, items: [WatchItem(symbol: first)])
        let oldReady = await provider.expectNext()
        let old = launch(.intraday, symbol: first, store: store)
        defer { old.cancel(); store.stop() }
        try await started(oldReady)
        let oldID = await provider.latestID()
        let newReady = await provider.expectNext()
        let current = launch(.intraday, symbol: first, store: store)
        defer { current.cancel() }
        try await started(newReady)
        let newID = await provider.latestID()
        // Old task is not canceled: ownership alone must reject its return.
        await provider.finish(oldID, price: 100)
        await old.value
        XCTAssertTrue(store.intraday.isEmpty)
        await provider.finish(newID, price: 220)
        try await waitUntil { store.intraday[first] != nil }
        XCTAssertEqual(store.intraday[first]?.points.first?.price, 220)
        current.cancel()
        await current.value
    }

    @MainActor
    func testCanceledSparklineErrorDoesNotSuppressTheNextFetch() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldChartProvider()
        let store = try context.store(provider: provider, items: [WatchItem(symbol: first)])
        let oldReady = await provider.expectNext()
        let old = Task { await store.trackSparklines([first]) }
        defer { old.cancel(); store.stop() }
        try await started(oldReady)
        let oldID = await provider.latestID()
        old.cancel()
        await provider.finish(oldID, fails: true)
        await old.value
        let newReady = await provider.expectNext()
        let current = Task { await store.trackSparklines([first]) }
        defer { current.cancel() }
        try await started(newReady) // A stale fetched timestamp would skip this request.
        let newID = await provider.latestID()
        await provider.finish(newID)
        try await waitUntil { store.sparklines[first] != nil }
        current.cancel()
        await current.value
    }

    @MainActor
    func testRemoveAndReaddCannotReviveOldOwner() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldChartProvider()
        let item = WatchItem(symbol: first)
        let store = try context.store(provider: provider, items: [item])
        let ready = await provider.expectNext()
        let old = launch(.intraday, symbol: first, store: store)
        defer { old.cancel(); store.stop() }
        try await started(ready)
        let oldID = await provider.latestID()
        store.remove(first)
        store.replaceWatchlist([item])
        store.stop()
        let newReady = await provider.expectNext()
        let current = launch(.intraday, symbol: first, store: store)
        defer { current.cancel() }
        try await started(newReady)
        let newID = await provider.latestID()
        await provider.finish(newID, price: 220)
        try await waitUntil { store.intraday[first] != nil }
        await provider.finish(oldID, price: 100)
        await old.value
        XCTAssertEqual(store.intraday[first]?.points.first?.price, 220)
        current.cancel()
        await current.value
    }

    @MainActor
    func testKindsAndKlinePeriodsHaveIndependentOwners() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldChartProvider()
        let store = try context.store(provider: provider, items: [WatchItem(symbol: first)])
        var tasks: [Task<Void, Never>] = []
        defer { tasks.forEach { $0.cancel() }; store.stop() }
        var ids: [Int] = []
        for kind in [HeldChartProvider.Kind.intraday, .kline(.day), .kline(.week), .fiveDay, .fundFlow] {
            let ready = await provider.expectNext()
            tasks.append(launch(kind, symbol: first, store: store))
            try await started(ready)
            ids.append(await provider.latestID())
        }
        for id in ids { await provider.finish(id) }
        try await waitUntil {
            store.intraday[first] != nil && store.klines.count == 2 && store.fiveDay[first] != nil && store.fundFlowLoaded.contains(first)
        }
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }

    @MainActor
    func testReplacingDisjointListsPrunesEveryChartButReorderKeepsMembers() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldChartProvider()
        let items = [WatchItem(symbol: first), WatchItem(symbol: second)]
        let store = try context.store(provider: provider, items: items)
        defer { store.stop() }
        for symbol in [first, second] {
            for kind in [HeldChartProvider.Kind.intraday, .kline(.day), .fiveDay, .fundFlow] {
                let ready = await provider.expectNext()
                let task = launch(kind, symbol: symbol, store: store)
                defer { task.cancel() }
                try await started(ready)
                await provider.finish(await provider.latestID())
                try await waitUntil { !context.delays.isEmpty }
                task.cancel()
                await task.value
                context.delays = []
            }
        }
        XCTAssertEqual(store.sparklines.count, 2)
        store.replaceWatchlist(Array(items.reversed()))
        store.stop()
        XCTAssertEqual(store.intraday.count, 2)
        XCTAssertEqual(store.klines.count, 2)
        XCTAssertEqual(store.fiveDay.count, 2)
        XCTAssertEqual(store.fundFlowLoaded.count, 2)
        store.replaceWatchlist([items[1]])
        store.stop()
        XCTAssertEqual(Set(store.intraday.keys), [second])
        XCTAssertEqual(Set(store.klines.keys.map(\.symbol)), [second])
        XCTAssertEqual(Set(store.fiveDay.keys), [second])
        XCTAssertEqual(Set(store.fundFlows.keys), [second])
        XCTAssertEqual(store.fundFlowLoaded, [second])
        XCTAssertEqual(Set(store.sparklines.keys), [second])
        for symbol in [first, second, first] {
            store.replaceWatchlist([WatchItem(symbol: symbol)])
            store.stop()
            XCTAssertTrue(store.intraday.isEmpty)
            XCTAssertTrue(store.klines.isEmpty)
            XCTAssertTrue(store.fiveDay.isEmpty)
            XCTAssertTrue(store.fundFlows.isEmpty)
            XCTAssertTrue(store.fundFlowLoaded.isEmpty)
            XCTAssertTrue(store.sparklines.isEmpty)
        }
        // No private-state assertion: pruning fetched metadata allows immediate reload.
        let ready = await provider.expectNext()
        let task = Task { await store.trackSparklines([first]) }
        defer { task.cancel() }
        try await started(ready)
        await provider.finish(await provider.latestID())
        try await waitUntil { store.sparklines[first] != nil }
        task.cancel()
        await task.value
    }
}
