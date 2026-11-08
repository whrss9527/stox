import Foundation

/// 统一入口按市场分发；股票主备切换仍由调用方注入的股票 provider 负责。
public struct MarketDataProvider: QuoteProvider {
    private let stock: QuoteProvider
    private let crypto: QuoteProvider

    public init(stock: QuoteProvider = TencentProvider(), crypto: QuoteProvider = CryptoProvider.shared) {
        self.stock = stock
        self.crypto = crypto
    }

    private struct Outcome: @unchecked Sendable {
        let quotes: [Symbol: Quote]
        let error: Error?
    }

    public func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        try Task.checkCancellation()
        let unique = Array(Set(symbols))
        let stocks = unique.filter { !$0.isCrypto }
        let coins = unique.filter(\.isCrypto)
        guard !unique.isEmpty else { return [:] }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            for (provider, requested) in [(stock, stocks), (crypto, coins)] where !requested.isEmpty {
                group.addTask {
                    do {
                        let quotes = try await provider.fetchQuotes(for: requested)
                        try Task.checkCancellation()
                        let allowed = Set(requested)
                        return Outcome(quotes: quotes.filter { allowed.contains($0.key) }, error: nil)
                    } catch {
                        if Self.cancelled(error) { throw CancellationError() }
                        return Outcome(quotes: [:], error: error)
                    }
                }
            }
            var quotes: [Symbol: Quote] = [:]
            var errors: [Error] = []
            for try await result in group {
                quotes.merge(result.quotes) { _, new in new }
                if let error = result.error { errors.append(error) }
            }
            try Task.checkCancellation()
            if quotes.isEmpty, let error = errors.first { throw error }
            return quotes
        }
    }

    /// 显式交易对只查本地，不等待股票网络；裸 ticker 保留同名美股候选。
    public func search(_ query: String) async throws -> [SearchResult] {
        try Task.checkCancellation()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let local = CryptoCatalog.search(text)
        if CryptoCatalog.symbol(for: text) != nil { return local }
        do {
            let remote = try await stock.search(text)
            try Task.checkCancellation()
            var seen = Set(local.map(\.symbol))
            return local + remote.filter { seen.insert($0.symbol).inserted }
        } catch {
            if Self.cancelled(error) { throw CancellationError() }
            if !local.isEmpty { return local }
            throw error
        }
    }

    public func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries? {
        try await (symbol.isCrypto ? crypto : stock).fetchIntraday(for: symbol)
    }

    public func fetchKline(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String?) async throws -> KlineSeries? {
        try await (symbol.isCrypto ? crypto : stock).fetchKline(for: symbol, period: period, count: count, exchangeCode: exchangeCode)
    }

    public func fetchExchangeRates() async throws -> ExchangeRates? { try await stock.fetchExchangeRates() }
    public func fetchRank(_ kind: RankKind, count: Int) async throws -> [RankEntry]? { try await stock.fetchRank(kind, count: count) }
    public func fetchIndustries(count: Int) async throws -> [IndustryEntry]? { try await stock.fetchIndustries(count: count) }

    public func fetchFiveDay(for symbol: Symbol, exchangeCode: String?) async throws -> MultiDaySeries? {
        guard !symbol.isCrypto else { return nil }
        return try await stock.fetchFiveDay(for: symbol, exchangeCode: exchangeCode)
    }

    public func fetchExtendedHours(for symbol: Symbol, exchangeCode: String?) async throws -> ExtendedHoursQuote? {
        guard !symbol.isCrypto else { return nil }
        return try await stock.fetchExtendedHours(for: symbol, exchangeCode: exchangeCode)
    }

    public func fetchFundFlow(for symbol: Symbol) async throws -> FundFlow? {
        guard !symbol.isCrypto else { return nil }
        return try await stock.fetchFundFlow(for: symbol)
    }

    private static func cancelled(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
