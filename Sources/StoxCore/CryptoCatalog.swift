import Foundation

/// 首版只接入常用的 USDT 现货。代码、同步身份与交易对名称不受界面语言影响。
public enum CryptoCatalog {
    public struct Entry: Sendable, Identifiable {
        public let baseAsset: String
        public let name: String
        public let english: String
        public var quoteAsset: String { "USDT" }
        public var code: String { baseAsset + quoteAsset }
        public var id: String { "cc" + code }
        public var symbol: Symbol { Symbol(market: .crypto, code: code)! }
    }

    /// 固定顺序用于相同匹配等级的搜索，不表示投资推荐或市值排名。
    public static let entries: [Entry] = [
        Entry(baseAsset: "BTC", name: "比特币", english: "Bitcoin"),  // l10n-ignore: catalog data
        Entry(baseAsset: "ETH", name: "以太坊", english: "Ethereum"),  // l10n-ignore: catalog data
        Entry(baseAsset: "SOL", name: "索拉纳", english: "Solana"),  // l10n-ignore: catalog data
        Entry(baseAsset: "BNB", name: "币安币", english: "BNB"),  // l10n-ignore: catalog data
        Entry(baseAsset: "XRP", name: "瑞波币", english: "XRP"),  // l10n-ignore: catalog data
        Entry(baseAsset: "DOGE", name: "狗狗币", english: "Dogecoin"),  // l10n-ignore: catalog data
        Entry(baseAsset: "ADA", name: "艾达币", english: "Cardano"),  // l10n-ignore: catalog data
        Entry(baseAsset: "TRX", name: "波场币", english: "TRON"),  // l10n-ignore: catalog data
        Entry(baseAsset: "AVAX", name: "雪崩", english: "Avalanche"),  // l10n-ignore: catalog data
        Entry(baseAsset: "LINK", name: "Chainlink", english: "Chainlink"),
    ]

    public static var symbols: [Symbol] { entries.map(\.symbol) }

    public static func entry(for symbol: Symbol) -> Entry? {
        guard symbol.isCrypto else { return nil }
        return entries.first { $0.code == symbol.code }
    }

    /// 只认显式交易对，不把裸 BTC 等同名美股代码解释成数字货币。
    public static func symbol(for code: String) -> Symbol? {
        var value = code.filter { !$0.isWhitespace }
        if value.prefix(2).lowercased() == "cc" { value.removeFirst(2) }
        guard let normalized = normalizedCode(value) else { return nil }
        return Symbol(market: .crypto, code: normalized)
    }

    /// 供 Symbol 校验；不经 Symbol 构造目录，避免静态初始化互相依赖。
    static func normalizedCode(_ raw: String) -> String? {
        let value = raw.filter { !$0.isWhitespace }.uppercased()
        return entries.first { value == $0.code || value == $0.baseAsset + "/USDT" }?.code
    }

    /// 搜索可以用裸 ticker；它只是候选，不改变 SymbolInput 对同名美股的解析。
    public static func search(_ query: String, limit: Int = 6) -> [SearchResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, limit > 0 else { return [] }
        if let symbol = symbol(for: text), let entry = entry(for: symbol) {
            return [SearchResult(symbol: symbol, name: entry.name, typeCode: "CRYPTO")]
        }
        let isChinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        var matches: [(rank: Int, index: Int, entry: Entry)] = []
        for (index, entry) in entries.enumerated() {
            let values = [entry.baseAsset, entry.name, entry.english].map { $0.lowercased() }
            let rank: Int
            if values.contains(text) { rank = 0 }
            else if text.count >= (isChinese ? 1 : 3), values.contains(where: { $0.hasPrefix(text) }) { rank = 1 }
            else if isChinese, text.count >= 2, values.contains(where: { $0.contains(text) }) { rank = 2 }
            else { continue }
            matches.append((rank, index, entry))
        }
        return matches.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.prefix(limit).map {
            SearchResult(symbol: $0.entry.symbol, name: $0.entry.name, typeCode: "CRYPTO")
        }
    }

    /// 常见大币显示到分，小币保留需要的小数；不把行情接口统一的八位尾零照抄到 UI。
    public static func priceDecimals(for price: Double) -> Int {
        guard price.isFinite, price > 0 else { return 2 }
        if price >= 1000 { return 2 }
        if price >= 1 { return 4 }
        if price >= 0.01 { return 6 }
        return 8
    }
}
