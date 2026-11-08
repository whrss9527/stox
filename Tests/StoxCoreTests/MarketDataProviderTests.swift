import XCTest
@testable import StoxCore

final class MarketDataProviderTests: XCTestCase {
    private let stock = Symbol("usBTC")!
    private let coin = Symbol(market: .crypto, code: "BTCUSDT")!

    private func quote(_ symbol: Symbol) -> Quote {
        Quote(symbol: symbol, name: symbol.code, price: 100, previousClose: 90)
    }

    func testEachMarketOnlyReceivesItsOwnSymbolsAndMergesResults() async throws {
        let a = RoutingTestProvider(), b = RoutingTestProvider()
        await a.configure(quotes: [stock: quote(stock)])
        await b.configure(quotes: [coin: quote(coin)])
        let result = try await MarketDataProvider(stock: a, crypto: b).fetchQuotes(for: [stock, coin, stock])
        XCTAssertEqual(Set(result.keys), [stock, coin])
        let stockRequests = await a.requested(), cryptoRequests = await b.requested()
        XCTAssertEqual(stockRequests, [[stock]])
        XCTAssertEqual(cryptoRequests, [[coin]])
    }

    func testMarketRequestsActuallyRunConcurrently() async throws {
        let gate = RoutingGate()
        let a = RoutingTestProvider(gate: gate), b = RoutingTestProvider(gate: gate)
        await a.configure(quotes: [stock: quote(stock)]); await b.configure(quotes: [coin: quote(coin)])
        let provider = MarketDataProvider(stock: a, crypto: b), symbols = [stock, coin]
        let task = Task { try await provider.fetchQuotes(for: symbols) }
        await gate.waitForBoth()
        await gate.release()
        let result = try await task.value
        XCTAssertEqual(result.count, 2)
    }

    func testOneMarketFailureRetainsOtherMarketAndAllFailureThrowsRealError() async throws {
        let a = RoutingTestProvider(), b = RoutingTestProvider()
        await a.configure(error: .badStatus(503)); await b.configure(quotes: [coin: quote(coin)])
        let provider = MarketDataProvider(stock: a, crypto: b)
        let result = try await provider.fetchQuotes(for: [stock, coin])
        XCTAssertEqual(Set(result.keys), [coin])
        await b.configure(error: .badStatus(503))
        do { _ = try await provider.fetchQuotes(for: [stock, coin]); XCTFail() }
        catch { XCTAssertEqual(error as? ProviderError, .badStatus(503)) }
    }

    func testCancellationWinsOverPartialSuccess() async throws {
        let a = RoutingTestProvider(), b = RoutingTestProvider()
        await a.cancelRequests(); await b.configure(quotes: [coin: quote(coin)])
        do { _ = try await MarketDataProvider(stock: a, crypto: b).fetchQuotes(for: [stock, coin]); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testExplicitPairSearchNeverWaitsForStockNetwork() async throws {
        let a = RoutingTestProvider(), provider = MarketDataProvider(stock: a, crypto: RoutingTestProvider())
        for input in ["BTCUSDT", "BTC/USDT", "ccBTCUSDT", "BTC / USDT"] {
            let result = try await provider.search(input)
            XCTAssertEqual(result.map(\.symbol), [coin])
        }
        let calls = await a.searchCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testBareTickerSearchKeepsCryptoAndSameNamedStock() async throws {
        let a = RoutingTestProvider()
        await a.setSearch([SearchResult(symbol: stock, name: "BTC stock", typeCode: "GP")])
        let result = try await MarketDataProvider(stock: a, crypto: RoutingTestProvider()).search("BTC")
        XCTAssertEqual(result.map(\.symbol), [coin, stock])
        let calls = await a.searchCalls(); XCTAssertEqual(calls, ["BTC"])
    }

    func testStockSearchErrorPreservesLocalCryptoButCancellationDoesNot() async throws {
        let a = RoutingTestProvider(); await a.configure(error: .badStatus(500))
        let provider = MarketDataProvider(stock: a, crypto: RoutingTestProvider())
        let result = try await provider.search("Bitcoin"); XCTAssertEqual(result.map(\.symbol), [coin])
        do { _ = try await provider.search("not-a-crypto"); XCTFail() } catch { XCTAssertEqual(error as? ProviderError, .badStatus(500)) }
        await a.cancelRequests()
        do { _ = try await provider.search("BTC"); XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAllOtherProtocolMethodsForwardWithoutSendingCryptoToStocks() async throws {
        let a = RoutingTestProvider(), b = RoutingTestProvider(), provider = MarketDataProvider(stock: a, crypto: b)
        _ = try await provider.fetchIntraday(for: coin)
        _ = try await provider.fetchKline(for: coin, period: .week, count: 40, exchangeCode: "ignored")
        _ = try await provider.fetchFiveDay(for: coin, exchangeCode: nil)
        _ = try await provider.fetchExtendedHours(for: coin, exchangeCode: nil)
        _ = try await provider.fetchFundFlow(for: coin)
        let none = await a.methods(); XCTAssertTrue(none.isEmpty)
        let cryptoMethods = await b.methods(); XCTAssertEqual(cryptoMethods, ["intraday:ccBTCUSDT", "kline:ccBTCUSDT:week:40:ignored"])
        _ = try await provider.fetchIntraday(for: stock)
        _ = try await provider.fetchKline(for: stock, period: .day, count: 30, exchangeCode: "BTC.N")
        _ = try await provider.fetchExchangeRates()
        _ = try await provider.fetchFiveDay(for: stock, exchangeCode: "BTC.N")
        _ = try await provider.fetchExtendedHours(for: stock, exchangeCode: "BTC.N")
        _ = try await provider.fetchFundFlow(for: stock)
        _ = try await provider.fetchRank(.gainers, count: 10)
        _ = try await provider.fetchIndustries(count: 5)
        let methods = await a.methods()
        XCTAssertEqual(methods, ["intraday:usBTC", "kline:usBTC:day:30:BTC.N", "rates", "five:usBTC:BTC.N", "extended:usBTC:BTC.N", "flow:usBTC", "rank:10", "industries:5"])
    }
}

private actor RoutingTestProvider: QuoteProvider {
    private var values: [Symbol: Quote] = [:]
    private var error: ProviderError?
    private var cancelled = false
    private var symbols: [[Symbol]] = []
    private var searches: [String] = []
    private var searchResults: [SearchResult] = []
    private var calls: [String] = []
    private let gate: RoutingGate?
    init(gate: RoutingGate? = nil) { self.gate = gate }
    func configure(quotes: [Symbol: Quote] = [:], error: ProviderError? = nil) { values = quotes; self.error = error }
    func cancelRequests() { cancelled = true }
    func setSearch(_ values: [SearchResult]) { searchResults = values }
    func requested() -> [[Symbol]] { symbols }
    func searchCalls() -> [String] { searches }
    func methods() -> [String] { calls }
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        self.symbols.append(symbols)
        if let gate { await gate.arrive() }
        if cancelled { throw CancellationError() }
        if let error { throw error }
        return values
    }
    func search(_ query: String) async throws -> [SearchResult] {
        searches.append(query)
        if cancelled { throw CancellationError() }
        if let error { throw error }
        return searchResults
    }
    func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries? { calls.append("intraday:" + symbol.rawValue); return nil }
    func fetchKline(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String?) async throws -> KlineSeries? { calls.append("kline:\(symbol.rawValue):\(period.rawValue):\(count):\(exchangeCode ?? "nil")"); return nil }
    func fetchExchangeRates() async throws -> ExchangeRates? { calls.append("rates"); return nil }
    func fetchFiveDay(for symbol: Symbol, exchangeCode: String?) async throws -> MultiDaySeries? { calls.append("five:\(symbol.rawValue):\(exchangeCode ?? "nil")"); return nil }
    func fetchExtendedHours(for symbol: Symbol, exchangeCode: String?) async throws -> ExtendedHoursQuote? { calls.append("extended:\(symbol.rawValue):\(exchangeCode ?? "nil")"); return nil }
    func fetchFundFlow(for symbol: Symbol) async throws -> FundFlow? { calls.append("flow:" + symbol.rawValue); return nil }
    func fetchRank(_ kind: RankKind, count: Int) async throws -> [RankEntry]? { calls.append("rank:\(count)"); return nil }
    func fetchIndustries(count: Int) async throws -> [IndustryEntry]? { calls.append("industries:\(count)"); return nil }
}

private actor RoutingGate {
    private var count = 0
    private var observer: CheckedContinuation<Void, Never>?
    private var held: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        count += 1
        if count == 2 { observer?.resume(); observer = nil }
        await withCheckedContinuation { held.append($0) }
    }
    func waitForBoth() async {
        if count >= 2 { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { for continuation in held { continuation.resume() }; held.removeAll() }
}
