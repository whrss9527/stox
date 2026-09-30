import Foundation

/// A 股涨跌榜的排法。行业是另一种榜：申万一级行业按涨跌幅排，每个行业带着领涨的那只。
public enum RankKind: String, CaseIterable, Sendable, Identifiable {
    case gainers, losers, turnover, industries

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gainers: return L("涨幅榜")
        case .losers: return L("跌幅榜")
        case .turnover: return L("成交额")
        case .industries: return L("行业")
        }
    }
}

/// 行业榜上的一个行业。
public struct IndustryEntry: Equatable, Sendable, Identifiable {
    public var code: String
    public var name: String
    /// 行业指数的涨跌幅（%）。
    public var changePercent: Double
    /// 领涨的那只：代码、名称、涨跌幅。
    public var leader: RankEntry?

    public init(code: String, name: String, changePercent: Double, leader: RankEntry? = nil) {
        self.code = code
        self.name = name
        self.changePercent = changePercent
        self.leader = leader
    }

    public var id: String { code }

    public var direction: PriceDirection { PriceDirection(changePercent) }
}

/// 榜上的一只。
public struct RankEntry: Equatable, Sendable, Identifiable {
    public var symbol: Symbol
    public var name: String
    public var price: Double
    public var change: Double
    /// 涨跌幅（%）。
    public var changePercent: Double
    /// 成交额（元）。
    public var amount: Double
    /// 换手率（%）；没有时为 nil。
    public var turnoverRate: Double?

    public init(symbol: Symbol, name: String, price: Double, change: Double, changePercent: Double, amount: Double, turnoverRate: Double? = nil) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.change = change
        self.changePercent = changePercent
        self.amount = amount
        self.turnoverRate = turnoverRate
    }

    public var id: String { symbol.rawValue }

    public var direction: PriceDirection { PriceDirection(change) }

    /// 新股：上市首日名字前面有 N，注册制的新股上市后前 5 天有 C。这几天没有涨跌幅限制，常常挤满涨幅榜。
    public var isNewListing: Bool { name.hasPrefix("N") || name.hasPrefix("C") }
}

/// 腾讯的 A 股涨跌榜（沪深京全部 A 股）：
/// `https://proxy.finance.qq.com/cgi/cgi-bin/rank/hs/getBoardRankList?_appver=11.17.0&board_code=aStock&sort_type=priceRatio&direct=down&offset=0&count=20`。
///
/// sort_type 是 `priceRatio`（涨跌幅）或 `turnover`（成交额），direct 是 `down`（从大到小）或 `up`（从小到大）。
/// 港股、美股的榜单不在这个接口里。
public enum TencentRank {
    public static let endpoint = "https://proxy.finance.qq.com/cgi/cgi-bin/rank/hs/getBoardRankList"

    /// 行业榜：`rank/pt/getRank?board_type=hy&sort_type=priceRatio&direct=down&offset=0&count=40`，一共 31 个行业。
    public static let industryEndpoint = "https://proxy.finance.qq.com/cgi/cgi-bin/rank/pt/getRank"

    public static func industryURL(count: Int) -> URL? {
        var components = URLComponents(string: industryEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "board_type", value: "hy"),
            URLQueryItem(name: "sort_type", value: "priceRatio"),
            URLQueryItem(name: "direct", value: "down"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "count", value: String(max(count, 1))),
        ]
        return components?.url
    }

    public static func url(_ kind: RankKind, count: Int) -> URL? {
        guard kind != .industries else { return industryURL(count: count) }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "_appver", value: "11.17.0"),
            URLQueryItem(name: "board_code", value: "aStock"),
            URLQueryItem(name: "sort_type", value: kind == .turnover ? "turnover" : "priceRatio"),
            URLQueryItem(name: "direct", value: kind == .losers ? "up" : "down"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "count", value: String(max(count, 1))),
        ]
        return components?.url
    }

    /// 解析 `{"code":0,"data":{"rank_list":[{"code":"sz301716","name":"N鸿富诚","zxj":"578.88","zd":"502.02","zdf":"653.16",
    /// "hsl":"51.82","turnover":"380275",…}],"total":5571}}`。数字都是字符串：zxj 现价、zd 涨跌额、zdf 涨跌幅（%）、
    /// hsl 换手率（%）、turnover 成交额（万元）。认不出的代码、没有现价的跳过；code 不是 0 时返回空数组。
    public static func parse(_ data: Data) -> [RankEntry] {
        rows(data).compactMap(entry)
    }

    /// 解析行业榜：每一行的 `code` 是板块代码（`pt01801180`），`zdf` 是行业的涨跌幅，`lzg` 是领涨股
    /// （`{"code":"sh600657","name":"信达地产","zd":"0.31","zdf":"10.10","zxj":"3.38"}`）。
    public static func parseIndustries(_ data: Data) -> [IndustryEntry] {
        rows(data).compactMap { row in
            guard let code = row["code"] as? String, let name = row["name"] as? String, !name.isEmpty,
                  let percent = number(row["zdf"]), percent.isFinite
            else { return nil }
            return IndustryEntry(code: code, name: name, changePercent: percent, leader: (row["lzg"] as? [String: Any]).flatMap(entry))
        }
    }

    /// `{"code":0,"data":{"rank_list":[…]}}` 里的 rank_list；code 不是 0、格式不对时是空的。
    private static func rows(_ data: Data) -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? Int ?? (root["code"] as? String).flatMap(Int.init)) == 0,
              let list = (root["data"] as? [String: Any])?["rank_list"] as? [[String: Any]]
        else { return [] }
        return list
    }

    /// 数字大多是字符串，偶尔是数。
    private static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        return (value as? NSNumber)?.doubleValue
    }

    private static func entry(_ row: [String: Any]) -> RankEntry? {
        guard let code = row["code"] as? String, let symbol = Symbol(code),
              let name = row["name"] as? String, !name.isEmpty,
              let price = number(row["zxj"]), price > 0, price.isFinite
        else { return nil }
        return RankEntry(
            symbol: symbol,
            name: name,
            price: price,
            change: number(row["zd"]) ?? 0,
            changePercent: number(row["zdf"]) ?? 0,
            amount: (number(row["turnover"]) ?? 0) * 10_000,
            turnoverRate: number(row["hsl"])
        )
    }
}
