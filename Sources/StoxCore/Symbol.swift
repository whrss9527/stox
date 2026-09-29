import Foundation

/// 一只证券（股票、指数、基金）。统一用腾讯接口的代码格式表示，例如
/// `sh600519`、`sz399001`、`bj920819`、`hk00700`、`hkHSI`、`usAAPL`、`us.IXIC`。
public struct Symbol: Hashable, Sendable {
    public let market: Market
    public let code: String

    public init?(market: Market, code: String) {
        guard let normalized = Symbol.normalize(code: code, market: market) else { return nil }
        self.market = market
        self.code = normalized
    }

    /// 从 `sh600519` 这样的完整代码构造。
    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2, let market = Market(rawValue: trimmed.prefix(2).lowercased()) else {
            return nil
        }
        self.init(market: market, code: String(trimmed.dropFirst(2)))
    }

    public var rawValue: String { market.rawValue + code }

    /// 指数没有成交量单位、价格固定两位小数，界面上也会单独标注。
    public var isIndex: Bool {
        switch market {
        case .sh: return code.hasPrefix("000")
        case .sz: return code.hasPrefix("399")
        case .bj: return code.hasPrefix("899")
        case .hk: return !code.allSatisfy(\.isASCIIDigit)
        case .us: return code.hasPrefix(".")
        case .jj: return false
        }
    }

    /// 场外基金：只有每天的净值，没有盘中行情、分时和 K 线。
    public var isFund: Bool { market == .jj }

    /// 科创板（上交所 688、689 开头）：腾讯接口里它的成交量、K 线的量是股，别的 A 股是手。
    public var isStarMarket: Bool {
        market == .sh && (code.hasPrefix("688") || code.hasPrefix("689"))
    }

    /// 界面上展示的代码：美股指数去掉前导的点。
    public var displayCode: String {
        if market == .us, code.hasPrefix(".") { return String(code.dropFirst()) }
        return code
    }

    static func normalize(code raw: String, market: Market) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        switch market {
        case .sh, .sz, .bj, .jj:
            guard code.count == 6, code.allSatisfy(\.isASCIIDigit) else { return nil }
            return code
        case .hk:
            if code.allSatisfy(\.isASCIIDigit) {
                guard code.count <= 5 else { return nil }
                return String(repeating: "0", count: 5 - code.count) + code
            }
            guard code.count <= 12, code.allSatisfy({ $0.isASCIILetter || $0.isASCIIDigit }) else { return nil }
            return code.uppercased()
        case .us:
            let upper = code.uppercased()
            guard upper.count <= 12,
                  upper.allSatisfy({ $0.isASCIILetter || $0.isASCIIDigit || $0 == "." || $0 == "-" }),
                  upper.contains(where: \.isASCIILetter)
            else { return nil }
            return upper
        }
    }
}

extension Symbol: Identifiable {
    public var id: String { rawValue }
}

extension Symbol: CustomStringConvertible {
    public var description: String { rawValue }
}

extension Symbol: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let symbol = Symbol(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效的证券代码：\(raw)")
        }
        self = symbol
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 把用户随手输入的代码解析成 Symbol。
///
/// 支持：`sh600519`、`600519.SH`、`600519`（按号段推断沪深北）、`700`/`00700`（港股）、
/// `AAPL`/`brk.b`（美股）、`us.IXIC`、`hkHSI`，场外基金 `jj161725`、`161725.OF`。
public enum SymbolInput {
    public static func parse(_ input: String) -> Symbol? {
        let text = input.filter { !$0.isWhitespace }
        guard !text.isEmpty else { return nil }

        // 1. 前缀格式：sh600519 / hk00700 / usAAPL / us.IXIC。
        //    美股、港股字母代码要求小写前缀，避免把 USO、HKD 之类的美股代码误判。
        if text.count > 2 {
            let prefix = String(text.prefix(2))
            let rest = String(text.dropFirst(2))
            if let market = Market(rawValue: prefix.lowercased()) {
                let restIsDigits = rest.allSatisfy(\.isASCIIDigit)
                let accept: Bool
                switch market {
                case .sh, .sz, .bj, .jj: accept = true
                case .hk: accept = restIsDigits || prefix == "hk"
                case .us: accept = prefix == "us" || rest.hasPrefix(".")
                }
                if accept, let symbol = Symbol(market: market, code: rest) { return symbol }
            }
        }

        // 2. 后缀格式：600519.SH / 600519.SS / 0700.HK / AAPL.US。
        if let dot = text.lastIndex(of: ".") {
            let code = String(text[..<dot])
            let suffix = text[text.index(after: dot)...].uppercased()
            let market: Market?
            switch suffix {
            case "SH", "SS": market = .sh
            case "SZ": market = .sz
            case "BJ": market = .bj
            case "HK": market = .hk
            case "US": market = .us
            case "OF": market = .jj  // 场外基金，比如 161725.OF
            default: market = nil
            }
            if let market, let symbol = Symbol(market: market, code: code) { return symbol }
        }

        // 3. 纯数字：6 位按 A 股号段推断，5 位及以内当作港股。
        if text.allSatisfy(\.isASCIIDigit) {
            if text.count == 6 { return Symbol(market: inferAShareMarket(text), code: text) }
            if text.count <= 5 { return Symbol(market: .hk, code: text) }
            return nil
        }

        // 4. 其余当作美股代码。
        return Symbol(market: .us, code: text)
    }

    /// 输入是否明确是证券代码，而不是名称或拼音缩写：含数字，或带 `us`/`hk` 等市场前缀、`.SH` 等后缀。
    /// 纯字母（如 `gzmt`、`aapl`）既可能是美股代码也可能是拼音，需要交给搜索判断。
    public static func isExplicitCode(_ input: String) -> Bool {
        let text = input.filter { !$0.isWhitespace }
        guard !text.isEmpty, parse(text) != nil else { return false }
        if text.contains(where: \.isASCIIDigit) { return true }
        if text.count > 2, text.hasPrefix("us") || text.hasPrefix("hk") { return true }
        if let dot = text.lastIndex(of: ".") {
            let suffix = text[text.index(after: dot)...].uppercased()
            return ["SH", "SS", "SZ", "BJ", "HK", "US", "OF"].contains(suffix)
        }
        return false
    }

    /// 一次粘贴的多个代码，用空白、逗号、顿号、分号或竖线分开。
    /// 至少能认出两个代码时返回结果（去重、保持顺序），否则返回 nil，按普通搜索处理。
    /// 这时纯字母按美股代码处理，是否真的存在由调用方再查一次行情确认。
    public static func parseList(_ input: String) -> (symbols: [Symbol], rejected: [String])? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，、;；|"))
        let tokens = input.components(separatedBy: separators).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return nil }
        var symbols: [Symbol] = []
        var rejected: [String] = []
        for token in tokens {
            if let symbol = parse(token) {
                if !symbols.contains(symbol) {
                    symbols.append(symbol)
                }
            } else {
                rejected.append(token)
            }
        }
        return symbols.count >= 2 ? (symbols, rejected) : nil
    }

    /// 按号段推断 6 位代码所属交易所。000001 这类沪深重号的代码按股票处理（深市）。
    static func inferAShareMarket(_ code: String) -> Market {
        if code.hasPrefix("92") || code.hasPrefix("4") || code.hasPrefix("8") { return .bj }
        if code.hasPrefix("6") || code.hasPrefix("9") || code.hasPrefix("5") || code.hasPrefix("11") { return .sh }
        return .sz
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
