import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 新浪财经行情，腾讯的行情接口不可用时的备用数据源。只提供实时行情；搜索、分时、K 线仍然用腾讯。
///
/// `https://hq.sinajs.cn/list=sh600519,hk00700,gb_aapl`，必须带 `Referer: https://finance.sina.com.cn/`（否则 403），
/// 返回 GB18030 编码的 `var hq_str_sh600519="贵州茅台,1236.000,…";`。
public final class SinaProvider: QuoteProvider, @unchecked Sendable {
    public static let endpoint = "https://hq.sinajs.cn/list="
    public static let referer = "https://finance.sina.com.cn/"

    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 8) {
        self.session = session
        self.timeout = timeout
    }

    /// 新浪的代码写法：沪深北、港股和腾讯一样；美股是 `gb_` 加小写代码，指数去掉开头的点（`gb_ixic`），
    /// 分级股的点换成 `$`（`gb_brk$b`）。
    public static func code(for symbol: Symbol) -> String {
        guard symbol.market == .us else { return symbol.rawValue }
        var ticker = symbol.code.lowercased()
        if ticker.hasPrefix(".") { ticker.removeFirst() }
        return "gb_" + ticker.replacingOccurrences(of: ".", with: "$")
    }

    public static func quoteURL(for symbols: [Symbol]) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "_,.$")
        let list = symbols.map(code(for:)).joined(separator: ",")
        guard let encoded = list.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: endpoint + encoded)
    }

    public func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        // 场外基金新浪这里没有，不请求。
        let symbols = symbols.filter { !$0.isFund }
        guard !symbols.isEmpty, let url = Self.quoteURL(for: symbols) else { return [:] }
        let data = try await HTTP.get(url, session: session, timeout: timeout, headers: ["Referer": Self.referer])
        return SinaQuoteParser.parse(Self.decodeText(data), symbols: symbols)
    }

    public func search(_ query: String) async throws -> [SearchResult] { [] }

    /// 新浪返回 GB18030；解不了时按 UTF-8 尽量解。
    static func decodeText(_ data: Data) -> String {
        #if canImport(Darwin)
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return text }
        #endif
        return String(decoding: data, as: UTF8.self)
    }
}

/// 解析新浪行情。三地的字段不同（下标从 0 开始）：
///
/// - 沪深北：0 名称、1 今开、2 昨收、3 现价、4 最高、5 最低、8 成交量（股；上证的指数是手）、9 成交额（元）、
///   10–19 / 20–29 买一到买五 / 卖一到卖五（每档“量（股）、价”）、30 日期、31 时间
/// - 港股：1 名称、2 今开、3 昨收、4 最高、5 最低、6 现价、11 成交额、12 成交量、13 市盈率、15 / 16 52 周最高 / 最低、
///   17 日期（`2026/09/28`）、18 时间（`16:08`）。指数的 11 是千港元，没有成交量
/// - 美股：0 名称、1 现价、3 北京时间、5 今开、6 最高、7 最低、8 / 9 52 周最高 / 最低、10 成交量、12 总市值、14 市盈率、
///   26 昨收、30 成交额
///
/// 查不到的代码返回空字符串 `var hq_str_sh999999="";`。
public enum SinaQuoteParser {
    public static func parse(_ text: String, symbols: [Symbol]) -> [Symbol: Quote] {
        var byCode: [String: Symbol] = [:]
        for symbol in symbols {
            byCode[SinaProvider.code(for: symbol)] = symbol
        }
        var quotes: [Symbol: Quote] = [:]
        for (code, payload) in records(in: text) {
            guard let symbol = byCode[code], let quote = parseRecord(symbol: symbol, payload: payload) else { continue }
            quotes[symbol] = quote
        }
        return quotes
    }

    /// 从 `var hq_str_CODE="PAYLOAD";` 序列中取出 (CODE, PAYLOAD)。
    static func records(in text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var cursor = text.startIndex
        while let prefix = text.range(of: "hq_str_", range: cursor..<text.endIndex) {
            guard let assign = text.range(of: "=\"", range: prefix.upperBound..<text.endIndex),
                  let close = text.range(of: "\"", range: assign.upperBound..<text.endIndex)
            else { break }
            let code = String(text[prefix.upperBound..<assign.lowerBound])
            let payload = String(text[assign.upperBound..<close.lowerBound])
            cursor = close.upperBound
            guard !code.isEmpty, code.count <= 24, !payload.isEmpty else { continue }
            result.append((code, payload))
        }
        return result
    }

    static func parseRecord(symbol: Symbol, payload: String) -> Quote? {
        let fields = payload.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func number(_ index: Int) -> Double? {
            guard index < fields.count, let value = Double(fields[index]), value.isFinite else { return nil }
            return value
        }
        func positive(_ index: Int) -> Double? {
            guard let value = number(index), value > 0 else { return nil }
            return value
        }
        let region = symbol.market.region
        switch region {
        case .cn:
            guard fields.count > 31, !fields[0].isEmpty, let previousClose = positive(2) else { return nil }
            // 开盘前、停牌时现价是 0，按昨收显示，和腾讯一致。
            let price = positive(3) ?? previousClose
            var volume = number(8) ?? 0
            if symbol.market == .sh, symbol.isIndex { volume *= 100 }
            return Quote(
                symbol: symbol,
                name: fields[0],
                price: price,
                previousClose: previousClose,
                open: number(1) ?? 0,
                high: number(4) ?? 0,
                low: number(5) ?? 0,
                volume: volume,
                amount: number(9) ?? 0,
                timestamp: timestamp("\(fields[30]) \(fields[31])", region: region),
                priceDecimals: symbol.isIndex ? 2 : decimals(fields[1...5], range: 2...3),
                orderBook: symbol.isIndex ? nil : orderBook(number)
            )
        case .hk:
            guard fields.count > 18, !fields[1].isEmpty, let previousClose = positive(3) else { return nil }
            let isIndex = symbol.isIndex
            return Quote(
                symbol: symbol,
                name: fields[1],
                price: positive(6) ?? previousClose,
                previousClose: previousClose,
                open: number(2) ?? 0,
                high: number(4) ?? 0,
                low: number(5) ?? 0,
                volume: isIndex ? 0 : (number(12) ?? 0),
                amount: (number(11) ?? 0) * (isIndex ? 1000 : 1),
                peRatio: isIndex ? nil : positive(13),
                high52Week: positive(15),
                low52Week: positive(16),
                timestamp: timestamp("\(fields[17]) \(fields[18])", region: region),
                priceDecimals: isIndex ? 2 : 3
            )
        case .us:
            guard fields.count > 26, !fields[0].isEmpty, let price = positive(1), let previousClose = positive(26) else {
                return nil
            }
            let isIndex = symbol.isIndex
            return Quote(
                symbol: symbol,
                name: fields[0],
                price: price,
                previousClose: previousClose,
                open: number(5) ?? 0,
                high: number(6) ?? 0,
                low: number(7) ?? 0,
                volume: number(10) ?? 0,
                amount: isIndex ? 0 : (number(30) ?? 0),
                peRatio: isIndex ? nil : positive(14),
                marketCap: isIndex ? nil : positive(12),
                high52Week: positive(8),
                low52Week: positive(9),
                // 美股的第 3 位是北京时间。
                timestamp: timestamp(fields[3], region: .cn),
                priceDecimals: price < 1 ? 4 : 2
            )
        }
    }

    /// A 股的五档：10–19 是买一到买五，20–29 是卖一到卖五，每档先量（股）后价。新浪没有内外盘。
    static func orderBook(_ number: (Int) -> Double?) -> OrderBook {
        func side(from start: Int) -> [OrderBook.Level] {
            OrderBook.levels(
                (0..<OrderBook.depth).map { (price: number(start + $0 * 2 + 1), volume: number(start + $0 * 2)) },
                volumeScale: 1
            )
        }
        return OrderBook(bids: side(from: 10), asks: side(from: 20))
    }

    /// `2026-09-28 15:34:59`、`2026/09/28 16:08`，按所在市场的时区。
    static func timestamp(_ text: String, region: MarketRegion) -> Date? {
        let numbers = text.split(whereSeparator: { !$0.isASCIIDigit }).compactMap { Int($0) }
        guard numbers.count >= 5 else { return nil }
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers.count > 5 ? numbers[5] : 0
        return region.calendar.date(from: components)
    }

    /// 新浪的 A 股价格一律三位小数（`1243.880`）。去掉末尾的 0 以后看开、昨收、现价、高、低里最多几位，
    /// 股票是两位，ETF 这类三位。
    static func decimals(_ values: ArraySlice<String>, range: ClosedRange<Int>) -> Int {
        var most = range.lowerBound
        for value in values {
            guard let dot = value.firstIndex(of: ".") else { continue }
            var digits = value[value.index(after: dot)...]
            while digits.hasSuffix("0") { digits = digits.dropLast() }
            most = max(most, digits.count)
        }
        return min(most, range.upperBound)
    }
}

/// 实时行情来自哪个数据源。
public enum QuoteSource: String, Sendable {
    case primary, backup
}

/// 先用主数据源取行情；出错或者一只都没取到时改用备用数据源。两个都不行时抛出主数据源的错误。
public enum QuoteFailover {
    public static func fetchQuotes(
        _ symbols: [Symbol],
        primary: QuoteProvider,
        backup: QuoteProvider?,
        skipPrimary: Bool = false
    ) async throws -> (quotes: [Symbol: Quote], source: QuoteSource) {
        var primaryError: Error?
        var primaryQuotes: [Symbol: Quote]?
        if !skipPrimary || backup == nil {
            do {
                let quotes = try await primary.fetchQuotes(for: symbols)
                if !quotes.isEmpty || backup == nil {
                    return (quotes, .primary)
                }
                primaryQuotes = quotes
            } catch {
                guard backup != nil else { throw error }
                primaryError = error
            }
        }
        guard let backup else { return ([:], .primary) }
        do {
            let quotes = try await backup.fetchQuotes(for: symbols)
            if !quotes.isEmpty { return (quotes, .backup) }
        } catch {
            if primaryError == nil, primaryQuotes == nil { throw error }
        }
        if let primaryError { throw primaryError }
        return (primaryQuotes ?? [:], .primary)
    }
}
