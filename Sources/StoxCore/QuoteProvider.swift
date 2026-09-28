import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol QuoteProvider: Sendable {
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote]
    func search(_ query: String) async throws -> [SearchResult]
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
