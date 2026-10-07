import Foundation
import StoxCore
@testable import Stox

actor FakeQuoteProvider: QuoteProvider {
    var fails = false
    var values: [Symbol: Quote] = [:]
    var quotesRequested = 0
    var intradayRequested = 0
    var extendedRequested = 0
    func configure(fails: Bool = false, values: [Symbol: Quote] = [:]) { self.fails = fails; self.values = values }
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        quotesRequested += 1
        if fails { throw URLError(.cannotConnectToHost) }
        return values.filter { symbols.contains($0.key) }
    }
    func search(_ query: String) async throws -> [SearchResult] { [] }
    func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries? { intradayRequested += 1; return nil }
    func fetchExtendedHours(for symbol: Symbol, exchangeCode: String?) async throws -> ExtendedHoursQuote? { extendedRequested += 1; return nil }
    func counts() -> (quotes: Int, intraday: Int, extended: Int) { (quotesRequested, intradayRequested, extendedRequested) }
}

@MainActor
final class AppTestContext {
    let suite = "StoxTests-" + UUID().uuidString
    let defaults: UserDefaults
    let settings: SettingsStore
    var date = ISO8601DateFormatter().date(from: "2026-10-07T07:30:00Z")!
    var delays: [TimeInterval] = []
    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "slowWhenIdle")
        settings = SettingsStore(defaults: defaults)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
    var clock: QuoteStoreClock {
        QuoteStoreClock(now: { [unowned self] in self.date }, sleep: { [weak self] interval in
            self?.delays.append(interval)
            // Hold until the test cancels this panel/polling task; no wall-clock wait.
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
    }
    func store(provider: QuoteProvider, backup: QuoteProvider? = nil, items: [WatchItem]) throws -> QuoteStore {
        defaults.set(try JSONEncoder().encode(items), forKey: "watchlist.v1")
        return QuoteStore(settings: settings, provider: provider, backup: backup, defaults: defaults, clock: clock)
    }
    func quote(_ symbol: Symbol, price: Double = 110) -> Quote {
        Quote(symbol: symbol, name: "Fixture", price: price, previousClose: 100, open: 100, high: 120, low: 90,
              volume: 100, amount: 1000, timestamp: date)
    }
}
