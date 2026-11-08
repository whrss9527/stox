import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CryptoProviderError: Error, LocalizedError, Equatable {
    case cooldown(until: Date)
    case requestLimit

    public var errorDescription: String? { L("数字货币行情请求暂缓，请稍后重试") }
}

/// Binance 公开 USDT 现货数据。仅使用同一交易所备用主机，不改变计价资产。
public final class CryptoProvider: QuoteProvider, @unchecked Sendable {
    /// App、快捷指令与统一数据入口共用网络窗口；测试可继续显式注入独立实例。
    public static let shared = CryptoProvider()
    public static let endpoint = URL(string: "https://data-api.binance.vision/api/v3")!
    public static let fallbackEndpoint = URL(string: "https://api.binance.com/api/v3")!
    public static let maximumIntradayPoints = 288
    public static var maximumKlineCount: Int { KlineChartData.fetchCount }

    private let transport: CryptoHTTPTransport
    private let timeout: TimeInterval
    private let endpoints: [URL]
    private let now: @Sendable () -> Date
    private let onResponse: (@Sendable (Data, HTTPURLResponse) -> Void)?
    private let state: CryptoRequestState

    public init(session: URLSession = .shared, timeout: TimeInterval = 8,
                baseURL: URL = CryptoProvider.endpoint, fallbackURL: URL? = CryptoProvider.fallbackEndpoint,
                now: @escaping @Sendable () -> Date = { Date() }, chartConcurrency: Int = 3,
                onResponse: (@Sendable (Data, HTTPURLResponse) -> Void)? = nil) {
        let requestTimeout = timeout.isFinite ? min(max(timeout, 0.1), 8) : 8
        self.timeout = requestTimeout
        transport = CryptoHTTPTransport(configuration: session.configuration, timeout: requestTimeout)
        self.endpoints = [baseURL] + (fallbackURL.flatMap { $0 == baseURL ? nil : $0 }.map { [$0] } ?? [])
        self.now = now
        self.onResponse = onResponse
        state = CryptoRequestState(chartCapacity: min(max(chartConcurrency, 1), 3))
    }

    public func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        let requested = supported(symbols)
        guard !requested.isEmpty else { try Task.checkCancellation(); return [:] }
        let at = now()
        return try await request(scope: .quotes, path: "ticker/24hr", query: tickerQuery(requested)) { data in
            let quotes = CryptoQuoteParser.parse(data, symbols: requested, now: at)
            guard !quotes.isEmpty else { throw ProviderError.emptyResponse }
            return quotes
        }
    }

    /// 调试入口保留真实响应字节；和行情相同的限流、取消、批量校验路径，不写入个人文件。
    public func fetchRaw(for symbols: [Symbol]) async throws -> Data {
        let requested = supported(symbols)
        guard !requested.isEmpty else { throw ProviderError.emptyResponse }
        let at = now()
        return try await request(scope: .quotes, path: "ticker/24hr", query: tickerQuery(requested)) { data in
            guard !CryptoQuoteParser.parse(data, symbols: requested, now: at).isEmpty else { throw ProviderError.emptyResponse }
            return data
        }
    }

    public func search(_ query: String) async throws -> [SearchResult] {
        try Task.checkCancellation()
        return CryptoCatalog.search(query)
    }

    public func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries? {
        guard CryptoCatalog.entry(for: symbol) != nil else { return nil }
        let at = now()
        let end = Int64(floor(at.timeIntervalSince1970 * 1000))
        let query = [URLQueryItem(name: "symbol", value: symbol.code),
                     URLQueryItem(name: "interval", value: "5m"),
                     URLQueryItem(name: "startTime", value: String(end - 86_400_000 + 1)),
                     URLQueryItem(name: "endTime", value: String(end)),
                     URLQueryItem(name: "limit", value: String(Self.maximumIntradayPoints)),
                     URLQueryItem(name: "timeZone", value: "0")]
        return try await request(scope: .chart(symbol.rawValue + "/5m"), path: "klines", query: query) { data in
            guard let series = CryptoKlineParser.intraday(data, symbol: symbol, now: at) else { throw ProviderError.emptyResponse }
            return series
        }
    }

    public func fetchKline(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String?) async throws -> KlineSeries? {
        guard CryptoCatalog.entry(for: symbol) != nil else { return nil }
        let at = now()
        let limit = min(max(count, 1), Self.maximumKlineCount)
        let interval: String
        switch period { case .day: interval = "1d"; case .week: interval = "1w"; case .month: interval = "1M" }
        let query = [URLQueryItem(name: "symbol", value: symbol.code), URLQueryItem(name: "interval", value: interval),
                     URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "timeZone", value: "0"),
                     URLQueryItem(name: "endTime", value: String(Int64(floor(at.timeIntervalSince1970 * 1000))))]
        return try await request(scope: .chart(symbol.rawValue + "/" + interval), path: "klines", query: query) { data in
            guard let series = CryptoKlineParser.kline(data, symbol: symbol, period: period, count: limit, now: at) else { throw ProviderError.emptyResponse }
            return series
        }
    }

    private func supported(_ symbols: [Symbol]) -> [Symbol] {
        var seen = Set<Symbol>()
        return symbols.filter { CryptoCatalog.entry(for: $0) != nil && seen.insert($0).inserted }
    }

    private func tickerQuery(_ symbols: [Symbol]) -> [URLQueryItem] {
        let codes = symbols.map(\.code)
        let json = (try? JSONSerialization.data(withJSONObject: codes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return [URLQueryItem(name: "symbols", value: json), URLQueryItem(name: "type", value: "FULL")]
    }

    private func request<Value: Sendable>(scope: CryptoRequestScope, path: String, query: [URLQueryItem],
                                         parse: @Sendable (Data) throws -> Value) async throws -> Value {
        guard await state.acquire(scope) else {
            try Task.checkCancellation()
            throw CryptoProviderError.requestLimit
        }
        var retryAfter: TimeInterval?
        do {
            try Task.checkCancellation()
            let preferred = try await state.preflight(scope, now: now())
            let order = endpoints.indices.sorted { lhs, rhs in lhs == preferred && rhs != preferred }
            for (index, host) in order.enumerated() {
                do {
                    try Task.checkCancellation()
                    var components = URLComponents(url: endpoints[host], resolvingAgainstBaseURL: false)
                    components?.path = endpoints[host].path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 } + "/" + path
                    components?.queryItems = query
                    guard let url = components?.url else { throw URLError(.badURL) }
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
                    request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await transport.load(request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    onResponse?(data, http)
                    if http.statusCode == 429 || http.statusCode == 418 {
                        retryAfter = Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After"), now: now())
                    }
                    guard (200..<300).contains(http.statusCode) else { throw ProviderError.badStatus(http.statusCode) }
                    guard !data.isEmpty, data.count <= 2_000_000 else { throw ProviderError.emptyResponse }
                    let value = try parse(data)
                    try Task.checkCancellation()
                    await state.succeeded(scope, host: host)
                    await state.release(scope)
                    return value
                } catch {
                    if Self.cancelled(error) { throw CancellationError() }
                    if index + 1 < order.count, Self.mayFallback(error) { continue }
                    throw error
                }
            }
            throw ProviderError.emptyResponse
        } catch {
            let cancelled = Self.cancelled(error)
            if !cancelled, !(error is CryptoProviderError) {
                await state.failed(scope, now: now(), retryAfter: retryAfter)
            }
            await state.release(scope)
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    private static func cancelled(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func mayFallback(_ error: Error) -> Bool {
        if case ProviderError.badStatus(let status) = error { return (500...599).contains(status) }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .badServerResponse].contains(error.code)
    }

    static func retryDelay(_ value: String?, now: Date) -> TimeInterval {
        // 官方418封禁可持续三天，不能把合法Retry-After截短为一天而提前重试。
        let maximum: TimeInterval = 3 * 86_400
        if let value, let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(max(seconds, 1), maximum) }
        if let value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return min(max(date.timeIntervalSince(now), 1), maximum) }
        }
        return 60
    }

}

private enum CryptoRequestScope: Hashable, Sendable { case quotes, chart(String) }

/// 所有同实例调用共享窗口：股票成功不会清空数字货币失败退避。
private actor CryptoRequestState {
    private struct Waiter {
        let id: UUID
        let scope: CryptoRequestScope
        let continuation: CheckedContinuation<Bool, Never>
    }
    private let chartCapacity: Int
    private var active = Set<CryptoRequestScope>()
    private var waiters: [Waiter] = []
    private var failures: [CryptoRequestScope: Int] = [:]
    private var retryAt: [CryptoRequestScope: Date] = [:]
    private var rateLimitUntil: Date?
    private var preferredHost = 0

    init(chartCapacity: Int) { self.chartCapacity = chartCapacity }

    func acquire(_ scope: CryptoRequestScope) async -> Bool {
        guard !Task.isCancelled, waiters.count < 32 else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                waiters.append(Waiter(id: id, scope: scope, continuation: continuation))
                grant()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func release(_ scope: CryptoRequestScope) { active.remove(scope); grant() }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func grant() {
        while let index = waiters.firstIndex(where: { waiter in
            guard !active.contains(waiter.scope) else { return false }
            if waiter.scope == .quotes { return true }
            return active.filter { $0 != .quotes }.count < chartCapacity
        }) {
            let waiter = waiters.remove(at: index)
            active.insert(waiter.scope)
            waiter.continuation.resume(returning: true)
        }
    }

    func preflight(_ scope: CryptoRequestScope, now: Date) throws -> Int {
        if let until = [retryAt[scope], rateLimitUntil].compactMap({ $0 }).max(), until > now {
            throw CryptoProviderError.cooldown(until: until)
        }
        return preferredHost
    }

    func succeeded(_ scope: CryptoRequestScope, host: Int) {
        failures.removeValue(forKey: scope)
        retryAt.removeValue(forKey: scope)
        preferredHost = host
    }

    func failed(_ scope: CryptoRequestScope, now: Date, retryAfter: TimeInterval?) {
        let count = min((failures[scope] ?? 0) + 1, 7)
        failures[scope] = count
        retryAt[scope] = now.addingTimeInterval(min(5 * pow(2, Double(count - 1)), 300))
        if let retryAfter {
            let until = now.addingTimeInterval(retryAfter)
            rateLimitUntil = max(rateLimitUntil ?? until, until)
        }
    }
}
