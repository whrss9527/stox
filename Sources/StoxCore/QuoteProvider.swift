import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol QuoteProvider: Sendable {
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote]
    func search(_ query: String) async throws -> [SearchResult]
    /// 当天的分时走势；数据源不支持时返回 nil。
    func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries?
    /// 最近 count 根 K 线；数据源不支持时返回 nil。
    /// exchangeCode 是行情里带的交易所代码（例如 `AAPL.OQ`），有的数据源查美股 K 线要用到。
    func fetchKline(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String?) async throws -> KlineSeries?
}

extension QuoteProvider {
    public func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries? { nil }
    public func fetchKline(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String?) async throws -> KlineSeries? { nil }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case badStatus(Int)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "服务器返回 HTTP \(code)"
        case .emptyResponse: return "服务器没有返回数据"
        }
    }
}

/// 腾讯财经行情源：免费、无需密钥，覆盖沪深北 A 股、港股（延时约 15 分钟）和美股。
public final class TencentProvider: QuoteProvider, @unchecked Sendable {
    public static let quoteEndpoint = "https://qt.gtimg.cn/utf8/q="
    public static let searchEndpoint = "https://smartbox.gtimg.cn/s3/?v=2&t=all&c=1&q="

    /// 单次请求的最大代码数，超出后分批并发请求。
    static let batchSize = 60

    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 8) {
        self.session = session
        self.timeout = timeout
    }

    public static func quoteURL(for symbols: [Symbol]) -> URL? {
        URL(string: quoteEndpoint + symbols.map(\.rawValue).joined(separator: ","))
    }

    public static let minuteEndpoint = "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code="
    public static let usMinuteEndpoint = "https://web.ifzq.gtimg.cn/appstock/app/UsMinute/query?code="

    /// 分时接口：美股（含指数）用单独的地址。
    public static func minuteURL(for symbol: Symbol) -> URL? {
        let endpoint = symbol.market.region == .us ? usMinuteEndpoint : minuteEndpoint
        return URL(string: endpoint + symbol.rawValue)
    }

    public static let klineEndpoints: [MarketRegion: String] = [
        .cn: "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=",
        .hk: "https://web.ifzq.gtimg.cn/appstock/app/hkfqkline/get?param=",
        .us: "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=",
    ]

    /// K 线接口（前复权）：沪深北、港股、美股各用一个地址。美股个股要带交易所后缀，
    /// 用行情里的交易所代码补上（`AAPL.OQ`、`BRK.B.N`）；指数的代码（`.IXIC`）本身就是这个样子。
    public static func klineURL(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String? = nil) -> URL? {
        let region = symbol.market.region
        guard let endpoint = klineEndpoints[region] else { return nil }
        var code = symbol.rawValue
        if region == .us, let exchangeCode, exchangeCode.contains(".") {
            code = "us" + exchangeCode
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".")
        guard let encoded = code.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(endpoint)\(encoded),\(period.rawValue),,,\(max(count, 1)),qfq")
    }

    public static func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchEndpoint + encoded)
    }

    public func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        var unique: [Symbol] = []
        var seen = Set<Symbol>()
        for symbol in symbols where seen.insert(symbol).inserted { unique.append(symbol) }
        guard !unique.isEmpty else { return [:] }

        let batches = stride(from: 0, to: unique.count, by: Self.batchSize).map {
            Array(unique[$0..<min($0 + Self.batchSize, unique.count)])
        }
        return try await withThrowingTaskGroup(of: [Symbol: Quote].self) { group in
            for batch in batches {
                group.addTask { try await self.fetchBatch(batch) }
            }
            var merged: [Symbol: Quote] = [:]
            for try await quotes in group {
                merged.merge(quotes) { _, new in new }
            }
            return merged
        }
    }

    public func fetchRaw(for symbols: [Symbol]) async throws -> String {
        guard let url = Self.quoteURL(for: symbols) else { throw URLError(.badURL) }
        return Self.decodeText(try await get(url))
    }

    public func search(_ query: String) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let url = Self.searchURL(for: trimmed) else { throw URLError(.badURL) }
        return TencentSearchParser.parse(Self.decodeText(try await get(url)))
    }

    public func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries? {
        guard let url = Self.minuteURL(for: symbol) else { throw URLError(.badURL) }
        return TencentMinuteParser.parse(try await get(url), symbol: symbol)
    }

    public func fetchKline(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String?) async throws -> KlineSeries? {
        var code = exchangeCode
        // 美股个股不带交易所后缀时取不到正确的 K 线，调用方没给就先查一次行情。
        if code == nil, symbol.market.region == .us, !symbol.isIndex {
            code = try await fetchQuotes(for: [symbol])[symbol]?.exchangeCode
        }
        guard let url = Self.klineURL(for: symbol, period: period, count: count, exchangeCode: code) else { throw URLError(.badURL) }
        return TencentKlineParser.parse(try await get(url), symbol: symbol, period: period)
    }

    private func fetchBatch(_ symbols: [Symbol]) async throws -> [Symbol: Quote] {
        guard let url = Self.quoteURL(for: symbols) else { throw URLError(.badURL) }
        return TencentQuoteParser.parse(Self.decodeText(try await get(url)))
    }

    private func get(_ url: URL) async throws -> Data {
        try await HTTP.get(url, session: session, timeout: timeout)
    }

    /// 接口默认返回 UTF-8；万一退回 GBK 也能正确解码。
    static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        #if canImport(Darwin)
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return text }
        #endif
        return String(decoding: data, as: UTF8.self)
    }
}
