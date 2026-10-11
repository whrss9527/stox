import Foundation

public struct SearchResult: Sendable, Hashable, Identifiable {
    public let symbol: Symbol
    public let name: String
    /// 腾讯的证券类型代码，例如 GP-A、GP-A-KCB、ZS、ETF、QDII-ETF、LOF、GP。
    public let typeCode: String

    public init(symbol: Symbol, name: String, typeCode: String) {
        self.symbol = symbol
        self.name = name
        self.typeCode = typeCode
    }

    public var id: String { symbol.rawValue }

    /// 搜索结果里显示的名称：英文界面里能换成英文的换成英文（见 EnglishName；美股、港股的英文名在行情里，
    /// 查到行情之前是代码），别的用搜索接口给的名称。
    public func displayName(quote: Quote?, english: Bool = AppLanguage.isEnglish,
                            traditional: Bool = AppLanguage.isTraditionalChinese) -> String {
        if english, let name = EnglishName.name(symbol, quote: quote) { return name }
        return AppLanguage.securityName(name, traditional: traditional && !english)
    }

    public var typeLabel: String {
        let type = typeCode.uppercased()
        if type.hasPrefix("ZS") { return L("指数") }
        if type.contains("ETF") { return "ETF" }
        if type.contains("LOF") { return "LOF" }
        if type.hasPrefix("GP-A-KCB") { return L("科创板") }
        if type.hasPrefix("GP-A-CYB") { return L("创业板") }
        if type.hasPrefix("GP") { return L("股票") }
        if type.hasPrefix("JJ") || type.hasPrefix("KJ") { return L("基金") }
        if type.hasPrefix("ZQ") { return L("债券") }
        // 期货外汇的品种表里直接写的是中文类型。
        switch typeCode {
        case "贵金属": return L("贵金属")  // l10n-ignore
        case "能源": return L("能源")  // l10n-ignore
        case "期货": return L("期货")  // l10n-ignore
        case "外汇": return L("外汇")  // l10n-ignore
        default: return typeCode
        }
    }
}

/// 解析腾讯搜索接口 `https://smartbox.gtimg.cn/s3/?v=2&t=all&c=1&q=gzmt` 的返回：
/// `v_hint="sh~600519~贵州茅台~gzmt~GP-A^hk~00700~...~txkg~GP"`，
/// 没有结果时为 `v_hint="N";`。
public enum TencentSearchParser {
    /// 权证、牛熊证之类的衍生品会淹没正股结果，直接过滤掉。
    static let excludedTypePrefixes = ["QZ", "NX"]

    public static func parse(_ text: String) -> [SearchResult] {
        guard let start = text.range(of: "=\""),
              let end = text.range(of: "\"", options: .backwards),
              start.upperBound <= end.lowerBound
        else { return [] }
        let body = decodeUnicodeEscapes(String(text[start.upperBound..<end.lowerBound]))
        guard !body.isEmpty, body != "N" else { return [] }

        var seen = Set<Symbol>()
        var results: [SearchResult] = []
        for entry in body.split(separator: "^") {
            let fields = entry.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, let market = Market(rawValue: fields[0].lowercased()) else { continue }
            let type = fields[4]
            if excludedTypePrefixes.contains(where: { type.uppercased().hasPrefix($0) }) { continue }

            var code = fields[1]
            if market == .us {
                if type.uppercased().hasPrefix("ZS") {
                    // 美股指数：ixic → .IXIC
                    code = "." + code.drop(while: { $0 == "." })
                } else if let dot = code.lastIndex(of: ".") {
                    // 美股个股带交易所后缀：aapl.oq → AAPL，brk.b.n → BRK.B
                    code = String(code[..<dot])
                }
            }
            guard let symbol = Symbol(market: market, code: code), seen.insert(symbol).inserted else { continue }
            results.append(SearchResult(symbol: symbol, name: fields[2], typeCode: type))
        }
        return results
    }

    /// 把 `贵` 形式的转义还原成字符，支持代理对。
    static func decodeUnicodeEscapes(_ text: String) -> String {
        guard text.contains("\\u") else { return text }
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var highSurrogate: UInt32?
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\\", i + 5 < scalars.count, scalars[i + 1] == "u",
               let value = UInt32(String(String.UnicodeScalarView(scalars[(i + 2)...(i + 5)])), radix: 16) {
                i += 6
                if (0xD800...0xDBFF).contains(value) {
                    highSurrogate = value
                    continue
                }
                if (0xDC00...0xDFFF).contains(value), let high = highSurrogate {
                    let combined = 0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)
                    if let scalar = Unicode.Scalar(combined) { output.append(scalar) }
                } else if let scalar = Unicode.Scalar(value) {
                    output.append(scalar)
                }
                highSurrogate = nil
            } else {
                highSurrogate = nil
                output.append(scalars[i])
                i += 1
            }
        }
        return String(output)
    }
}
