import Foundation

/// 期货外汇的行情，腾讯和新浪的行情接口都有（和股票用同一个地址）。
///
/// 国际期货和贵金属现货：`v_hf_XAU="4141.36,0.64,4141.36,4141.71,4144.88,4113.30,14:00:00,4114.93,4117.01,0,0,0,2026-09-29,伦敦金（现货黄金）";`，
/// 字段以逗号分隔：0 现价、1 涨跌幅%（新浪这一位是空的或者昨收，不用）、2 买价、3 卖价、4 最高、5 最低、6 时间、
/// 7 昨收（期货是昨天的结算价）、8 今开、12 日期、13 名称，时间是北京时间。新浪的 `hf_` 行情字段位置一样，价格多一位小数。
///
/// 外汇：`v_whUSDCNY="310~美元人民币~USDCNY~6.7062~0~20260929140022~6.7100~6.7050~6.7086~6.7050~6.7062~6.7064~-0.0038~-0.06~…~7.1430~6.6950~2026-09-29";`，
/// 字段以 `~` 分隔：1 名称、3 现价、5 时间（北京时间）、6 昨收、7 今开、8 最高、9 最低、10 买价、11 卖价、
/// 12 涨跌、13 涨跌幅%、19 / 20 52 周最高 / 最低。只有腾讯有，新浪的外汇是另一套代码和字段，不用。
public enum GlobalQuoteParser {
    public static func parse(symbol: Symbol, payload: String) -> Quote? {
        switch symbol.market {
        case .hf: return futures(symbol: symbol, fields: fields(payload, separator: ","))
        case .wh: return forex(symbol: symbol, fields: fields(payload, separator: "~"))
        default: return nil
        }
    }

    static func fields(_ payload: String, separator: Character) -> [String] {
        payload.split(separator: separator, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    static func futures(symbol: Symbol, fields: [String]) -> Quote? {
        func positive(_ index: Int) -> Double? {
            guard index < fields.count, let value = Double(fields[index]), value.isFinite, value > 0 else { return nil }
            return value
        }
        guard fields.count > 13, let price = positive(0), let previousClose = positive(7) else { return nil }
        return Quote(
            symbol: symbol,
            name: shortName(fields[13], fallback: symbol.code),
            price: price,
            previousClose: previousClose,
            open: positive(8) ?? 0,
            high: positive(4) ?? 0,
            low: positive(5) ?? 0,
            timestamp: TencentQuoteParser.parseTimestamp(fields[12] + fields[6], timeZone: MarketRegion.global.timeZone),
            priceDecimals: decimals([0, 4, 5, 7, 8].compactMap { $0 < fields.count ? fields[$0] : nil }),
            bid: positive(2),
            ask: positive(3)
        )
    }

    static func forex(symbol: Symbol, fields: [String]) -> Quote? {
        func positive(_ index: Int) -> Double? {
            guard index < fields.count, let value = Double(fields[index]), value.isFinite, value > 0 else { return nil }
            return value
        }
        guard fields.count > 13, let price = positive(3), let previousClose = positive(6) else { return nil }
        return Quote(
            symbol: symbol,
            name: shortName(fields[1], fallback: symbol.code),
            price: price,
            previousClose: previousClose,
            open: positive(7) ?? 0,
            high: positive(8) ?? 0,
            low: positive(9) ?? 0,
            high52Week: positive(19),
            low52Week: positive(20),
            timestamp: TencentQuoteParser.parseTimestamp(fields[5], timeZone: MarketRegion.global.timeZone),
            priceDecimals: decimals([3, 6, 7, 8, 9].map { fields[$0] }),
            bid: positive(10),
            ask: positive(11)
        )
    }

    /// 名称去掉括号里的说明：`伦敦金（现货黄金）` → `伦敦金`。
    static func shortName(_ name: String, fallback: String) -> String {
        let short = name.prefix(while: { $0 != "（" && $0 != "(" }).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? fallback : short
    }

    /// 报价的小数位数：去掉末尾的 0 以后几个价格里最多几位，在 2 到 4 之间
    /// （腾讯的外汇一律四位，美元日元 `157.3300` 实际是两位）。
    static func decimals(_ values: [String]) -> Int {
        var most = 2
        for value in values {
            guard let dot = value.firstIndex(of: ".") else { continue }
            var digits = value[value.index(after: dot)...]
            while digits.hasSuffix("0") { digits = digits.dropLast() }
            most = max(most, digits.count)
        }
        return min(most, 4)
    }
}

/// 期货外汇的品种表。腾讯的搜索接口搜不到期货外汇，搜索时先在这里找：中文名、英文、代码、拼音首字母都行。
public enum GlobalCatalog {
    public struct Entry: Sendable {
        public let symbol: Symbol
        public let name: String
        /// 搜索结果里显示的类型：贵金属、能源、期货、外汇。
        public let kind: String
        /// 除了名称和代码，还能用这些词搜到（小写）。两个字母的拼音首字母容易和股票撞上（by 是白银也是比亚迪的开头），不放。
        let keywords: [String]
    }

    private static func hf(_ code: String, _ name: String, _ kind: String, _ keywords: [String]) -> Entry {
        Entry(symbol: Symbol(market: .hf, code: code)!, name: name, kind: kind, keywords: keywords)
    }

    private static func wh(_ code: String, _ name: String, _ keywords: [String]) -> Entry {
        Entry(symbol: Symbol(market: .wh, code: code)!, name: name, kind: "外汇", keywords: keywords)
    }

    /// 腾讯行情接口取得到的品种（2026 年 9 月实测）。常用的排在前面，同样匹配时先列出来。
    public static let entries: [Entry] = [
        hf("XAU", "伦敦金", "贵金属", ["现货黄金", "黄金", "金价", "gold", "xauusd", "ljj", "xhhj"]),
        hf("GC", "纽约黄金", "贵金属", ["美黄金", "comex黄金", "黄金期货", "黄金", "gold", "nyhj", "mhj"]),
        hf("XAG", "伦敦银", "贵金属", ["现货白银", "白银", "silver", "xagusd", "ldy", "xhby"]),
        hf("SI", "纽约白银", "贵金属", ["美白银", "白银期货", "白银", "silver", "nyby", "mby"]),
        hf("XPT", "纽约铂金", "贵金属", ["铂金", "白金", "platinum", "nybj"]),
        hf("CL", "纽约原油", "能源", ["美原油", "wti原油", "原油", "wti", "crude", "oil", "nyyy", "myy"]),
        hf("OIL", "布伦特原油", "能源", ["布油", "原油", "brent", "crude", "bltyy"]),
        hf("NG", "美国天然气", "能源", ["天然气", "natural gas", "gas", "mgtrq", "trq"]),
        hf("HG", "美铜", "期货", ["纽约铜", "铜", "copper"]),
        hf("ES", "标普500指数期货", "期货", ["标普期货", "美股期货", "标普500", "s&p", "sp500", "bpqh"]),
        hf("HSI", "恒生指数期货", "期货", ["恒指期货", "hszsqh", "hzqh"]),
        hf("S", "美国大豆", "期货", ["美豆", "大豆", "soybean", "mgdd"]),
        hf("C", "美国玉米", "期货", ["美玉米", "玉米", "corn", "mgym"]),
        hf("W", "美国小麦", "期货", ["美麦", "小麦", "wheat", "mgxm"]),
        wh("USDCNY", "美元人民币", ["美元", "人民币", "汇率", "usd", "cny", "myrmb"]),
        wh("USDX", "美元指数", ["美元", "dxy", "dollar index", "myzs"]),
        wh("HKDCNY", "港元人民币", ["港元", "港币", "人民币", "hkd", "gyrmb", "gbrmb"]),
        wh("EURCNY", "欧元人民币", ["欧元", "人民币", "eur", "oyrmb"]),
        wh("GBPCNY", "英镑人民币", ["英镑", "人民币", "gbp", "ybrmb"]),
        wh("CNYJPY", "人民币日元", ["日元", "日币", "人民币", "jpy", "rmbry"]),
        wh("AUDCNY", "澳元人民币", ["澳元", "人民币", "aud", "ayrmb"]),
        wh("CADCNY", "加元人民币", ["加元", "人民币", "cad", "jyrmb"]),
        wh("CHFCNY", "瑞郎人民币", ["瑞郎", "瑞士法郎", "人民币", "chf", "rlrmb"]),
        wh("SGDCNY", "新加坡元人民币", ["新加坡元", "新元", "人民币", "sgd", "xjpyrmb"]),
        wh("EURUSD", "欧元美元", ["欧元", "美元", "eur", "usd", "oymy"]),
        wh("GBPUSD", "英镑美元", ["英镑", "美元", "gbp", "usd", "ybmy"]),
        wh("USDJPY", "美元日元", ["美元", "日元", "usd", "jpy", "myry"]),
        wh("AUDUSD", "澳元美元", ["澳元", "美元", "aud", "usd", "aymy"]),
        wh("NZDUSD", "新西兰元美元", ["纽元", "新西兰元", "美元", "nzd", "usd", "xxlymy"]),
        wh("USDCAD", "美元加元", ["美元", "加元", "usd", "cad", "myjy"]),
        wh("USDCHF", "美元瑞郎", ["美元", "瑞郎", "usd", "chf", "myrl"]),
        wh("USDHKD", "美元港元", ["美元", "港元", "港币", "usd", "hkd", "mygy"]),
        wh("USDSGD", "美元新加坡元", ["美元", "新加坡元", "usd", "sgd", "myxjpy"]),
        wh("EURGBP", "欧元英镑", ["欧元", "英镑", "eur", "gbp", "oyyb"]),
    ]

    /// 按关键词找品种：代码、名称完全相同的排最前，其次是别名完全相同的，再次是开头相同的，最后是包含的
    /// （只有中文、至少两个字时才算包含）。搜索结果排在股票前面，回车添加的是第一条，所以字母要多打几个才算：
    /// 至少两个字母才算完全相同（cl 是纽约原油），至少三个才看开头（打 a 不会冒出澳元）。
    /// 同一档里按品种表的顺序，最多 limit 个。
    public static func search(_ query: String, limit: Int = 6) -> [SearchResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return [] }
        let isChinese = text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        let exact = text.count >= (isChinese ? 1 : 2)
        let prefix = text.count >= (isChinese ? 1 : 3)
        var ranked: [(rank: Int, index: Int, entry: Entry)] = []
        for (index, entry) in entries.enumerated() {
            let names = [entry.symbol.code.lowercased(), entry.symbol.rawValue.lowercased(), entry.name.lowercased()]
            let words = names + entry.keywords
            let rank: Int
            if exact, names.contains(text) {
                rank = 0
            } else if exact, entry.keywords.contains(text) {
                rank = 1
            } else if prefix, words.contains(where: { $0.hasPrefix(text) }) {
                rank = 2
            } else if isChinese, text.count >= 2, words.contains(where: { $0.contains(text) }) {
                rank = 3
            } else {
                continue
            }
            ranked.append((rank, index, entry))
        }
        return ranked
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .prefix(max(limit, 0))
            .map { SearchResult(symbol: $0.entry.symbol, name: $0.entry.name, typeCode: $0.entry.kind) }
    }
}
