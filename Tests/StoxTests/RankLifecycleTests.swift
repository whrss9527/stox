import XCTest
import StoxCore
@testable import Stox

/// 故意在取消后仍返回，确认旧榜单请求不会覆盖当前页面。
private actor HeldRankProvider: QuoteProvider {
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var prices: [Int: Double] = [:]
    private var nextStarted: XCTestExpectation?
    private var serial = 0

    func expectNext() -> XCTestExpectation {
        let ready = XCTestExpectation(description: "rank request entered")
        nextStarted = ready
        return ready
    }
    func requestCount() -> Int { serial }
    func finish(_ id: Int, price: Double = 110, fails: Bool = false) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        prices[id] = price
        if fails { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
        else { continuation.resume() }
    }
    private func enter() async throws -> Double {
        serial += 1
        let id = serial
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            nextStarted?.fulfill()
            nextStarted = nil
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.finish(id, fails: true)
            }
        }
        return prices.removeValue(forKey: id) ?? 110
    }
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] { [:] }
    func search(_ query: String) async throws -> [SearchResult] { [] }
    func fetchRank(_ kind: RankKind, count: Int) async throws -> [RankEntry]? {
        let price = try await enter()
        return [RankEntry(symbol: Symbol("sh600519")!, name: "Fixture", price: price,
                          change: 1, changePercent: 1, amount: 100)]
    }
    func fetchIndustries(count: Int) async throws -> [IndustryEntry]? {
        [IndustryEntry(code: "fixture", name: "Fixture", changePercent: try await enter())]
    }
}

final class RankLifecycleTests: XCTestCase {
    private func started(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed)
        if result != .completed { throw NSError(domain: "RankLifecycleTests", code: 1) }
    }

    @MainActor
    func testCancelledSuccessCannotPublishRankOrIndustry() async throws {
        for kind in [RankKind.gainers, .industries] {
            let context = AppTestContext()
            defer { context.cleanup() }
            let provider = HeldRankProvider()
            let store = try context.store(provider: provider, items: [])
            let ready = await provider.expectNext()
            let task = Task { await store.loadRank(kind, count: 40) }
            defer { task.cancel(); store.stop() }
            try await started(ready)
            task.cancel()
            await provider.finish(1)
            await task.value
            XCTAssertTrue(store.rank.isEmpty)
            XCTAssertNil(store.industries)
            XCTAssertTrue(store.rankUpdated.isEmpty)
            XCTAssertNil(store.rankError)
        }
    }

    @MainActor
    func testOlderSameKindSuccessCannotReplaceNewerRank() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldRankProvider()
        let store = try context.store(provider: provider, items: [])
        let oldReady = await provider.expectNext()
        let old = Task { await store.loadRank(.gainers, count: 40) }
        defer { old.cancel(); store.stop() }
        try await started(oldReady)
        let newReady = await provider.expectNext()
        let current = Task { await store.loadRank(.gainers, count: 40) }
        defer { current.cancel() }
        try await started(newReady)
        await provider.finish(2, price: 220)
        await current.value
        let updated = store.rankUpdated[.gainers]
        context.date += 10
        await provider.finish(1, price: 100)
        await old.value
        XCTAssertEqual(store.rank[.gainers]?.first?.price, 220)
        XCTAssertEqual(store.rankUpdated[.gainers], updated)
    }

    @MainActor
    func testPreviousKindFailureCannotReplaceCurrentIndustrySuccess() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldRankProvider()
        let store = try context.store(provider: provider, items: [])
        let oldReady = await provider.expectNext()
        let old = Task { await store.loadRank(.gainers, count: 40) }
        defer { old.cancel(); store.stop() }
        try await started(oldReady)
        let newReady = await provider.expectNext()
        let current = Task { await store.loadRank(.industries, count: 40) }
        defer { current.cancel() }
        try await started(newReady)
        await provider.finish(2, price: 2)
        await current.value
        await provider.finish(1, fails: true)
        await old.value
        XCTAssertEqual(store.industries?.first?.changePercent, 2)
        XCTAssertNil(store.rankError)
        XCTAssertNil(store.rankUpdated[.gainers])
    }

    @MainActor
    func testNewKindClearsThePreviousErrorWhileLoading() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldRankProvider()
        let store = try context.store(provider: provider, items: [])
        let failedReady = await provider.expectNext()
        let failed = Task { await store.loadRank(.gainers, count: 40) }
        defer { failed.cancel(); store.stop() }
        try await started(failedReady)
        await provider.finish(1, fails: true)
        await failed.value
        XCTAssertNotNil(store.rankError)
        let nextReady = await provider.expectNext()
        let next = Task { await store.loadRank(.industries, count: 40) }
        defer { next.cancel() }
        try await started(nextReady)
        XCTAssertNil(store.rankError)
        await provider.finish(2)
        await next.value
        XCTAssertNotNil(store.industries)
    }

    @MainActor
    func testAlreadyCancelledRequestDoesNotStartNetworkWork() async throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let provider = HeldRankProvider()
        let store = try context.store(provider: provider, items: [])
        let task = Task { await store.loadRank(.gainers, count: 40) }
        task.cancel()
        await task.value
        let count = await provider.requestCount()
        XCTAssertEqual(count, 0)
    }
}
