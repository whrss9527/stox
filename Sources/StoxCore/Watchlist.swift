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
    /// 分组，比如“科技”“长期持有”；不分组时为 nil。
    public var group: String? {
        didSet { group = Self.normalizedGroup(group) }
    }
    /// 用“记一笔”记下的买卖，最早的在前，最多留 `Trade.limit` 笔。全部卖出、持仓清掉以后也还留着。
    public var trades: [Trade]

    /// 分组名最多这么多个字。
    public static let groupNameLimit = 10

    public init(
        symbol: Symbol, name: String = "", alias: String? = nil, pinned: Bool = false,
        alert: PriceAlert = PriceAlert(), holding: Holding? = nil, note: String? = nil, group: String? = nil,
        trades: [Trade] = []
    ) {
        self.symbol = symbol
        self.name = name
        self.alias = alias
        self.pinned = pinned
        self.alert = alert
        self.holding = holding
        self.note = note
        self.group = Self.normalizedGroup(group)
        self.trades = trades
    }

    /// 分组名去掉首尾空白，太长的截断，空的当作不分组。
    public static func normalizedGroup(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(groupNameLimit))
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
        case symbol, name, alias, pinned, alert, holding, note, group, trades
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
        group = Self.normalizedGroup(try? c.decodeIfPresent(String.self, forKey: .group))
        // 一笔一笔地读，读不懂的那笔（比如以后的版本加的新类型）跳过，别的照常。
        trades = (try? c.decodeIfPresent([Lenient<Trade>].self, forKey: .trades))?.compactMap(\.value) ?? []
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
        try c.encodeIfPresent(group, forKey: .group)
        if !trades.isEmpty {
            try c.encode(trades, forKey: .trades)
        }
    }
}

public enum Watchlist {
    /// 首次启动时的默认自选：三大市场的主要指数加几只常见股票。
    public static let defaults: [WatchItem] = [
        item("sh000001", "上证指数", alias: "上证", pinned: true),  // l10n-ignore
        item("sz399001", "深证成指"),  // l10n-ignore
        item("sz399006", "创业板指"),  // l10n-ignore
        item("hkHSI", "恒生指数"),  // l10n-ignore
        item("us.IXIC", "纳斯达克"),  // l10n-ignore
        item("sh600519", "贵州茅台"),  // l10n-ignore
        item("hk00700", "腾讯控股"),  // l10n-ignore
        item("usAAPL", "苹果"),  // l10n-ignore
    ]

    /// 常用指数：默认自选里的几个指数，自选删空以后一键加回来。
    public static var commonIndices: [WatchItem] {
        defaults.filter { $0.symbol.isIndex }
    }

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

    /// 自选里用到的分组，按第一次出现的顺序。
    public static func groups(in items: [WatchItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    /// 编辑分组：members 里的都放进 name 这个分组（原来在别的分组里的也移过来，每只只能在一个分组里）；
    /// 原来在 old 这个分组、这次没勾上的移出分组。改名时 old 是原来的名字。name 为空时相当于解散 old。
    public static func settingGroup(_ name: String, members: Set<Symbol>, replacing old: String?, in items: [WatchItem]) -> [WatchItem] {
        let group = WatchItem.normalizedGroup(name)
        return items.map { item in
            var updated = item
            if group != nil, members.contains(item.symbol) {
                updated.group = group
            } else if let old, item.group == old {
                updated.group = nil
            }
            return updated
        }
    }

    /// 筛选着的时候拖动排序。visible 是列表里看得见的那几只（按显示的顺序，也就是它们在自选里的先后），
    /// 把其中 source 那几只挪到 destination（都按看得见的算）。看得见的几只只在它们原来占的那些位置之间换，
    /// 看不见的原地不动。visible 和自选对不上时不改。
    public static func moving(_ items: [WatchItem], visible: [Symbol], fromOffsets source: IndexSet, toOffset destination: Int) -> [WatchItem] {
        let wanted = Set(visible)
        let slots = items.indices.filter { wanted.contains(items[$0].symbol) }
        guard slots.map({ items[$0].symbol }) == visible,
              source.allSatisfy({ $0 < visible.count }), (0...visible.count).contains(destination)
        else { return items }
        let shown = slots.map { items[$0] }
        let moved = source.map { shown[$0] }
        var rest = shown.indices.filter { !source.contains($0) }.map { shown[$0] }
        rest.insert(contentsOf: moved, at: destination - source.filter { $0 < destination }.count)
        var result = items
        for (slot, item) in zip(slots, rest) {
            result[slot] = item
        }
        return result
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

/// 菜单栏行情怎么排：一行（名称、价格、涨跌幅连成一行），或者上下两行（价格在上、涨跌幅在下，字小一些，
/// 同样的地方能放下更多只）。
public enum TickerLayout: String, CaseIterable, Sendable, Identifiable {
    case inline, stacked

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inline: return L("一行")
        case .stacked: return L("上下两行")
        }
    }
}

/// 上下两行排法里的一段：左边一行字（名称，或者盈亏前面的“今日”“持仓”），右边上下两行（价格和涨跌幅，
/// 或者盈亏金额和比例）。右边只有一个数时，它单独占一行、上下居中。
public struct StackedTickerBlock: Equatable, Sendable {
    public var label: TickerPart?
    public var top: TickerPart?
    public var bottom: TickerPart?

    public init(label: TickerPart? = nil, top: TickerPart? = nil, bottom: TickerPart? = nil) {
        self.label = label
        self.top = top
        self.bottom = bottom
    }

    /// 读屏和诊断用的一行字，和一行排法的文字一样：`上证 3829.87 +0.16%`。
    public var text: String { [label, top, bottom].compactMap { $0?.text }.joined(separator: " ") }
}

/// 菜单栏上显示哪一种盈亏。
public enum MenuBarProfit: String, CaseIterable, Sendable, Identifiable {
    /// 今日盈亏。
    case day
    /// 持仓盈亏（按现价算的浮动盈亏）。
    case total

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: return L("今日盈亏")
        case .total: return L("持仓盈亏")
        }
    }

    /// 菜单栏上数字前面的字。
    public var label: String {
        switch self {
        case .day: return L("今日")
        case .total: return L("持仓")
        }
    }

    func value(_ summary: PortfolioSummary) -> Double {
        self == .day ? summary.dayProfit : summary.totalProfit
    }

    /// 今日盈亏相对昨日市值，持仓盈亏相对成本。
    func percent(_ summary: PortfolioSummary) -> Double? {
        self == .day ? summary.dayProfitPercent : summary.totalProfitPercent
    }
}

public enum MenuBarTicker {
    /// 菜单栏上的今日盈亏，例如“今日 +¥688 -HK$120”，每种货币一段；给了汇率时折成人民币合成一段。
    /// 隐藏金额时换成相对昨日市值的比例，例如“今日 +0.62%”。没有持仓时返回空数组。
    public static func dayProfitParts(
        _ summaries: [PortfolioSummary], rates: ExchangeRates? = nil, hidingAmounts: Bool = false
    ) -> [TickerPart] {
        profitParts(summaries, kind: .day, rates: rates, hidingAmounts: hidingAmounts)
    }

    /// 菜单栏上的盈亏：今日盈亏（“今日 +¥688”）或者持仓盈亏（“持仓 +¥1.29万”），每种货币一段，给了汇率时折成人民币合成一段。
    /// 隐藏金额时换成比例（今日盈亏相对昨日市值，持仓盈亏相对成本）。没有持仓时返回空数组。
    public static func profitParts(
        _ summaries: [PortfolioSummary], kind: MenuBarProfit, rates: ExchangeRates? = nil, hidingAmounts: Bool = false
    ) -> [TickerPart] {
        guard !summaries.isEmpty else { return [] }
        var parts = [TickerPart(role: .name, text: kind.label, direction: .flat)]
        for summary in shownProfits(summaries, rates: rates) {
            let amount = profitAmount(summary, kind: kind)
            let text = hidingAmounts ? kind.percent(summary).map(QuoteFormatter.percent) ?? "--" : amount.text
            parts.append(TickerPart(role: .percent, text: text, direction: amount.direction))
        }
        return parts
    }

    /// 有好几种货币并且拿到了汇率时，折成人民币只显示一个数，省地方。
    private static func shownProfits(_ summaries: [PortfolioSummary], rates: ExchangeRates?) -> [PortfolioSummary] {
        Portfolio.combined(summaries, rates: rates).map { [$0] } ?? summaries
    }

    /// 菜单栏上的盈亏金额：`+¥688`、`-HK$1.20万`。颜色和正负号一致，不到一分钱的算平。
    private static func profitAmount(_ summary: PortfolioSummary, kind: MenuBarProfit) -> TickerPart {
        let value = kind.value(summary)
        let direction: PriceDirection = value >= 0.005 ? .up : (value <= -0.005 ? .down : .flat)
        let sign = direction == .up ? "+" : (direction == .down ? "-" : "")
        return TickerPart(role: .price, text: sign + summary.region.currencySymbol + QuoteFormatter.compactMoney(abs(value)), direction: direction)
    }

    /// 一只证券排成上下两行：名称在左边，价格在上、涨跌幅在下；设置里关掉的那项没有。
    public static func stacked(_ parts: [TickerPart]) -> StackedTickerBlock {
        StackedTickerBlock(
            label: parts.first { $0.role == .name },
            top: parts.first { $0.role == .price },
            bottom: parts.first { $0.role == .percent }
        )
    }

    /// 盈亏排成上下两行：每种货币一段，上面是金额、下面是比例（今日盈亏相对昨日市值，持仓盈亏相对成本），
    /// “今日”“持仓”写在第一段左边；隐藏金额时只有比例。给了汇率时折成人民币合成一段。没有持仓时返回空数组。
    public static func stackedProfit(
        _ summaries: [PortfolioSummary], kind: MenuBarProfit, rates: ExchangeRates? = nil, hidingAmounts: Bool = false
    ) -> [StackedTickerBlock] {
        shownProfits(summaries, rates: rates).enumerated().map { index, summary in
            let amount = profitAmount(summary, kind: kind)
            let percent = kind.percent(summary).map {
                TickerPart(role: .percent, text: QuoteFormatter.percent($0), direction: amount.direction)
            }
            return StackedTickerBlock(
                label: index == 0 ? TickerPart(role: .name, text: kind.label, direction: .flat) : nil,
                top: hidingAmounts ? nil : amount,
                bottom: hidingAmounts ? percent ?? TickerPart(role: .percent, text: "--", direction: .flat) : percent
            )
        }
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
    /// 雪球个股页：SH600519、00700、HKHSI、AAPL、.IXIC。场外基金、期货外汇没有，返回 nil。
    public static func xueqiu(_ symbol: Symbol) -> URL? {
        let path: String
        switch symbol.market {
        case .sh, .sz, .bj: path = symbol.market.rawValue.uppercased() + symbol.code
        case .hk: path = symbol.isIndex ? "HK" + symbol.code : symbol.code
        case .us: path = symbol.code
        case .jj, .hf, .wh: return nil
        }
        return URL(string: "https://xueqiu.com/S/" + path)
    }

    /// 在网页上看这一只：股票和指数去雪球，场外基金去天天基金，期货外汇去新浪财经（美元指数在新浪叫 DINIW）。
    /// 返回按钮上写的名字和地址。
    public static func web(_ symbol: Symbol) -> (title: String, url: URL)? {
        switch symbol.market {
        case .jj:
            return URL(string: "https://fund.eastmoney.com/\(symbol.code).html").map { (L("天天基金"), $0) }
        case .hf:
            return URL(string: "https://finance.sina.com.cn/futures/quotes/\(symbol.code).shtml").map { (L("新浪财经"), $0) }
        case .wh:
            let code = symbol.code == "USDX" ? "DINIW" : symbol.code
            return URL(string: "https://finance.sina.com.cn/money/forex/hq/\(code).shtml").map { (L("新浪财经"), $0) }
        default:
            return xueqiu(symbol).map { (L("雪球"), $0) }
        }
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
/// 列表上方的筛选：全部、某个市场、有持仓的，或者某个分组。
public enum WatchlistFilter: Hashable, Sendable {
    case all, cn, hk, us, global, holdings
    case group(String)

    /// 存进设置里的写法：`all`、`cn`、`hk`、`us`、`global`、`holdings`，分组是 `group:名字`。
    public var id: String {
        switch self {
        case .all: return "all"
        case .cn: return "cn"
        case .hk: return "hk"
        case .us: return "us"
        case .global: return "global"
        case .holdings: return "holdings"
        case .group(let name): return "group:" + name
        }
    }

    public init?(id: String) {
        switch id {
        case "all": self = .all
        case "cn": self = .cn
        case "hk": self = .hk
        case "us": self = .us
        case "global": self = .global
        case "holdings": self = .holdings
        default:
            guard id.hasPrefix("group:"), let name = WatchItem.normalizedGroup(String(id.dropFirst(6))) else { return nil }
            self = .group(name)
        }
    }

    public func apply(_ items: [WatchItem]) -> [WatchItem] {
        switch self {
        case .all: return items
        case .cn: return items.filter { $0.symbol.market.region == .cn }
        case .hk: return items.filter { $0.symbol.market.region == .hk }
        case .us: return items.filter { $0.symbol.market.region == .us }
        case .global: return items.filter { $0.symbol.market.region == .global }
        case .holdings: return items.filter { $0.holding != nil }
        case .group(let name): return items.filter { $0.group == name }
        }
    }

    /// 值得显示的筛选：自选涉及两个以上市场时列出这些市场；有的有持仓、有的没有时加上“持仓”；
    /// 再按第一次出现的顺序列出各个分组（整个自选都在同一个分组里时不列）。
    /// 只剩“全部”一项时返回空数组，不显示筛选。
    public static func available(for items: [WatchItem]) -> [WatchlistFilter] {
        var result: [WatchlistFilter] = [.all]
        let regions = Set(items.map { $0.symbol.market.region })
        if regions.count > 1 {
            if regions.contains(.cn) { result.append(.cn) }
            if regions.contains(.hk) { result.append(.hk) }
            if regions.contains(.us) { result.append(.us) }
            if regions.contains(.global) { result.append(.global) }
        }
        let held = items.filter { $0.holding != nil }.count
        if held > 0, held < items.count {
            result.append(.holdings)
        }
        for name in Watchlist.groups(in: items) where items.contains(where: { $0.group != name }) {
            result.append(.group(name))
        }
        return result.count > 1 ? result : []
    }

    /// 实际生效的筛选：选中的那一项已经不适用（比如美股都删了）时回到全部。
    public static func effective(_ selected: WatchlistFilter, items: [WatchItem]) -> WatchlistFilter {
        available(for: items).contains(selected) ? selected : .all
    }
}
