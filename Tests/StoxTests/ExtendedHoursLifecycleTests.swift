import XCTest
import StoxCore
@testable import Stox

/// Holds responses independently of cancellation, so admission and queueing can be checked separately.
private actor HeldExtendedProvider: QuoteProvider {
    struct Pending {
        let symbol: Symbol
        let continuation: CheckedContinuation<ExtendedHoursQuote?, Error>
    }
    struct Stats {
        let started: Int
        let peak: Int
        let duplicatePeak: Int
        let symbols: [Symbol]
    }
    private var pending: [Int: Pending] = [:]
    private var requests: [Symbol] = []
    private var active: [Symbol: Int] = [:]
    private var peak = 0
    private var duplicatePeak = 0
    private var observers: [(count: Int, expectation: XCTestExpectation)] = []

    func expectStarted(_ count: Int, inverted: Bool = false) -> XCTestExpectation {
        let result = XCTestExpectation(description: "extended request count \(count)")
        result.isInverted = inverted
        if requests.count >= count { result.fulfill() }
        else { observers.append((count, result)) }
        return result
    }
    func stats() -> Stats { Stats(started: requests.count, peak: peak, duplicatePeak: duplicatePeak, symbols: requests) }
    func finish(_ id: Int, price: Double? = 110, fails: Bool = false) {
        guard let request = pending.removeValue(forKey: id) else { return }
        active[request.symbol, default: 1] -= 1
        if active[request.symbol] == 0 { active[request.symbol] = nil }
        if fails { request.continuation.resume(throwing: URLError(.cannotConnectToHost)) }
        else { request.continuation.resume(returning: price.map { ExtendedHoursQuote(session: .preMarket, price: $0) }) }
    }
    func finishPending(price: Double = 110) {
        for id in Array(pending.keys) { finish(id, price: price) }
    }
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        // Setting changes may restart ordinary polling; do not let that loop reach the test clock.
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
        return [:]
    }
    func search(_ query: String) async throws -> [SearchResult] { [] }
    func fetchExtendedHours(for symbol: Symbol, exchangeCode: String?) async throws -> ExtendedHoursQuote? {
        requests.append(symbol)
        let id = requests.count
        active[symbol, default: 0] += 1
        peak = max(peak, active.values.reduce(0, +))
        duplicatePeak = max(duplicatePeak, active[symbol]!)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(symbol: symbol, continuation: continuation)
            let ready = observers.filter { $0.count <= requests.count }
            observers.removeAll { $0.count <= requests.count }
            ready.forEach { $0.expectation.fulfill() }
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.finish(id, fails: true)
            }
        }
    }
}

final class ExtendedHoursLifecycleTests: XCTestCase {
    private let symbols = ["AAPL", "MSFT", "GOOGL", "AMZN", "META", "NVDA", "TSLA", "AMD", "INTC", "NFLX", "ORCL", "IBM"].map { Symbol("us" + $0)! }
    @MainActor private func context() -> AppTestContext {
        let context = AppTestContext()
        context.date = ISO8601DateFormatter().date(from: "2026-10-07T12:30:00Z")!
        return context
    }
    private func started(_ provider: HeldExtendedProvider, _ count: Int) async throws {
        let expectation = await provider.expectStarted(count)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed)
        if result != .completed { throw NSError(domain: "ExtendedHoursLifecycleTests", code: 1) }
    }
    private func noStart(_ provider: HeldExtendedProvider, _ count: Int) async {
        let expectation = await provider.expectStarted(count, inverted: true)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 0.2)
        XCTAssertEqual(result, .completed, "held responses must not allow another request to start")
    }
    @MainActor private func batchFinished(_ context: AppTestContext, after count: Int = 0) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while context.delays.count <= count {
            if ContinuousClock.now >= deadline { throw NSError(domain: "ExtendedHoursLifecycleTests", code: 2) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor
    func testPeakIsFourAndEveryUniqueSymbolFinishes() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let store = try context.store(provider: provider, items: symbols.map { WatchItem(symbol: $0) })
        let task = Task { await store.trackExtendedHours() }
        defer { task.cancel(); store.stop() }
        try await started(provider, 4)
        await noStart(provider, 5)
        let initial = await provider.stats()
        print("EXTENDED_PEAK held-started=\(initial.started) peak=\(initial.peak)")
        for target in [4, 8, 12] {
            try await started(provider, target)
            await provider.finishPending()
        }
        try await batchFinished(context)
        let stats = await provider.stats()
        XCTAssertEqual(stats.peak, 4)
        XCTAssertEqual(stats.started, symbols.count)
        XCTAssertEqual(Set(stats.symbols).count, symbols.count)
        XCTAssertEqual(store.extendedHours.count, symbols.count)
        task.cancel()
        await task.value
    }

    @MainActor
    func testCancellationStopsQueuedWorkAndRejectsLateSuccess() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let store = try context.store(provider: provider, items: symbols.map { WatchItem(symbol: $0) })
        let task = Task { await store.trackExtendedHours() }
        defer { task.cancel(); store.stop() }
        try await started(provider, 4)
        task.cancel()
        await provider.finishPending()
        await task.value
        let stats = await provider.stats()
        XCTAssertLessThanOrEqual(stats.started, 4)
        XCTAssertTrue(store.extendedHours.isEmpty)
    }

    @MainActor
    func testOverlappingDifferentSymbolBatchesShareTheFourSlots() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let store = try context.store(provider: provider, items: symbols.prefix(4).map { WatchItem(symbol: $0) })
        let old = Task { await store.trackExtendedHours() }
        defer { old.cancel(); store.stop() }
        try await started(provider, 4)
        let currentSymbols = Array(symbols[4..<8])
        store.replaceWatchlist(currentSymbols.map { WatchItem(symbol: $0) })
        store.stop()
        let current = Task { await store.trackExtendedHours() }
        defer { current.cancel() }
        await noStart(provider, 5)
        old.cancel()
        await provider.finishPending(price: 100)
        await old.value
        try await started(provider, 8)
        await provider.finishPending(price: 220)
        try await batchFinished(context)
        let stats = await provider.stats()
        XCTAssertEqual(stats.peak, 4, "superseded batches must not get a separate concurrency budget")
        XCTAssertEqual(Set(store.extendedHours.keys), Set(currentSymbols))
        XCTAssertEqual(Set(store.extendedHours.values.map(\.price)), [220])
        current.cancel()
        await current.value
    }

    @MainActor
    func testCanceledPermitWaitersExitWithoutStartingAndDoNotLeakSlots() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let store = try context.store(provider: provider, items: symbols.prefix(4).map { WatchItem(symbol: $0) })
        let old = Task { await store.trackExtendedHours() }
        defer { old.cancel(); store.stop() }
        try await started(provider, 4)
        store.replaceWatchlist(symbols[4..<8].map { WatchItem(symbol: $0) })
        store.stop()
        let canceledDone = XCTestExpectation(description: "permit waiters canceled")
        let canceled = Task { await store.trackExtendedHours(); canceledDone.fulfill() }
        defer { canceled.cancel() }
        await noStart(provider, 5)
        canceled.cancel()
        let result = await XCTWaiter.fulfillment(of: [canceledDone], timeout: 3)
        XCTAssertEqual(result, .completed)
        old.cancel()
        await provider.finishPending()
        await old.value
        let beforeRestart = await provider.stats()
        XCTAssertEqual(beforeRestart.started, 4)
        let current = Task { await store.trackExtendedHours() }
        defer { current.cancel() }
        try await started(provider, 8)
        await provider.finishPending()
        try await batchFinished(context)
        XCTAssertEqual(store.extendedHours.count, 4)
        current.cancel()
        await current.value
    }

    @MainActor
    func testSupersededTrackersDoNotDuplicateInFlightSymbolsOrPublishOldValues() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let items = symbols.prefix(2).map { WatchItem(symbol: $0) }
        let store = try context.store(provider: provider, items: items)
        let oldDone = XCTestExpectation(description: "superseded tracker returned")
        let old = Task { await store.trackExtendedHours(); oldDone.fulfill() }
        defer { old.cancel(); store.stop() }
        try await started(provider, 2)
        let current = Task { await store.trackExtendedHours() }
        defer { current.cancel() }
        await noStart(provider, 3)
        await provider.finish(1, price: 100)
        await provider.finish(2, price: 100)
        let result = await XCTWaiter.fulfillment(of: [oldDone], timeout: 3)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(store.extendedHours.isEmpty, "an old tracker must not publish while the new batch is held")
        old.cancel()
        await old.value
        try await started(provider, 4)
        await provider.finishPending(price: 220)
        try await batchFinished(context)
        XCTAssertEqual(Set(store.extendedHours.values.map(\.price)), [220])
        let stats = await provider.stats()
        XCTAssertEqual(stats.duplicatePeak, 1)
        current.cancel()
        await current.value
    }

    @MainActor
    func testRemovedAndReaddedSymbolCannotAcceptItsOldResponse() async throws {
        for readd in [false, true] {
            let context = context()
            defer { context.cleanup() }
            let provider = HeldExtendedProvider()
            let symbol = symbols[0]
            let item = WatchItem(symbol: symbol)
            let store = try context.store(provider: provider, items: [item])
            let task = Task { await store.trackExtendedHours() }
            defer { task.cancel(); store.stop() }
            try await started(provider, 1)
            store.remove(symbol)
            if readd { store.replaceWatchlist([item]); store.stop() }
            await provider.finishPending()
            try await batchFinished(context)
            XCTAssertTrue(store.extendedHours.isEmpty, "removed/readded membership must have a new identity")
            task.cancel()
            await task.value
        }
    }

    @MainActor
    func testRemovedQueuedSymbolNeverStarts() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let store = try context.store(provider: provider, items: symbols.prefix(8).map { WatchItem(symbol: $0) })
        let task = Task { await store.trackExtendedHours() }
        defer { task.cancel(); store.stop() }
        try await started(provider, 4)
        store.remove(symbols[4])
        await provider.finishPending()
        try await started(provider, 7)
        await provider.finishPending()
        try await batchFinished(context)
        let stats = await provider.stats()
        XCTAssertEqual(stats.started, 7)
        XCTAssertFalse(stats.symbols.contains(symbols[4]))
        XCTAssertEqual(store.extendedHours.count, 7)
        task.cancel()
        await task.value
    }

    @MainActor
    func testDuplicateWatchItemsOnlyRequestOnce() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let item = WatchItem(symbol: symbols[0])
        let store = try context.store(provider: provider, items: [item])
        store.replaceWatchlist([item, item])
        store.stop()
        let task = Task { await store.trackExtendedHours() }
        defer { task.cancel(); store.stop() }
        try await started(provider, 1)
        await noStart(provider, 2)
        await provider.finishPending()
        try await batchFinished(context)
        let stats = await provider.stats()
        XCTAssertEqual(stats.started, 1)
        task.cancel()
        await task.value
    }

    @MainActor
    func testDisableAndReenableCannotAdmitPreviousSessionResult() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let store = try context.store(provider: provider, items: [WatchItem(symbol: symbols[0])])
        let task = Task { await store.trackExtendedHours() }
        defer { task.cancel(); store.stop() }
        try await started(provider, 1)
        context.settings.showExtendedHours = false
        context.settings.showExtendedHours = true
        await provider.finishPending()
        try await batchFinished(context)
        XCTAssertTrue(store.extendedHours.isEmpty)
        task.cancel()
        await task.value
    }

    @MainActor
    func testNilClearsFailureKeepsCacheAndSuccessPreservesPrice() async throws {
        let context = context()
        defer { context.cleanup() }
        let provider = HeldExtendedProvider()
        let store = try context.store(provider: provider, items: symbols.prefix(3).map { WatchItem(symbol: $0) })
        let first = Task { await store.trackExtendedHours() }
        defer { first.cancel(); store.stop() }
        try await started(provider, 3)
        await provider.finishPending(price: 100)
        try await batchFinished(context)
        first.cancel()
        await first.value
        let delayCount = context.delays.count
        let current = Task { await store.trackExtendedHours() }
        defer { current.cancel() }
        try await started(provider, 6)
        let stats = await provider.stats()
        for id in 4...6 {
            let symbol = stats.symbols[id - 1]
            if symbol == symbols[0] { await provider.finish(id, price: nil) }
            else if symbol == symbols[1] { await provider.finish(id, fails: true) }
            else { await provider.finish(id, price: 220) }
        }
        try await batchFinished(context, after: delayCount)
        XCTAssertNil(store.extendedHours[symbols[0]])
        XCTAssertEqual(store.extendedHours[symbols[1]]?.price, 100)
        XCTAssertEqual(store.extendedHours[symbols[2]], ExtendedHoursQuote(session: .preMarket, price: 220))
        current.cancel()
        await current.value
    }
}
