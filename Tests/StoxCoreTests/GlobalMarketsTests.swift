import XCTest
@testable import StoxCore

final class GlobalMarketsTests: XCTestCase {
    // 2026-09-29 从腾讯行情接口抓取（原样，和 A 股放在同一个请求里）。
    static let tencent = #"""
    v_hf_XAU="4141.36,0.64,4141.36,4141.71,4144.88,4113.30,14:00:00,4114.93,4117.01,0,0,0,2026-09-29,伦敦金（现货黄金）";
    v_hf_CL="94.12,1.64,94.05,94.07,94.74,93.00,13:57:04,92.60,93.53,0,2,7,2026-09-29,纽约原油";
    v_hf_W="727.81,-0.13,728.50,729.00,743.50,724.25,10:54:02,728.75,0.00,0,1,8,2026-09-29,美国小麦";
    v_whUSDCNY="310~美元人民币~USDCNY~6.7062~0~20260929140022~6.7100~6.7050~6.7086~6.7050~6.7062~6.7064~-0.0038~-0.06~0.17~-0.03~-0.20~-1.27~-4.02~7.1430~6.6950~2026-09-29";
    v_whUSDJPY="310~美元日元~USDJPY~157.3300~~20260929135653~157.3600~157.3600~157.5800~157.2000~157.3300~157.3400~-0.0300~-0.02~-0.03~1.94~-1.50~-2.93~0.43~163.9800~146.5800~2026-09-29";
    v_pv_none_match="1";
    """#

    // 同一时间新浪的国际期货（原样），字段位置和腾讯一样，价格多一位小数，第 1 位是空的。
    static let sina = #"""
    var hq_str_hf_GC="4172.014,,4171.400,4171.700,4176.200,4145.200,13:57:27,4168.400,4150.100,0,2,1,2026-09-29,纽约黄金,0";
    var hq_str_hf_NG="3.125,,3.125,3.126,3.156,3.120,13:57:20,3.106,3.149,0,5,3,2026-09-29,美国天然气,0";
    """#

    private func beijing(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute, second: second))!
    }

    func testParsesFuturesAndSpotMetals() throws {
        let quotes = TencentQuoteParser.parse(Self.tencent)
        XCTAssertEqual(quotes.count, 5, "查不到的 pv_none_match 不算")

        let gold = try XCTUnwrap(quotes[Symbol("hf_XAU")!])
        XCTAssertEqual(gold.name, "伦敦金", "括号里的说明去掉")
        XCTAssertEqual(gold.price, 4141.36)
        XCTAssertEqual(gold.previousClose, 4114.93)
        XCTAssertEqual(gold.open, 4117.01)
        XCTAssertEqual(gold.high, 4144.88)
        XCTAssertEqual(gold.low, 4113.30)
        XCTAssertEqual(gold.bid, 4141.36)
        XCTAssertEqual(gold.ask, 4141.71)
        XCTAssertEqual(gold.change, 26.43, accuracy: 1e-9)
        XCTAssertEqual(gold.changePercent, 26.43 / 4114.93 * 100, accuracy: 1e-9, "和接口给的 0.64% 一致")
        XCTAssertEqual(gold.timestamp, beijing(29, 14, 0), "日期加时间，北京时间")
        XCTAssertEqual(gold.priceDecimals, 2)
        XCTAssertTrue(gold.hasTraded, "没有成交量也算")
        XCTAssertNil(gold.orderBook)
        XCTAssertNil(gold.high52Week)

        let oil = try XCTUnwrap(quotes[Symbol("hf_CL")!])
        XCTAssertEqual(oil.name, "纽约原油")
        XCTAssertEqual(oil.direction, .up)
        XCTAssertEqual(oil.timestamp, beijing(29, 13, 57, 4))

        let wheat = try XCTUnwrap(quotes[Symbol("hf_W")!])
        XCTAssertEqual(wheat.open, 0, "还没开盘的今开是 0")
        XCTAssertTrue(wheat.hasTraded)
    }

    func testParsesForex() throws {
        let quotes = TencentQuoteParser.parse(Self.tencent)
        let usd = try XCTUnwrap(quotes[Symbol("whUSDCNY")!])
        XCTAssertEqual(usd.name, "美元人民币")
        XCTAssertEqual(usd.price, 6.7062)
        XCTAssertEqual(usd.previousClose, 6.71)
        XCTAssertEqual(usd.open, 6.705)
        XCTAssertEqual(usd.high, 6.7086)
        XCTAssertEqual(usd.low, 6.705)
        XCTAssertEqual(usd.bid, 6.7062)
        XCTAssertEqual(usd.ask, 6.7064)
        XCTAssertEqual(usd.change, -0.0038, accuracy: 1e-9)
        XCTAssertEqual(usd.high52Week, 7.143)
        XCTAssertEqual(usd.low52Week, 6.695)
        XCTAssertEqual(usd.timestamp, beijing(29, 14, 0, 22))
        XCTAssertEqual(usd.priceDecimals, 4)
        XCTAssertEqual(usd.direction, .down)

        let yen = try XCTUnwrap(quotes[Symbol("whUSDJPY")!])
        XCTAssertEqual(yen.priceDecimals, 2, "157.3300 末尾的 0 不算")
        XCTAssertEqual(QuoteFormatter.price(yen.price, decimals: yen.priceDecimals), "157.33")
    }

    func testParsesSinaFutures() throws {
        let symbols = [Symbol("hf_GC")!, Symbol("hf_NG")!]
        let quotes = SinaQuoteParser.parse(Self.sina, symbols: symbols)
        let gold = try XCTUnwrap(quotes[symbols[0]])
        XCTAssertEqual(gold.name, "纽约黄金")
        XCTAssertEqual(gold.price, 4172.014)
        XCTAssertEqual(gold.previousClose, 4168.4)
        XCTAssertEqual(gold.priceDecimals, 3)
        XCTAssertEqual(gold.timestamp, beijing(29, 13, 57, 27))
        XCTAssertEqual(quotes[symbols[1]]?.priceDecimals, 3)
        XCTAssertEqual(SinaProvider.code(for: symbols[0]), "hf_GC", "新浪的写法和腾讯一样")
    }

    func testSymbols() throws {
        let gold = try XCTUnwrap(Symbol("hf_XAU"))
        XCTAssertEqual(gold.market, .hf)
        XCTAssertEqual(gold.code, "XAU")
        XCTAssertEqual(gold.rawValue, "hf_XAU", "腾讯接口的写法带下划线")
        XCTAssertEqual(gold.displayCode, "XAU")
        XCTAssertEqual(gold.market.label, "期")
        XCTAssertEqual(gold.market.region, .global)
        XCTAssertTrue(gold.isGlobal)
        XCTAssertFalse(gold.isIndex)
        XCTAssertFalse(gold.canHold)
        XCTAssertTrue(gold.hasIntraday, "期货的分时来自新浪")
        XCTAssertFalse(gold.hasKline)
        XCTAssertEqual(Symbol("hfXAU"), gold)
        XCTAssertEqual(Symbol(market: .hf, code: "xau"), gold)

        let usd = try XCTUnwrap(Symbol("whUSDCNY"))
        XCTAssertEqual(usd.rawValue, "whUSDCNY")
        XCTAssertEqual(usd.market.label, "汇")
        XCTAssertEqual(Symbol("whUSDX")?.code, "USDX", "美元指数")
        XCTAssertNil(Symbol("whUSD"), "外汇是六个字母")
        XCTAssertNil(Symbol("whUSDCN1"))
        XCTAssertNil(Symbol("hf_"))

        XCTAssertTrue(Symbol("sh600519")!.canHold)
        XCTAssertFalse(Symbol("sh000001")!.canHold, "指数")
        XCTAssertFalse(Symbol("jj161725")!.hasIntraday)
        XCTAssertFalse(Symbol("jj161725")!.hasKline)
        XCTAssertFalse(usd.hasIntraday, "外汇没有分时")
        XCTAssertTrue(Symbol("usAAPL")!.hasIntraday && Symbol("usAAPL")!.hasKline)

        // 编码成腾讯的写法，旧版本认不出的会在同步时跳过（见 LossyWatchItem）。
        let data = try JSONEncoder().encode([gold, usd])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["hf_XAU","whUSDCNY"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Symbol].self, from: data), [gold, usd])
    }

    func testParsesInput() {
        XCTAssertEqual(SymbolInput.parse("hf_xau")?.rawValue, "hf_XAU")
        XCTAssertEqual(SymbolInput.parse("HF_CL")?.rawValue, "hf_CL")
        XCTAssertEqual(SymbolInput.parse("whusdcny")?.rawValue, "whUSDCNY")
        XCTAssertEqual(SymbolInput.parse("hfc")?.rawValue, "usHFC", "不带下划线的还是美股")
        XCTAssertEqual(SymbolInput.parse("whr")?.rawValue, "usWHR", "惠而浦不是外汇")
        XCTAssertEqual(SymbolInput.parse("WHUSDCNY")?.rawValue, "usWHUSDCNY", "外汇要小写前缀")
        XCTAssertTrue(SymbolInput.isExplicitCode("hf_XAU"))
        XCTAssertTrue(SymbolInput.isExplicitCode("whusdcny"))
        XCTAssertFalse(SymbolInput.isExplicitCode("whr"))
        XCTAssertEqual(SymbolInput.parseList("hf_XAU whUSDCNY 600519")?.symbols.map(\.rawValue), ["hf_XAU", "whUSDCNY", "sh600519"])
    }

    func testCatalogSearch() {
        func codes(_ query: String) -> [String] { GlobalCatalog.search(query).map(\.symbol.rawValue) }
        XCTAssertEqual(Array(codes("黄金").prefix(2)), ["hf_XAU", "hf_GC"], "现货排在期货前面")
        XCTAssertEqual(Array(codes("gold").prefix(2)), ["hf_XAU", "hf_GC"])
        XCTAssertEqual(codes("伦敦金"), ["hf_XAU"])
        XCTAssertEqual(codes("xau"), ["hf_XAU"])
        XCTAssertEqual(codes("hf_xau"), ["hf_XAU"])
        XCTAssertEqual(codes("usdcny"), ["whUSDCNY"])
        XCTAssertEqual(codes("美元指数"), ["whUSDX"])
        XCTAssertEqual(Array(codes("原油").prefix(2)), ["hf_CL", "hf_OIL"])
        XCTAssertEqual(codes("oil"), ["hf_OIL", "hf_CL"], "代码完全相同的排在别名前面")
        XCTAssertEqual(codes("美元").first, "whUSDCNY")
        XCTAssertTrue(codes("美元").contains("whUSDX"))
        XCTAssertEqual(codes("美元").count, 6, "最多 6 个")
        XCTAssertEqual(codes("日元"), ["whCNYJPY", "whUSDJPY"])
        XCTAssertTrue(codes("人民币").contains("whHKDCNY"), "中文按包含算")
        XCTAssertEqual(codes("zzz"), [])
        XCTAssertEqual(codes("茅台"), [])
        XCTAssertEqual(codes(" "), [])
        XCTAssertEqual(codes("a"), [], "一个字母什么都不算")
        XCTAssertEqual(codes("c"), [], "玉米的代码是 C，也要多打几个字")
        XCTAssertEqual(codes("hf_c"), ["hf_C", "hf_CL"], "完全相同的在前，开头相同的在后")
        XCTAssertEqual(codes("玉米"), ["hf_C"])
        XCTAssertEqual(codes("cl"), ["hf_CL"], "两个字母要完全相同")
        XCTAssertEqual(codes("au"), [], "两个字母不看开头")
        XCTAssertEqual(codes("aud").first, "whAUDCNY", "三个字母看开头")
        XCTAssertEqual(codes("by"), [], "两个字母的拼音首字母不放，比亚迪也是 by 开头")

        let result = GlobalCatalog.search("黄金")[0]
        XCTAssertEqual(result.name, "伦敦金")
        XCTAssertEqual(result.typeLabel, "贵金属")
        XCTAssertEqual(GlobalCatalog.search("usdcny")[0].typeLabel, "外汇")

        // 品种表里每个代码都能解析，不重复。
        let symbols = GlobalCatalog.entries.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertTrue(symbols.allSatisfy(\.isGlobal))
    }

    func testTradesAroundTheClockOnWeekdays() {
        // 2026-09-28 是周一；9 月还是夏令时，纽约比北京晚 12 小时。
        XCTAssertEqual(MarketClock.phase(for: .global, at: beijing(28, 5, 59)), .closed, "纽约周日 17:59")
        XCTAssertEqual(MarketClock.phase(for: .global, at: beijing(28, 6, 0)), .trading, "纽约周日 18:00 开盘")
        XCTAssertEqual(MarketClock.phase(for: .global, at: beijing(28, 12, 0)), .trading)
        XCTAssertEqual(MarketClock.phase(for: .global, at: beijing(29, 3, 0)), .trading, "半夜也在交易")
        XCTAssertEqual(MarketClock.phase(for: .global, at: beijing(26, 4, 59)), .trading, "纽约周五 16:59")
        XCTAssertEqual(MarketClock.phase(for: .global, at: beijing(26, 5, 0)), .closed, "纽约周五 17:00 收盘")
        XCTAssertEqual(MarketClock.phase(for: .global, at: beijing(26, 12, 0)), .closed, "周六")
        XCTAssertEqual(MarketClock.phase(for: .global, at: beijing(27, 12, 0)), .closed, "周日白天")

        // 圣诞这样的节日：该开着的时候行情停了几个小时，当休市；每天一小时的休息不算。
        let now = beijing(29, 14, 0)
        XCTAssertEqual(MarketClock.effectivePhase(for: .global, at: now, latestQuoteTime: beijing(29, 13, 59)), .trading)
        XCTAssertEqual(MarketClock.effectivePhase(for: .global, at: now, latestQuoteTime: beijing(29, 12, 30)), .trading)
        XCTAssertEqual(MarketClock.effectivePhase(for: .global, at: now, latestQuoteTime: beijing(29, 10, 0)), .closed)
        XCTAssertEqual(MarketClock.effectivePhase(for: .global, at: now, latestQuoteTime: nil), .trading)
        XCTAssertEqual(MarketClock.effectivePhase(for: .global, at: beijing(26, 12, 0), latestQuoteTime: beijing(26, 11, 59)), .closed)
    }

    func testFiltersAndLinks() throws {
        let items = ["sh600519", "hf_XAU", "whUSDCNY"].map { WatchItem(symbol: Symbol($0)!) }
        XCTAssertEqual(WatchlistFilter.available(for: items), [.all, .cn, .global])
        XCTAssertEqual(WatchlistFilter.global.apply(items).map(\.symbol.rawValue), ["hf_XAU", "whUSDCNY"])
        XCTAssertEqual(WatchlistFilter(id: "global"), .global)
        XCTAssertEqual(WatchlistFilter.global.id, "global")
        XCTAssertEqual(MarketRegion.global.displayName, "期货外汇")

        XCTAssertNil(QuoteLinks.xueqiu(Symbol("hf_XAU")!))
        XCTAssertEqual(QuoteLinks.web(Symbol("hf_XAU")!)?.title, "新浪财经")
        XCTAssertEqual(QuoteLinks.web(Symbol("hf_XAU")!)?.url.absoluteString, "https://finance.sina.com.cn/futures/quotes/XAU.shtml")
        XCTAssertEqual(QuoteLinks.web(Symbol("whUSDCNY")!)?.url.absoluteString, "https://finance.sina.com.cn/money/forex/hq/USDCNY.shtml")
        XCTAssertEqual(QuoteLinks.web(Symbol("whUSDX")!)?.url.absoluteString, "https://finance.sina.com.cn/money/forex/hq/DINIW.shtml")
    }

    func testNotCountedInHoldings() throws {
        let quotes = TencentQuoteParser.parse(Self.tencent)
        // 同步或备份里就算带着持仓，期货外汇也不算进合计。
        var gold = WatchItem(symbol: Symbol("hf_XAU")!)
        gold.holding = Holding(shares: 10, cost: 3000)
        XCTAssertTrue(Portfolio.summaries(items: [gold], quotes: quotes).isEmpty)
    }

    func testNoChartsRequested() async throws {
        let provider = TencentProvider(quoteEndpoint: "http://127.0.0.1:9/")
        let gold = Symbol("hf_XAU")!
        let intraday = try await provider.fetchIntraday(for: Symbol("whUSDCNY")!)
        XCTAssertNil(intraday, "外汇没有分时")
        let kline = try await provider.fetchKline(for: gold, period: .day, count: 5, exchangeCode: nil)
        XCTAssertNil(kline)
        let fiveDay = try await provider.fetchFiveDay(for: gold, exchangeCode: nil)
        XCTAssertNil(fiveDay)
        XCTAssertNil(TencentFundFlow.url(for: gold))
    }
}
