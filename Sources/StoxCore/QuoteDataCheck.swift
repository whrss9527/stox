import Foundation

public enum QuoteDataSource: String, Sendable {
    case tencent, sina

    public func decode(_ data: Data) -> String {
        self == .tencent ? String(decoding: data, as: UTF8.self) : SinaProvider.decodeText(data)
    }

    func records(_ text: String) -> [String: String] {
        let pairs = self == .tencent ? TencentQuoteParser.records(in: text) : SinaQuoteParser.records(in: text)
        return Dictionary(pairs, uniquingKeysWith: { _, last in last })
    }

    func key(_ symbol: Symbol) -> String { self == .tencent ? symbol.rawValue : SinaProvider.code(for: symbol) }
    var separator: Character { self == .tencent ? "~" : "," }

    func snapshot() -> String? {
        let ext = self == .tencent ? "txt" : "bin"
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: ext, subdirectory: "DatasourceSnapshots"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}

/// 用原始字段数与行情不变量发现位置漂移；每条差异包含证券、字段和值。
public enum QuoteDataCheck {
    public static let defaultSymbols = ["sh600519", "sz000001", "sh000001", "hk00700", "usAAPL"].compactMap(Symbol.init)

    public static func differences(_ raw: String, source: QuoteDataSource, symbols: [Symbol], now: Date = Date(),
                                   maxAgeDays: Double? = nil) -> [String] {
        guard let snapshot = source.snapshot() else { return ["\(source.rawValue): missing schema snapshot"] }
        let expected = source.records(snapshot)
        let actual = source.records(raw)
        let quotes = source == .tencent ? TencentQuoteParser.parse(raw) : SinaQuoteParser.parse(raw, symbols: symbols)
        let reference = source == .tencent ? TencentQuoteParser.parse(snapshot) : SinaQuoteParser.parse(snapshot, symbols: symbols)
        var differences: [String] = []
        for symbol in symbols {
            let key = source.key(symbol)
            guard let schema = expected[key] else {
                differences.append("\(symbol.rawValue): no reviewed schema snapshot")
                continue
            }
            guard let payload = actual[key], !payload.isEmpty else {
                differences.append("\(symbol.rawValue): missing raw record")
                continue
            }
            let count = payload.split(separator: source.separator, omittingEmptySubsequences: false).count
            let expectedCount = schema.split(separator: source.separator, omittingEmptySubsequences: false).count
            if count != expectedCount { differences.append("\(symbol.rawValue): fields=\(count), snapshot=\(expectedCount)") }
            guard let quote = quotes[symbol] else {
                differences.append("\(symbol.rawValue): record cannot be parsed")
                continue
            }
            func fail(_ field: String, _ detail: String) { differences.append("\(symbol.rawValue): \(field) \(detail)") }
            if !quote.previousClose.isFinite || quote.previousClose <= 0 { fail("previousClose", "=\(quote.previousClose), expected > 0") }
            // 停牌/尚未成交可以没有日内高低价；已成交行情必须在价格范围内。
            if quote.hasTraded {
                let tolerance = max(0.011, abs(quote.price) * 0.0005)
                if !quote.price.isFinite || !quote.low.isFinite || !quote.high.isFinite || quote.low <= 0 || quote.high < quote.low
                    || quote.price < quote.low - tolerance || quote.price > quote.high + tolerance {
                    fail("price", "=\(quote.price), low=\(quote.low), high=\(quote.high)")
                }
                if symbol.market.region == .cn, !symbol.isIndex, quote.volume > 0 {
                    let average = quote.amount / quote.volume
                    if !average.isFinite || average < quote.low * 0.99 || average > quote.high * 1.01
                        || average < quote.price * 0.7 || average > quote.price * 1.3 {
                        fail("amount/volume", "=\(average), price=\(quote.price), low=\(quote.low), high=\(quote.high)")
                    }
                }
                if reference[symbol]?.high52Week != nil {
                    if let high = quote.high52Week {
                        if !high.isFinite || high + tolerance < quote.high { fail("high52Week", "=\(high), todayHigh=\(quote.high)") }
                    } else { fail("high52Week", "is missing or invalid") }
                }
            }
            // 核心没有节假日日历。A 股长假留十天窗口，港美股五天；超出需明确覆盖，不能默认放行。
            let ageDays = maxAgeDays ?? (symbol.market.region == .cn ? 10 : 5)
            if let timestamp = quote.timestamp {
                let age = now.timeIntervalSince(timestamp)
                if age < -300 || age > ageDays * 86400 { fail("timestamp", "=\(timestamp), ageSeconds=\(Int(age)), allowedDays=\(ageDays)") }
            } else { fail("timestamp", "is missing or invalid") }
        }
        return differences
    }
}
