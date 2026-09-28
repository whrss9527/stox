import Foundation

/// 自选列表里的一项。
public struct WatchItem: Hashable, Sendable, Identifiable {
    public var symbol: Symbol
    /// 缓存的名称，行情返回前先用它显示。
    public var name: String
    /// 菜单栏上显示的简称，为空时自动截取名称。
    public var alias: String?
    /// 是否显示在菜单栏。
    public var pinned: Bool
    public var alert: PriceAlert
    /// 持仓；没有填写时为 nil。
    public var holding: Holding?
    /// 备注，比如关注的理由；没有填写时为 nil。
    public var note: String?

    public init(
        symbol: Symbol, name: String = "", alias: String? = nil, pinned: Bool = false,
        alert: PriceAlert = PriceAlert(), holding: Holding? = nil, note: String? = nil
    ) {
        self.symbol = symbol
        self.name = name
        self.alias = alias
        self.pinned = pinned
        self.alert = alert
        self.holding = holding
        self.note = note
    }

    public var id: String { symbol.rawValue }

    public var displayName: String { name.isEmpty ? symbol.displayCode : name }

    /// 菜单栏上显示的名字：优先用户设置的简称，否则截断全称。
    public var tickerName: String {
        if let alias, !alias.trimmingCharacters(in: .whitespaces).isEmpty {
            return alias.trimmingCharacters(in: .whitespaces)
        }
        return NameAbbreviator.abbreviate(displayName)
    }
}

// 手写 Codable：新增字段时旧数据也能正常读出。
extension WatchItem: Codable {
    enum CodingKeys: String, CodingKey {
        case symbol, name, alias, pinned, alert, holding, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(Symbol.self, forKey: .symbol)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        alert = try c.decodeIfPresent(PriceAlert.self, forKey: .alert) ?? PriceAlert()
        // 持仓读不懂时当作没有，不影响这一项的其他内容。
        holding = (try? c.decodeIfPresent(Holding.self, forKey: .holding)).flatMap { $0.isValid ? $0 : nil }
        note = (try? c.decodeIfPresent(String.self, forKey: .note)).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(alias, forKey: .alias)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(alert, forKey: .alert)
        try c.encodeIfPresent(holding, forKey: .holding)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

public enum Watchlist {
    /// 首次启动时的默认自选：三大市场的主要指数加几只常见股票。
    public static let defaults: [WatchItem] = [
        item("sh000001", "上证指数", alias: "上证", pinned: true),
        item("sz399001", "深证成指"),
        item("sz399006", "创业板指"),
        item("hkHSI", "恒生指数"),
        item("us.IXIC", "纳斯达克"),
        item("sh600519", "贵州茅台"),
        item("hk00700", "腾讯控股"),
        item("usAAPL", "苹果"),
    ]

    private static func item(_ raw: String, _ name: String, alias: String? = nil, pinned: Bool = false) -> WatchItem {
        WatchItem(symbol: Symbol(raw)!, name: name, alias: alias, pinned: pinned)
    }

    /// 解码保存的自选列表，忽略无法识别的条目并去重。
    public static func decode(_ data: Data) -> [WatchItem]? {
        guard let decoded = try? JSONDecoder().decode([LossyWatchItem].self, from: data) else { return nil }
        return deduplicated(decoded.compactMap(\.item))
    }

    /// 同一只证券只保留第一次出现的那一项。
    public static func deduplicated(_ items: [WatchItem]) -> [WatchItem] {
        var seen = Set<Symbol>()
        return items.filter { seen.insert($0.symbol).inserted }
    }

    /// 复制出去的代码，用空格分开，粘贴到搜索框就能一次全部加回来（见 SymbolInput.parseList）。
    public static func exportText(_ items: [WatchItem]) -> String {
        items.map(\.symbol.rawValue).joined(separator: " ")
    }

    public static func encode(_ items: [WatchItem]) -> Data? {
        try? JSONEncoder().encode(items)
    }
}

/// 解码失败的条目变成 nil 而不是让整个列表解码失败，旧版本或别的设备写的数据也能读。
struct LossyWatchItem: Decodable {
    let item: WatchItem?

    init(from decoder: Decoder) throws {
        item = try? WatchItem(from: decoder)
    }
}

/// 菜单栏行情文字的组成部分，由 App 层负责着色和拼接。
public struct TickerPart: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case name, price, percent }

    public let role: Role
    public let text: String
    public let direction: PriceDirection

    public init(role: Role, text: String, direction: PriceDirection) {
        self.role = role
        self.text = text
        self.direction = direction
    }
}

public struct TickerOptions: Sendable, Equatable {
    public var showName: Bool
    public var showPrice: Bool
    public var showPercent: Bool

    public init(showName: Bool = true, showPrice: Bool = true, showPercent: Bool = true) {
        self.showName = showName
        self.showPrice = showPrice
        self.showPercent = showPercent
    }

    public var isEmpty: Bool { !showName && !showPrice && !showPercent }
}

public enum MenuBarTicker {
    /// 菜单栏上的今日盈亏，例如“今日 +¥688 -HK$120”，每种货币一段；给了汇率时折成人民币合成一段。
    /// 没有持仓时返回空数组。
    public static func dayProfitParts(_ summaries: [PortfolioSummary], rates: ExchangeRates? = nil) -> [TickerPart] {
        guard !summaries.isEmpty else { return [] }
        var parts = [TickerPart(role: .name, text: "今日", direction: .flat)]
        // 有好几种货币并且拿到了汇率时，折成人民币只显示一个数，省地方。
        let shown = Portfolio.combined(summaries, rates: rates).map { [$0] } ?? summaries
        for summary in shown {
            let value = summary.dayProfit
            // 颜色和正负号一致：不到一分钱的算平。
            let direction: PriceDirection = value >= 0.005 ? .up : (value <= -0.005 ? .down : .flat)
            let sign = direction == .up ? "+" : (direction == .down ? "-" : "")
            let text = sign + summary.region.currencySymbol + QuoteFormatter.compactMoney(abs(value))
            parts.append(TickerPart(role: .percent, text: text, direction: direction))
        }
        return parts
    }

    /// 每只“显示在菜单栏”的证券对应一组文字片段；没有固定项或全部选项关闭时返回空数组。
    public static func entries(items: [WatchItem], quotes: [Symbol: Quote], options: TickerOptions) -> [[TickerPart]] {
        guard !options.isEmpty else { return [] }
        return items.filter(\.pinned).map { item in
            let quote = quotes[item.symbol]
            let direction = quote?.direction ?? .flat
            var parts: [TickerPart] = []
            if options.showName {
                parts.append(TickerPart(role: .name, text: item.tickerName, direction: direction))
            }
            if options.showPrice {
                let text = quote.map { QuoteFormatter.price($0.price, decimals: $0.priceDecimals) } ?? "--"
                parts.append(TickerPart(role: .price, text: text, direction: direction))
            }
            if options.showPercent {
                let text = quote.map { QuoteFormatter.percent($0.changePercent) } ?? "--"
                parts.append(TickerPart(role: .percent, text: text, direction: direction))
            }
            return parts
        }
    }
}

public enum QuoteLinks {
    /// 雪球个股页：SH600519、00700、HKHSI、AAPL、.IXIC。
    public static func xueqiu(_ symbol: Symbol) -> URL? {
        let path: String
        switch symbol.market {
        case .sh, .sz, .bj: path = symbol.market.rawValue.uppercased() + symbol.code
        case .hk: path = symbol.isIndex ? "HK" + symbol.code : symbol.code
        case .us: path = symbol.code
        }
        return URL(string: "https://xueqiu.com/S/" + path)
    }
}

/// 自选列表的显示顺序。自定义顺序可以拖动；按涨跌幅排序时没有行情的排在最后，涨跌幅相同的保持原来的顺序。
public enum WatchlistSort: String, CaseIterable, Sendable {
    case custom, gainers, losers, holdingProfit

    /// 排序用的数：涨跌幅，或者持仓盈亏比例。没有的（没有行情、没有持仓）排在最后，保持原来的顺序。
    func key(_ item: WatchItem, quotes: [Symbol: Quote]) -> Double? {
        switch self {
        case .custom:
            return nil
        case .gainers, .losers:
            return quotes[item.symbol]?.changePercent
        case .holdingProfit:
            guard let holding = item.holding, let quote = quotes[item.symbol] else { return nil }
            return Portfolio.position(holding, quote: quote)?.totalProfitPercent
        }
    }

    public func apply(_ items: [WatchItem], quotes: [Symbol: Quote]) -> [WatchItem] {
        guard self != .custom else { return items }
        let descending = self != .losers
        return items.enumerated().sorted { a, b in
            switch (key(a.element, quotes: quotes), key(b.element, quotes: quotes)) {
            case let (x?, y?) where x != y:
                return descending ? x > y : x < y
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// 自选列表的筛选：全部、某个市场、有持仓的。
public enum WatchlistFilter: String, CaseIterable, Codable, Sendable {
    case all, cn, hk, us, holdings

    public func apply(_ items: [WatchItem]) -> [WatchItem] {
        switch self {
        case .all: return items
        case .cn: return items.filter { $0.symbol.market.region == .cn }
        case .hk: return items.filter { $0.symbol.market.region == .hk }
        case .us: return items.filter { $0.symbol.market.region == .us }
        case .holdings: return items.filter { $0.holding != nil }
        }
    }

    /// 值得显示的筛选：自选涉及两个以上市场时列出这些市场；有的有持仓、有的没有时加上“持仓”。
    /// 只剩“全部”一项时返回空数组，不显示筛选。
    public static func available(for items: [WatchItem]) -> [WatchlistFilter] {
        var result: [WatchlistFilter] = [.all]
        let regions = Set(items.map { $0.symbol.market.region })
        if regions.count > 1 {
            if regions.contains(.cn) { result.append(.cn) }
            if regions.contains(.hk) { result.append(.hk) }
            if regions.contains(.us) { result.append(.us) }
        }
        let held = items.filter { $0.holding != nil }.count
        if held > 0, held < items.count {
            result.append(.holdings)
        }
        return result.count > 1 ? result : []
    }

    /// 实际生效的筛选：选中的那一项已经不适用（比如美股都删了）时回到全部。
    public static func effective(_ selected: WatchlistFilter, items: [WatchItem]) -> WatchlistFilter {
        available(for: items).contains(selected) ? selected : .all
    }
}
