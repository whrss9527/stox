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

    public init(
        symbol: Symbol, name: String = "", alias: String? = nil, pinned: Bool = false,
        alert: PriceAlert = PriceAlert(), holding: Holding? = nil
    ) {
        self.symbol = symbol
        self.name = name
        self.alias = alias
        self.pinned = pinned
        self.alert = alert
        self.holding = holding
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
        case symbol, name, alias, pinned, alert, holding
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
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(alias, forKey: .alias)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(alert, forKey: .alert)
        try c.encodeIfPresent(holding, forKey: .holding)
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
    case custom, gainers, losers

    public func apply(_ items: [WatchItem], quotes: [Symbol: Quote]) -> [WatchItem] {
        guard self != .custom else { return items }
        return items.enumerated().sorted { a, b in
            switch (quotes[a.element.symbol]?.changePercent, quotes[b.element.symbol]?.changePercent) {
            case let (x?, y?) where x != y:
                return self == .gainers ? x > y : x < y
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
