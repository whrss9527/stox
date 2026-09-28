import Foundation

/// 解析腾讯行情接口 `https://qt.gtimg.cn/utf8/q=sh600519,hk00700,usAAPL` 的返回。
///
/// 每只证券一行：`v_sh600519="1~贵州茅台~600519~1239.58~1237.00~...";`，字段以 `~` 分隔。
/// 沪深北、港股、美股共用下列字段位置：
///
/// | 下标 | 含义 |
/// |---|---|
/// | 1 | 名称 |
/// | 2 | 交易所代码（`600519`、`00700`、`AAPL.OQ`、`.IXIC`） |
/// | 3 / 4 / 5 | 现价 / 昨收 / 今开 |
/// | 6 | 成交量（A 股单位为手，港美股为股） |
/// | 30 | 时间（`20260928141019`、`2026/09/28 13:55:11`、`2026-09-25 16:00:01`） |
/// | 31 / 32 | 涨跌额 / 涨跌幅% |
/// | 33 / 34 | 最高 / 最低 |
/// | 35 | A 股为 `价格/成交量/成交额(元)`，美股为币种 |
/// | 37 | 成交额（A 股单位为万元，港美股为元） |
/// | 38 / 39 | 换手率%（港股在第 59 位） / 市盈率 |
/// | 45 | 总市值（亿；指数为成分股总市值，不展示） |
/// | 47 / 48 | A 股：涨停价 / 跌停价；港美股：52 周最高 / 最低 |
/// | 67 / 68 | A 股：52 周最高 / 最低（美股的 67 是当天的成交均价，即成交额除以成交量，没有用） |
///
/// 无效代码不会出现在返回里。
public enum TencentQuoteParser {
    public static func parse(_ text: String) -> [Symbol: Quote] {
        var quotes: [Symbol: Quote] = [:]
        for (key, payload) in records(in: text) {
            guard let symbol = Symbol(key), let quote = parseRecord(symbol: symbol, payload: payload) else { continue }
            quotes[symbol] = quote
        }
        return quotes
    }

    /// 从 `v_KEY="PAYLOAD";` 序列中取出 (KEY, PAYLOAD)。
    static func records(in text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var cursor = text.startIndex
        while let prefix = text.range(of: "v_", range: cursor..<text.endIndex) {
            guard let assign = text.range(of: "=\"", range: prefix.upperBound..<text.endIndex),
                  let close = text.range(of: "\"", range: assign.upperBound..<text.endIndex)
            else { break }
            let key = String(text[prefix.upperBound..<assign.lowerBound])
            let payload = String(text[assign.upperBound..<close.lowerBound])
            cursor = close.upperBound
            guard !key.isEmpty, key.count <= 24, !key.contains(where: { $0.isWhitespace }) else { continue }
            result.append((key, payload))
        }
        return result
    }

    static func parseRecord(symbol: Symbol, payload: String) -> Quote? {
        let fields = payload.split(separator: "~", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard fields.count > 38 else { return nil }

        func number(_ index: Int) -> Double? {
            guard index < fields.count, !fields[index].isEmpty else { return nil }
            return Double(fields[index])
        }
        func positive(_ index: Int) -> Double? {
            guard let value = number(index), value > 0 else { return nil }
            return value
        }

        let name = fields[1]
        guard !name.isEmpty, let price = number(3), let previousClose = number(4) else { return nil }

        let region = symbol.market.region
        let isCN = region == .cn
        let isIndex = symbol.isIndex

        var volume = number(6) ?? 0
        var amount: Double = 0
        switch region {
        case .cn:
            volume *= 100  // 手 → 股
            let parts = fields[35].split(separator: "/")
            if parts.count == 3, let yuan = Double(parts[2]) {
                amount = yuan
            } else {
                amount = (number(37) ?? 0) * 10_000
            }
        case .hk:
            if isIndex {
                // 港股指数的第 6、37 位都是成交额（万港元），没有成交量。
                volume = 0
                amount = (number(37) ?? 0) * 10_000
            } else {
                amount = number(37) ?? 0
            }
        case .us:
            // 美股指数的成交额字段数值不可靠，不展示。
            amount = isIndex ? 0 : (number(37) ?? 0)
        }

        return Quote(
            symbol: symbol,
            name: name,
            price: price,
            previousClose: previousClose,
            open: number(5) ?? 0,
            high: number(33) ?? 0,
            low: number(34) ?? 0,
            change: number(31),
            changePercent: number(32),
            volume: volume,
            amount: amount,
            turnoverRate: positive(region == .hk ? 59 : 38),
            // 亏损公司的市盈率是负数，照常显示；指数只在有值时显示（A 股指数有平均市盈率）。
            peRatio: isIndex ? positive(39) : number(39).flatMap { $0 == 0 ? nil : $0 },
            marketCap: isIndex ? nil : positive(45).map { $0 * 100_000_000 },
            limitUp: isCN ? positive(47) : nil,
            limitDown: isCN ? positive(48) : nil,
            high52Week: positive(isCN ? 67 : 48),
            low52Week: positive(isCN ? 68 : 49),
            timestamp: parseTimestamp(fields[30], timeZone: region.timeZone),
            priceDecimals: isIndex ? 2 : decimalPlaces(of: fields[3], fallback: fields[4]),
            exchangeCode: fields[2].isEmpty ? nil : fields[2]
        )
    }

    /// 兼容 `20260928141019`、`2026/09/28 13:55:11`、`2026-09-25 16:00:01` 三种写法。
    static func parseTimestamp(_ text: String, timeZone: TimeZone) -> Date? {
        let digits = text.filter(\.isASCIIDigit)
        guard digits.count == 14 else { return nil }
        let chars = Array(digits)
        func int(_ from: Int, _ length: Int) -> Int? { Int(String(chars[from..<(from + length)])) }
        var components = DateComponents()
        components.year = int(0, 4)
        components.month = int(4, 2)
        components.day = int(6, 2)
        components.hour = int(8, 2)
        components.minute = int(10, 2)
        components.second = int(12, 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    static func decimalPlaces(of text: String, fallback: String) -> Int {
        func places(_ s: String) -> Int? {
            guard let dot = s.firstIndex(of: ".") else { return nil }
            return s.distance(from: s.index(after: dot), to: s.endIndex)
        }
        let value = places(text) ?? places(fallback) ?? 2
        return min(max(value, 2), 4)
    }
}
