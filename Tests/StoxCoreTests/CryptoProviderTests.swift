import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StoxCore

/// 下列行都是离线构造的边界资料，不冒充真实交易所抓取样本。
final class CryptoProviderTests: XCTestCase {
    private let btc = Symbol(market: .crypto, code: "BTCUSDT")!
    private let eth = Symbol(market: .crypto, code: "ETHUSDT")!
    private static let at = Date(timeIntervalSince1970: 1_794_096_000)

    private func session(_ handler: @escaping CryptoTestProtocol.Handler) -> (session: URLSession, port: Int) {
        let port = CryptoTestProtocol.registry.add(handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CryptoTestProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); CryptoTestProtocol.registry.remove(port) }
        return (session, port)
    }

    private func provider(_ handler: @escaping CryptoTestProtocol.Handler, clock: CryptoTestClock? = nil,
                          chartConcurrency: Int = 3, fallback: Bool = true) -> CryptoProvider {
        let date = Self.at
        let fixture = session(handler)
        func endpoint(_ original: URL) -> URL {
            var components = URLComponents(url: original, resolvingAgainstBaseURL: false)!
            components.port = fixture.port
            return components.url!
        }
        return CryptoProvider(session: fixture.session, timeout: 80, baseURL: endpoint(CryptoProvider.endpoint),
            fallbackURL: fallback ? endpoint(CryptoProvider.fallbackEndpoint) : nil,
            now: { clock?.now() ?? date }, chartConcurrency: chartConcurrency)
    }

    static func ticker(_ code: String = "BTCUSDT", price: String = "100.125", at: Date = CryptoProviderTests.at) -> [String: Any] {
        ["symbol": code, "lastPrice": price, "openPrice": "100", "highPrice": "110", "lowPrice": "90",
         "priceChange": "0.125", "priceChangePercent": "0.125", "volume": "12.5", "quoteVolume": "1251.25",
         "openTime": Int64(at.addingTimeInterval(-86_400).timeIntervalSince1970 * 1000),
         "closeTime": Int64(at.timeIntervalSince1970 * 1000)]
    }

    static func data(_ rows: Any) -> Data { try! JSONSerialization.data(withJSONObject: rows) }
    static func bar(open: Date, duration: TimeInterval = 300, price: String = "100.125") -> [Any] {
        [Int64(open.timeIntervalSince1970 * 1000), "100", "110", "90", price, "12.5",
         Int64(open.addingTimeInterval(duration).timeIntervalSince1970 * 1000) - 1, "1251.25", 10]
    }

    func testRealBinanceTickerSnapshotPreserves24hBasisAndExchangeTime() throws {
        // 原样采集于2026-11-08T06:37:55Z：生产provider主源HTTP200，SHA256见维护记录。
        let url = try XCTUnwrap(Bundle.module.url(forResource: "crypto-ticker-20261108", withExtension: "json", subdirectory: "Fixtures"))
        let sampled = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-08T06:37:55Z"))
        let quotes = CryptoQuoteParser.parse(try Data(contentsOf: url), symbols: [btc, eth], now: sampled)
        XCTAssertEqual(quotes.count, 2)
        let bitcoin = try XCTUnwrap(quotes[btc]), ethereum = try XCTUnwrap(quotes[eth])
        XCTAssertEqual(bitcoin.price, 75839.30, accuracy: 0.000001)
        XCTAssertEqual(bitcoin.previousClose, 76039.69, accuracy: 0.000001)
        XCTAssertEqual(bitcoin.open, bitcoin.previousClose)
        XCTAssertNotEqual(bitcoin.previousClose, 76039.68, "API prevClosePrice不是滚动24h openPrice")
        XCTAssertEqual(bitcoin.change, -200.39, accuracy: 0.000001)
        XCTAssertEqual(bitcoin.changePercent, -0.264, accuracy: 0.000001)
        XCTAssertEqual(ethereum.price, 2234.89, accuracy: 0.000001)
        XCTAssertEqual(ethereum.previousClose, 2246.69, accuracy: 0.000001)
        XCTAssertEqual(ethereum.change, -11.80, accuracy: 0.000001)
        XCTAssertEqual(ethereum.changePercent, -0.525, accuracy: 0.000001)
        XCTAssertEqual(Int64((try XCTUnwrap(bitcoin.timestamp).timeIntervalSince1970 * 1000).rounded()), 1_794_119_875_001)
        XCTAssertEqual(Int64((try XCTUnwrap(ethereum.timestamp).timeIntervalSince1970 * 1000).rounded()), 1_794_119_875_013)
    }

    func testTickerBatchesOnlyUniqueRequestedPairsAndUsesEightSecondTimeout() async throws {
        let calls = CryptoTestCalls()
        let provider = provider { request in
            calls.record(request)
            request.reply(Self.data([Self.ticker(), Self.ticker("ETHUSDT")]))
        }
        let quotes = try await provider.fetchQuotes(for: [btc, eth, btc, Symbol("usBTC")!])
        XCTAssertEqual(Set(quotes.keys), Set([btc, eth]))
        XCTAssertEqual(calls.requests.count, 1)
        let request = try XCTUnwrap(calls.requests.first)
        XCTAssertEqual(request.timeoutInterval, 8)
        XCTAssertEqual(request.url?.host, "data-api.binance.vision")
        XCTAssertEqual(request.url?.path, "/api/v3/ticker/24hr")
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(values["symbols"]!.utf8)) as? [String], ["BTCUSDT", "ETHUSDT"])
        XCTAssertEqual(values["type"], "FULL")
        let quote = try XCTUnwrap(quotes[btc])
        XCTAssertEqual(quote.previousClose, 100, "这是滚动24h开盘基准，不是API prevClosePrice")
        XCTAssertEqual(quote.volume, 12.5)
        XCTAssertEqual(quote.amount, 1251.25)
        XCTAssertEqual(quote.timestamp, Self.at)
        XCTAssertEqual(quote.priceDecimals, 4)
    }

    func testNoSymbolsAndStockOnlyDoNotMakeNetworkRequests() async throws {
        let calls = CryptoTestCalls()
        let provider = provider { request in calls.record(request); request.reply(Data()) }
        let empty = try await provider.fetchQuotes(for: [])
        let stocks = try await provider.fetchQuotes(for: [Symbol("usBTC")!])
        let chart = try await provider.fetchIntraday(for: Symbol("usBTC")!)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(stocks.isEmpty)
        XCTAssertNil(chart)
        XCTAssertEqual(calls.requests.count, 0)
    }

    func testBadIndividualTickerDoesNotDiscardGoodRecords() async throws {
        var bad = Self.ticker("ETHUSDT"); bad["lastPrice"] = "nan"
        let body = Self.data([Self.ticker(), bad, "broken record", Self.ticker("NOTREQUESTED")] as [Any])
        let provider = provider { $0.reply(body) }
        let quotes = try await provider.fetchQuotes(for: [btc, eth])
        XCTAssertEqual(Set(quotes.keys), [btc])
    }

    func testRejectsNonfiniteNegativeWrongSymbolAndBadTimestamps() {
        for (field, value) in [("lastPrice", "nan"), ("lastPrice", "inf"), ("lastPrice", "-1"),
                               ("quoteVolume", "1e999"), ("volume", "-1"), ("priceChange", "nan"),
                               ("priceChangePercent", "inf"), ("highPrice", "0"), ("closeTime", "nan"),
                               ("closeTime", "0"), ("symbol", "btcusdt")] {
            var row = Self.ticker(); row[field] = value
            XCTAssertTrue(CryptoQuoteParser.parse(Self.data([row]), symbols: [btc], now: Self.at).isEmpty, field + value)
        }
        var row = Self.ticker(); row["closeTime"] = true
        XCTAssertTrue(CryptoQuoteParser.parse(Self.data([row]), symbols: [btc], now: Self.at).isEmpty)
        row = Self.ticker(); row["closeTime"] = Int64(Self.at.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        XCTAssertTrue(CryptoQuoteParser.parse(Self.data([row]), symbols: [btc], now: Self.at).isEmpty)
    }

    func testInvalidBodyDoesNotTryAnotherHostAndEntersCooldown() async throws {
        let calls = CryptoTestCalls()
        let provider = provider { request in calls.record(request); request.reply(Data("not JSON".utf8)) }
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() } catch { XCTAssertEqual(error as? ProviderError, .emptyResponse) }
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() } catch { XCTAssertNotNil(error as? CryptoProviderError) }
        XCTAssertEqual(calls.requests.count, 1)
    }

    func testFallbackRemembersHealthyBinanceHost() async throws {
        let calls = CryptoTestCalls()
        let provider = provider { request in
            calls.record(request)
            if request.request.url?.host == "data-api.binance.vision" { request.fail(URLError(.timedOut)) }
            else { request.reply(Self.data([Self.ticker()])) }
        }
        _ = try await provider.fetchQuotes(for: [btc])
        _ = try await provider.fetchQuotes(for: [btc])
        XCTAssertEqual(calls.requests.map { $0.url?.host }, ["data-api.binance.vision", "api.binance.com", "api.binance.com"])
        XCTAssertTrue(calls.requests.allSatisfy { $0.timeoutInterval <= 8 })
    }

    func testRateLimitHasNoFallbackAndBlocksOtherScopesUntilRetryAfter() async throws {
        let clock = CryptoTestClock(Self.at), calls = CryptoTestCalls()
        let provider = provider({ request in
            let index = calls.record(request)
            if index == 1 { request.reply(Data("{}".utf8), status: 429, headers: ["Retry-After": "120"]) }
            else { request.reply(Self.data([Self.ticker(at: clock.now())])) }
        }, clock: clock)
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() } catch { XCTAssertEqual(error as? ProviderError, .badStatus(429)) }
        clock.advance(119)
        do { _ = try await provider.fetchIntraday(for: eth); XCTFail() }
        catch { XCTAssertEqual(error as? CryptoProviderError, .cooldown(until: Self.at.addingTimeInterval(120))) }
        XCTAssertEqual(calls.requests.count, 1)
        clock.advance(2)
        _ = try await provider.fetchQuotes(for: [btc])
        XCTAssertEqual(calls.requests.count, 2)
    }

    func testRetryAfterHTTPDateAndInvalidValuesAreBounded() {
        XCTAssertEqual(CryptoProvider.retryDelay("259200", now: Self.at), 259_200)
        XCTAssertEqual(CryptoProvider.retryDelay("Wed, 11 Nov 2026 00:00:00 GMT", now: Self.at), 259_200)
        XCTAssertEqual(CryptoProvider.retryDelay("Wed, 01 Jan 2031 00:00:00 GMT", now: Self.at), 259_200)
        XCTAssertEqual(CryptoProvider.retryDelay("nan", now: Self.at), 60)
        XCTAssertEqual(CryptoProvider.retryDelay("-3", now: Self.at), 60)
        XCTAssertEqual(CryptoProvider.retryDelay("1e100", now: Self.at), 259_200)
        XCTAssertEqual(CryptoProvider.retryDelay("0", now: Self.at), 1)
    }

    func testOrdinaryFailureBacksOffAndSuccessResetsFailureCount() async throws {
        let clock = CryptoTestClock(Self.at), calls = CryptoTestCalls()
        let provider = provider({ request in
            let n = calls.record(request)
            if n == 2 { request.reply(Self.data([Self.ticker(at: clock.now())])) }
            else { request.reply(Data("{}".utf8), status: 503) }
        }, clock: clock, fallback: false)
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() } catch { }
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() } catch { }
        XCTAssertEqual(calls.requests.count, 1)
        clock.advance(6)
        _ = try await provider.fetchQuotes(for: [btc])
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() } catch { }
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() }
        catch { XCTAssertEqual(error as? CryptoProviderError, .cooldown(until: clock.now().addingTimeInterval(5))) }
    }

    func testCancellationStopsDataTaskWithoutFallbackOrCooldown() async throws {
        let started = expectation(description: "HTTP started"), stopped = expectation(description: "HTTP cancelled")
        let calls = CryptoTestCalls()
        let provider = provider { request in
            let n = calls.record(request)
            if n == 1 { request.onStop = { stopped.fulfill() }; started.fulfill() }
            else { request.reply(Self.data([Self.ticker()])) }
        }
        let symbol = btc
        let task = Task { try await provider.fetchQuotes(for: [symbol]) }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
        _ = try await provider.fetchQuotes(for: [btc])
        XCTAssertEqual(calls.requests.map { $0.url?.host }, ["data-api.binance.vision", "data-api.binance.vision"])
    }

    func testIntradayUsesRollingUTCWindowAndAtMost288Points() async throws {
        let calls = CryptoTestCalls()
        let body = Self.data((0..<300).map { Self.bar(open: Self.at.addingTimeInterval(Double($0 - 299) * 300)) })
        let provider = provider { request in calls.record(request); request.reply(body) }
        let fetched = try await provider.fetchIntraday(for: btc)
        let series = try XCTUnwrap(fetched)
        XCTAssertEqual(series.start, Self.at.addingTimeInterval(-86_400))
        XCTAssertEqual(series.points.count, 288)
        XCTAssertEqual(series.points.last?.minute, 1440)
        XCTAssertTrue(series.points.allSatisfy { (0...1440).contains($0.minute) })
        let query = URLComponents(url: calls.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "288")
        XCTAssertEqual(query.first { $0.name == "timeZone" }?.value, "0")
        XCTAssertEqual(query.first { $0.name == "interval" }?.value, "5m")
    }

    func testKlineLimitsCountAndKeepsUTCPeriodIdentityAcrossMidnight() async throws {
        let calls = CryptoTestCalls()
        let opened = Self.at.addingTimeInterval(-3600)
        let provider = provider { request in calls.record(request); request.reply(Self.data([Self.bar(open: opened, duration: 31 * 86_400)])) }
        let fetched = try await provider.fetchKline(for: btc, period: .month, count: Int.max, exchangeCode: nil)
        let first = try XCTUnwrap(fetched)
        let second = try XCTUnwrap(CryptoKlineParser.kline(Self.data([Self.bar(open: opened, duration: 31 * 86_400)]), symbol: btc, period: .month, count: 80, now: Self.at.addingTimeInterval(86_400)))
        XCTAssertEqual(first.candles.first?.date, second.candles.first?.date)
        XCTAssertEqual(first.candles.first?.date, KlineCalendar.dayString(opened, region: .crypto))
        let query = URLComponents(url: calls.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, String(KlineChartData.fetchCount))
        XCTAssertEqual(query.first { $0.name == "interval" }?.value, "1M")
    }

    func testInvalidKlineRowsAreSkippedWithoutPoisoningOtherBars() {
        var bad = Self.bar(open: Self.at.addingTimeInterval(-600)); bad[4] = "nan"
        var wrongTime = Self.bar(open: Self.at.addingTimeInterval(-600)); wrongTime[0] = true
        let good = Self.bar(open: Self.at.addingTimeInterval(-300))
        let series = CryptoKlineParser.intraday(Self.data([bad, wrongTime, good]), symbol: btc, now: Self.at)
        XCTAssertEqual(series?.points.count, 1)
        XCTAssertNil(CryptoKlineParser.intraday(Self.data([bad]), symbol: btc, now: Self.at))
    }

    func testChartAdmissionIsBoundedAndCancelledWaiterNeverStartsNetwork() async throws {
        let started = expectation(description: "three admitted"); started.expectedFulfillmentCount = 3
        let held = CryptoTestHeld()
        let provider = provider { request in held.add(request); started.fulfill() }
        let symbols = Array(CryptoCatalog.symbols.prefix(4))
        let tasks = symbols.prefix(3).map { symbol in Task { try await provider.fetchIntraday(for: symbol) } }
        defer { tasks.forEach { $0.cancel() } }
        await fulfillment(of: [started], timeout: 2)
        let fourth = Task { try await provider.fetchIntraday(for: symbols[3]) }
        defer { fourth.cancel() }
        fourth.cancel()
        do { _ = try await fourth.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(held.requests.count, 3)
        for request in held.requests { request.reply(Self.data([Self.bar(open: Self.at.addingTimeInterval(-300))])) }
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(held.requests.count, 3)
    }

    func testDeclaredOversizeCancelsWithoutTryingFallback() async throws {
        let calls = CryptoTestCalls()
        let provider = provider { request in
            calls.record(request)
            request.reply(Data(), headers: ["Content-Length": "2000001"])
        }
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
        XCTAssertEqual(calls.requests.count, 1)
    }

    func testChunkedOversizeCancelsTransportAndEntersCooldown() async throws {
        let calls = CryptoTestCalls()
        let provider = provider { request in
            calls.record(request)
            request.replyChunks([Data(repeating: 32, count: 1_000_001), Data(repeating: 32, count: 1_000_001)])
        }
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
        do { _ = try await provider.fetchQuotes(for: [btc]); XCTFail() }
        catch { XCTAssertNotNil(error as? CryptoProviderError) }
        XCTAssertEqual(calls.requests.count, 1)
    }

    func testSameTickerScopeQueuesAndCancelledWaiterDoesNotSendRequest() async throws {
        let started = expectation(description: "first ticker started")
        let held = CryptoTestHeld()
        let provider = provider { request in held.add(request); started.fulfill() }
        let symbol = btc
        let first = Task { try await provider.fetchQuotes(for: [symbol]) }
        defer { first.cancel() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await provider.fetchQuotes(for: [symbol]) }
        defer { second.cancel() }
        let noDuplicate = expectation(description: "no simultaneous ticker")
        noDuplicate.isInverted = true
        await fulfillment(of: [noDuplicate], timeout: 0.05)
        second.cancel()
        do { _ = try await second.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(held.requests.count, 1)
        let request = try XCTUnwrap(held.requests.first)
        request.reply(Self.data([Self.ticker()]))
        _ = try await first.value
        XCTAssertEqual(held.requests.count, 1)
    }

    func testDailyWeeklyMonthlyRequestsUseUTCAndClampCount() async throws {
        let calls = CryptoTestCalls()
        let provider = provider { request in
            calls.record(request)
            let query = URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let interval = query.first { $0.name == "interval" }!.value!
            let duration: TimeInterval = interval == "1d" ? 86_400 : interval == "1w" ? 604_800 : 31 * 86_400
            request.reply(Self.data([Self.bar(open: Self.at.addingTimeInterval(-3600), duration: duration)]))
        }
        for period in KlinePeriod.allCases { _ = try await provider.fetchKline(for: btc, period: period, count: -5, exchangeCode: nil) }
        XCTAssertEqual(calls.requests.count, 3)
        let queries = calls.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems! }
        XCTAssertEqual(queries.compactMap { q in q.first { $0.name == "interval" }?.value }, ["1d", "1w", "1M"])
        XCTAssertTrue(queries.allSatisfy { q in q.first { $0.name == "limit" }?.value == "1" && q.first { $0.name == "timeZone" }?.value == "0" })
    }
}

private final class CryptoTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}

private final class CryptoTestCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    @discardableResult func record(_ protocolRequest: CryptoTestProtocol) -> Int {
        lock.lock(); defer { lock.unlock() }; stored.append(protocolRequest.request); return stored.count
    }
}

private final class CryptoTestHeld: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CryptoTestProtocol] = []
    var requests: [CryptoTestProtocol] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ request: CryptoTestProtocol) { lock.lock(); stored.append(request); lock.unlock() }
}

private final class CryptoTestProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (CryptoTestProtocol) -> Void
    static let registry = Registry()
    var onStop: (@Sendable () -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // FoundationNetworking 不保证把 configuration 附加 header 合并给自定义 URLProtocol。
        // 唯一端口随 URL 保留；canInit 始终拦截，未注册请求也绝不落到真实网络。
        guard let port = request.url?.port, let handler = Self.registry.get(port) else {
            fail(URLError(.unsupportedURL)); return
        }
        handler(self)
    }
    override func stopLoading() { onStop?() }
    func reply(_ data: Data, status: Int = 200, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    func replyChunks(_ chunks: [Data]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [Int: Handler] = [:]
        private var nextPort = 49_152
        func add(handler: @escaping Handler) -> Int {
            lock.lock(); defer { lock.unlock() }
            precondition(nextPort <= 65_535, "Crypto test fixture port range exhausted")
            let port = nextPort
            nextPort += 1
            handlers[port] = handler
            return port
        }
        func get(_ port: Int) -> Handler? { lock.lock(); defer { lock.unlock() }; return handlers[port] }
        func remove(_ port: Int) { lock.lock(); handlers.removeValue(forKey: port); lock.unlock() }
    }
}
