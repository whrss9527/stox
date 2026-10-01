import Foundation

/// 英文界面里的名称。数据源给的名称都是中文（AAPL 是“苹果”），英文界面里能换成英文的换成英文：
///
/// - 指数：下面的表（A 股常见的指数、恒生、美股的几个指数），表里没有的港美股指数用行情里的英文名；
/// - 期货外汇、环球股指：品种表里的英文名（见 GlobalCatalog）；
/// - 美股：行情里的英文公司名去掉 Inc.、Corporation 这类字样（`Apple`），菜单栏上用代码；
///   没有英文名时（ETF、新浪的备用行情）都用代码（`AAPL`、`BRK.B`）；
/// - 港股：行情里的英文简称（`TENCENT`），没有时用代码；
/// - A 股、场外基金：数据源没有英文名，照旧用中文名。
///
/// 返回 nil 表示没有英文名，照旧用中文名。用户设的菜单栏简称总是优先（见 WatchItem.tickerName(with:english:)）。
public enum EnglishName {
    /// 指数的英文名和菜单栏上的简称。同一档里按这个顺序搜。
    static let indexTable: [(symbol: String, name: String, short: String)] = [
        ("us.INX", "S&P 500", "S&P 500"),
        ("us.IXIC", "Nasdaq Composite", "Nasdaq"),
        ("us.DJI", "Dow Jones", "Dow"),
        ("us.NDX", "Nasdaq 100", "NDX"),
        ("hkHSI", "Hang Seng", "HSI"),
        ("hkHSCEI", "HS China Enterprises", "HSCEI"),
        ("hkHSTECH", "Hang Seng TECH", "HSTECH"),
        ("sh000001", "SSE Composite", "SSE"),
        ("sz399001", "SZSE Component", "SZSE"),
        ("sz399006", "ChiNext", "ChiNext"),
        ("sh000300", "CSI 300", "CSI 300"),
        ("sz399300", "CSI 300", "CSI 300"),
        ("sh000016", "SSE 50", "SSE 50"),
        ("sh000905", "CSI 500", "CSI 500"),
        ("sz399905", "CSI 500", "CSI 500"),
        ("sh000852", "CSI 1000", "CSI 1000"),
        ("sh000688", "STAR 50", "STAR 50"),
        ("sz399673", "ChiNext 50", "CNX 50"),
        ("sz399330", "SZSE 100", "SZSE 100"),
        ("bj899050", "BSE 50", "BSE 50"),
    ]

    private static let indices = Dictionary(
        indexTable.map { ($0.symbol, (name: $0.name, short: $0.short)) }, uniquingKeysWith: { first, _ in first }
    )

    /// 列表、搜索结果、提醒里的英文名。
    public static func name(_ symbol: Symbol, quote: Quote?) -> String? {
        if let index = indices[symbol.rawValue] { return index.name }
        if let entry = GlobalCatalog.entry(for: symbol) { return entry.english }
        switch symbol.market {
        case .us: return quote?.englishName.map { symbol.isIndex ? $0 : company($0) } ?? symbol.displayCode
        case .hk: return quote?.englishName ?? symbol.displayCode
        case .wh: return pair(symbol.code)
        default: return nil
        }
    }

    /// 菜单栏上的英文名：指数、环球的品种用简称，美股用代码，港股和表里没有的指数用英文名的前几个词。
    public static func shortName(_ symbol: Symbol, quote: Quote?) -> String? {
        if let index = indices[symbol.rawValue] { return index.short }
        if let entry = GlobalCatalog.entry(for: symbol) { return entry.short }
        switch symbol.market {
        case .us where !symbol.isIndex: return symbol.displayCode
        case .us, .hk: return quote?.englishName.map { abbreviate($0) } ?? symbol.displayCode
        case .wh: return pair(symbol.code)
        default: return nil
        }
    }

    /// 品种表里没有的外汇：USDTRY → USD/TRY。
    static func pair(_ code: String) -> String? {
        code.count == 6 ? "\(code.prefix(3))/\(code.dropFirst(3))" : nil
    }

    /// 数据源里的英文名：去掉首尾空白；空的、不是英文的（没有字母或者带中文）当作没有。
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(where: \.isASCIILetter), trimmed.allSatisfy(\.isASCII) else { return nil }
        return trimmed
    }

    /// 公司名后面的这些字样去掉（不分大小写，不管点和逗号）。
    private static let companySuffixes: Set<String> = [
        "inc", "incorporated", "corp", "corporation", "co", "company", "ltd", "limited", "plc", "llc", "lp",
        "sa", "nv", "ag", "se", "a/s", "holding", "holdings", "group", "new", "adr", "ads", "&",
    ]

    /// 美股的公司名去掉后面的 Inc.、Corporation、Ltd 这类字样：`Apple Inc.` → `Apple`，
    /// `Berkshire Hathaway Inc. New` → `Berkshire Hathaway`，`Coca-Cola Company (The)` → `Coca-Cola`，
    /// `Jp Morgan Chase & Co.` → `Jp Morgan Chase`，`Alphabet Inc. Class A` → `Alphabet`。总会留下第一个词。
    public static func company(_ name: String) -> String {
        let plain = name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        var words = plain.split(separator: " ").map(String.init)
        func key(_ word: String) -> String { word.lowercased().filter { $0 != "." && $0 != "," } }
        while words.count > 1 {
            if companySuffixes.contains(key(words[words.count - 1])) {
                words.removeLast()
            } else if words.count > 2, key(words[words.count - 2]) == "class", words[words.count - 1].count == 1 {
                words.removeLast(2)
            } else {
                break
            }
        }
        let short = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return short.isEmpty ? name : short
    }

    /// 菜单栏放得下的英文名：整个词地取，最多 limit 个字符（`HSBC HOLDINGS` → `HSBC`），末尾的 of、and 这类词不要；
    /// 第一个词就太长时截断。
    static func abbreviate(_ name: String, limit: Int = 12) -> String {
        guard name.count > limit else { return name }
        var words: [Substring] = []
        for word in name.split(separator: " ") {
            guard (words + [word]).joined(separator: " ").count <= limit else { break }
            words.append(word)
        }
        while let last = words.last, ["of", "and", "&", "the"].contains(last.lowercased()) {
            words.removeLast()
        }
        return words.isEmpty ? String(name.prefix(limit)) : words.joined(separator: " ")
    }

    /// 按英文名找表里的指数，英文界面里的搜索用（S&P 500、Dow、Hang Seng 这些腾讯的搜索不一定找得到）：
    /// 简称、英文名或者代码完全相同，或者至少三个字时英文名开头相同。搜索结果的名称写英文名，加到自选以后
    /// 刷新一次行情就换成数据源的中文名（名称只从数据源记）。
    public static func searchIndices(_ query: String) -> [SearchResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.contains(where: \.isLetter) else { return [] }
        return indexTable.compactMap { entry -> SearchResult? in
            guard let symbol = Symbol(entry.symbol) else { return nil }
            let names = [entry.name.lowercased(), entry.short.lowercased(), symbol.displayCode.lowercased()]
            guard names.contains(text) || (text.count >= 3 && entry.name.lowercased().hasPrefix(text)) else { return nil }
            return SearchResult(symbol: symbol, name: entry.name, typeCode: "ZS")
        }
    }
}
