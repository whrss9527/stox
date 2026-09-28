import XCTest
@testable import StoxCore

final class PortfolioTests: XCTestCase {
    private func quote(_ raw: String, price: Double, previousClose: Double) -> Quote {
        Quote(symbol: Symbol(raw)!, name: raw, price: price, previousClose: previousClose)
    }

    func testPosition() throws {
        let holding = Holding(shares: 100, cost: 1200)
        let position = try XCTUnwrap(Portfolio.position(holding, quote: quote("sh600519", price: 1239.58, previousClose: 1237)))
        XCTAssertEqual(position.marketValue, 123_958, accuracy: 0.001)
        XCTAssertEqual(position.costValue, 120_000)
        XCTAssertEqual(position.totalProfit, 3958, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(position.totalProfitPercent), 3.2983, accuracy: 0.0001)
        XCTAssertEqual(position.dayProfit, 258, accuracy: 0.001)
    }

    func testFreeSharesHaveNoPercent() throws {
        let position = try XCTUnwrap(Portfolio.position(Holding(shares: 10, cost: 0), quote: quote("usAAPL", price: 341.07, previousClose: 335.92)))
        XCTAssertEqual(position.totalProfit, 3410.7, accuracy: 0.001)
        XCTAssertNil(position.totalProfitPercent)
    }

    func testNoPriceNoPosition() {
        XCTAssertNil(Portfolio.position(Holding(shares: 100, cost: 10), quote: quote("sz000001", price: 0, previousClose: 11.3)))
        XCTAssertNil(Portfolio.position(Holding(shares: 0, cost: 10), quote: quote("sz000001", price: 11.29, previousClose: 11.3)))
    }

    func testSummariesPerCurrency() throws {
        let items = [
            WatchItem(symbol: Symbol("usAAPL")!, holding: Holding(shares: 10, cost: 300)),
            WatchItem(symbol: Symbol("sh600519")!, holding: Holding(shares: 100, cost: 1200)),
            WatchItem(symbol: Symbol("sz000001")!, holding: Holding(shares: 1000, cost: 12)),
            WatchItem(symbol: Symbol("hk00700")!),
            WatchItem(symbol: Symbol("sh510300")!, holding: Holding(shares: 500, cost: 4)),
        ]
        let quotes: [Symbol: Quote] = [
            Symbol("usAAPL")!: quote("usAAPL", price: 341.07, previousClose: 335.92),
            Symbol("sh600519")!: quote("sh600519", price: 1239.58, previousClose: 1237),
            Symbol("sz000001")!: quote("sz000001", price: 11.29, previousClose: 11.30),
            Symbol("hk00700")!: quote("hk00700", price: 440, previousClose: 436.6),
        ]
        let summaries = Portfolio.summaries(items: items, quotes: quotes)
        XCTAssertEqual(summaries.map(\.region), [.cn, .us], "没有持仓的港股不出现，按 A 股、港股、美股排序")
        let cn = summaries[0]
        XCTAssertEqual(cn.count, 2, "没有行情的 510300 不计入")
        XCTAssertEqual(cn.marketValue, 123_958 + 11_290, accuracy: 0.001)
        XCTAssertEqual(cn.costValue, 132_000)
        XCTAssertEqual(cn.totalProfit, 3248, accuracy: 0.001)
        XCTAssertEqual(cn.dayProfit, 258 - 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cn.dayProfitPercent), 248 / (135_248 - 248) * 100, accuracy: 0.0001)
        let us = summaries[1]
        XCTAssertEqual(us.totalProfit, 410.7, accuracy: 0.001)
        XCTAssertEqual(us.region.currencyName, "美元")
    }

    func testHoldingIsSavedAndInvalidOnesAreDropped() throws {
        let item = WatchItem(symbol: Symbol("sh600519")!, name: "贵州茅台", holding: Holding(shares: 100, cost: 1200.5))
        let data = try XCTUnwrap(Watchlist.encode([item]))
        XCTAssertEqual(Watchlist.decode(data), [item])

        let json = #"""
        [{"symbol":"sh600519","holding":{"shares":-5,"cost":10}},
         {"symbol":"hk00700","holding":"garbage"},
         {"symbol":"usAAPL","holding":{"shares":2.5,"cost":300}}]
        """#
        let decoded = try XCTUnwrap(Watchlist.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.map(\.symbol.rawValue), ["sh600519", "hk00700", "usAAPL"], "持仓读不懂时只丢掉持仓")
        XCTAssertNil(decoded[0].holding)
        XCTAssertNil(decoded[1].holding)
        XCTAssertEqual(decoded[2].holding, Holding(shares: 2.5, cost: 300))

        let old = #"[{"symbol":"sh600519","name":"贵州茅台","pinned":true,"alert":{}}]"#
        XCTAssertNil(try XCTUnwrap(Watchlist.decode(Data(old.utf8))).first?.holding, "旧版本保存的数据没有持仓")
    }

    func testMoneyFormatting() {
        XCTAssertEqual(QuoteFormatter.money(3958), "3958.00")
        XCTAssertEqual(QuoteFormatter.money(123_958), "12.40万")
        XCTAssertEqual(QuoteFormatter.money(-2_500_000_000), "-25.00亿")
        XCTAssertEqual(QuoteFormatter.signedMoney(258), "+258.00")
        XCTAssertEqual(QuoteFormatter.signedMoney(-123_456), "-12.35万")
        XCTAssertEqual(QuoteFormatter.signedMoney(0.001), "0.00")
        XCTAssertEqual(QuoteFormatter.plain(100), "100")
        XCTAssertEqual(QuoteFormatter.plain(2.5), "2.5")
        XCTAssertEqual(QuoteFormatter.plain(0.1234), "0.1234")
        XCTAssertEqual(QuoteFormatter.plain(1_234_567.891), "1234567.891", "不用科学计数法，也不丢精度")
    }
}

final class SymbolListTests: XCTestCase {
    func testParsesPastedList() throws {
        let result = try XCTUnwrap(SymbolInput.parseList("600519, 00700  AAPL\nus.IXIC、600519；腾讯"))
        XCTAssertEqual(result.symbols.map(\.rawValue), ["sh600519", "hk00700", "usAAPL", "us.IXIC"])
        XCTAssertEqual(result.rejected, ["腾讯"])
    }

    func testSingleOrNamesAreNotALists() {
        XCTAssertNil(SymbolInput.parseList("600519"))
        XCTAssertNil(SymbolInput.parseList("  600519  "))
        XCTAssertNil(SymbolInput.parseList("贵州 茅台"))
        XCTAssertNil(SymbolInput.parseList("腾讯 700"), "只认出一个代码时按普通搜索处理")
        XCTAssertNil(SymbolInput.parseList("600519 600519"), "去重后只剩一个")
    }
}

final class WatchlistSortTests: XCTestCase {
    func testSortsByChangeAndKeepsMissingQuotesLast() {
        let items = ["sh600519", "hk00700", "usAAPL", "sz000001", "hkHSI"].map { WatchItem(symbol: Symbol($0)!) }
        func quote(_ raw: String, _ percent: Double) -> (Symbol, Quote) {
            (Symbol(raw)!, Quote(symbol: Symbol(raw)!, name: raw, price: 10, previousClose: 10, changePercent: percent))
        }
        let quotes = Dictionary(uniqueKeysWithValues: [
            quote("sh600519", 0.56), quote("hk00700", 0.73), quote("usAAPL", -0.16), quote("sz000001", 0.56),
        ])
        XCTAssertEqual(WatchlistSort.custom.apply(items, quotes: quotes).map(\.symbol.rawValue),
                       ["sh600519", "hk00700", "usAAPL", "sz000001", "hkHSI"])
        XCTAssertEqual(WatchlistSort.gainers.apply(items, quotes: quotes).map(\.symbol.rawValue),
                       ["hk00700", "sh600519", "sz000001", "usAAPL", "hkHSI"], "涨跌幅相同的保持原来的顺序，没有行情的排最后")
        XCTAssertEqual(WatchlistSort.losers.apply(items, quotes: quotes).map(\.symbol.rawValue),
                       ["usAAPL", "sh600519", "sz000001", "hk00700", "hkHSI"])
    }
}

final class MenuBarProfitTests: XCTestCase {
    func testDayProfitParts() {
        let summaries = [
            PortfolioSummary(region: .cn, marketValue: 147_000, costValue: 145_000, dayProfit: 688, count: 2),
            PortfolioSummary(region: .hk, marketValue: 87_960, costValue: 76_000, dayProfit: -12_345.6, count: 1),
            PortfolioSummary(region: .us, marketValue: 3_404, costValue: 3_000, dayProfit: 0.001, count: 1),
        ]
        let parts = MenuBarTicker.dayProfitParts(summaries)
        XCTAssertEqual(parts.map(\.text), ["今日", "+¥688", "-HK$1.23万", "$0.00"])
        XCTAssertEqual(parts.map(\.direction), [.flat, .up, .down, .flat], "颜色和正负号一致，不到一分钱的算平")
        XCTAssertEqual(parts.first?.role, .name)
        XCTAssertTrue(MenuBarTicker.dayProfitParts([]).isEmpty)
    }

    func testCompactMoney() {
        XCTAssertEqual(QuoteFormatter.compactMoney(12.9), "12.90")
        XCTAssertEqual(QuoteFormatter.compactMoney(688.4), "688")
        XCTAssertEqual(QuoteFormatter.compactMoney(11_960), "1.20万")
        XCTAssertEqual(QuoteFormatter.compactMoney(250_000_000), "2.50亿")
    }

    func testNoteIsSavedAndEmptyNotesAreDropped() throws {
        let item = WatchItem(symbol: Symbol("sh600519")!, name: "贵州茅台", note: "等回调到 1200 再加仓")
        let data = try XCTUnwrap(Watchlist.encode([item]))
        XCTAssertEqual(Watchlist.decode(data), [item])
        let json = #"[{"symbol":"hk00700","note":""},{"symbol":"usAAPL","note":42}]"#
        let decoded = try XCTUnwrap(Watchlist.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.map(\.symbol.rawValue), ["hk00700", "usAAPL"])
        XCTAssertNil(decoded[0].note)
        XCTAssertNil(decoded[1].note, "备注读不懂时只丢掉备注")
    }
}

final class ExportTests: XCTestCase {
    func testExportedCodesPasteBackIn() throws {
        let text = Watchlist.exportText(Watchlist.defaults)
        XCTAssertEqual(text, "sh000001 sz399001 sz399006 hkHSI us.IXIC sh600519 hk00700 usAAPL")
        let parsed = try XCTUnwrap(SymbolInput.parseList(text))
        XCTAssertEqual(parsed.symbols, Watchlist.defaults.map(\.symbol), "粘贴回搜索框能认出全部代码，顺序不变")
        XCTAssertTrue(parsed.rejected.isEmpty)
        let brk = [WatchItem(symbol: Symbol("usBRK.B")!), WatchItem(symbol: Symbol("bj920819")!)]
        XCTAssertEqual(SymbolInput.parseList(Watchlist.exportText(brk))?.symbols, brk.map(\.symbol))
    }
}

final class TradeTests: XCTestCase {
    func testBuyingAveragesTheCost() throws {
        let holding = Holding(shares: 100, cost: 1200)
        let more = try XCTUnwrap(holding.buying(shares: 100, at: 1300))
        XCTAssertEqual(more.shares, 200)
        XCTAssertEqual(more.cost, 1250, accuracy: 1e-9)
        let free = try XCTUnwrap(holding.buying(shares: 100, at: 0))
        XCTAssertEqual(free.cost, 600, accuracy: 1e-9, "送股摊薄成本")
        XCTAssertNil(holding.buying(shares: 0, at: 1300))
        XCTAssertNil(holding.buying(shares: 10, at: -1))
    }

    func testSellingKeepsTheCost() throws {
        let holding = Holding(shares: 300, cost: 12.5)
        let fewer = try XCTUnwrap(holding.selling(shares: 100))
        XCTAssertEqual(fewer, Holding(shares: 200, cost: 12.5))
        let none = try XCTUnwrap(holding.selling(shares: 300))
        XCTAssertEqual(none.shares, 0)
        XCTAssertFalse(none.isValid, "全部卖出后由调用方清掉持仓")
        XCTAssertNil(holding.selling(shares: 301), "不能卖得比持有的多")
        XCTAssertNil(holding.selling(shares: -1))
    }
}

final class CloseSummaryTests: XCTestCase {
    private func time(_ text: String, _ region: MarketRegion) -> Date {
        TencentQuoteParser.parseTimestamp(text, timeZone: region.timeZone)!
    }

    private let summary = PortfolioSummary(region: .cn, marketValue: 147_000, costValue: 145_000, dayProfit: 688, count: 2)

    func testSendsOnceAfterTheClose() throws {
        let note = try XCTUnwrap(CloseSummary.due(
            region: .cn, phase: .closed, summary: summary,
            latestQuoteTime: time("20260928150003", .cn), now: time("20260928160000", .cn), lastSentDay: nil
        ))
        XCTAssertEqual(note.day, "2026-09-28")
        XCTAssertEqual(note.title, "A股收盘 今日盈亏 +688.00")
        XCTAssertEqual(note.body, "今日 +0.47%，持仓盈亏 +2000.00（+1.38%），市值 14.70万人民币")
        XCTAssertNil(CloseSummary.due(
            region: .cn, phase: .closed, summary: summary,
            latestQuoteTime: time("20260928150003", .cn), now: time("20260928200000", .cn), lastSentDay: "2026-09-28"
        ), "今天已经发过")
        // 半夜才打开：还算前一个交易日的，补发一次。
        let late = try XCTUnwrap(CloseSummary.due(
            region: .cn, phase: .closed, summary: summary,
            latestQuoteTime: time("20260928150003", .cn), now: time("20260929020000", .cn), lastSentDay: "2026-09-25"
        ))
        XCTAssertEqual(late.day, "2026-09-28")
        XCTAssertNil(CloseSummary.due(
            region: .cn, phase: .closed, summary: summary,
            latestQuoteTime: time("20260928150003", .cn), now: time("20260929080000", .cn), lastSentDay: "2026-09-25"
        ), "第二天早上不再发前一天的")
    }

    func testSkipsWhileTradingOnHolidaysAndWithoutHoldings() {
        let quoteTime = time("20260928150003", .cn)
        let now = time("20260928160000", .cn)
        XCTAssertNil(CloseSummary.due(region: .cn, phase: .lunchBreak, summary: summary, latestQuoteTime: quoteTime, now: now, lastSentDay: nil))
        XCTAssertNil(CloseSummary.due(region: .cn, phase: .trading, summary: summary, latestQuoteTime: quoteTime, now: now, lastSentDay: nil))
        XCTAssertNil(CloseSummary.due(region: .cn, phase: .closed, summary: nil, latestQuoteTime: quoteTime, now: now, lastSentDay: nil))
        // 国庆假期：最新行情还是节前的。
        XCTAssertNil(CloseSummary.due(
            region: .cn, phase: .closed, summary: summary,
            latestQuoteTime: quoteTime, now: time("20261002160000", .cn), lastSentDay: nil
        ))
    }

    func testUSSendsWhenAfterHoursStart() throws {
        let us = PortfolioSummary(region: .us, marketValue: 3400, costValue: 3000, dayProfit: -10.5, count: 1)
        let note = try XCTUnwrap(CloseSummary.due(
            region: .us, phase: .afterHours, summary: us,
            latestQuoteTime: time("2026-09-28 16:00:01", .us), now: time("2026-09-28 16:05:00", .us), lastSentDay: "2026-09-25"
        ))
        XCTAssertEqual(note.title, "美股收盘 今日盈亏 -10.50")
        XCTAssertEqual(note.day, "2026-09-28", "按美东的日期")
    }
}

final class FilterTests: XCTestCase {
    func testFiltersByMarketAndHoldings() {
        var items = Watchlist.defaults
        XCTAssertEqual(WatchlistFilter.available(for: items), [.all, .cn, .hk, .us], "没有持仓时不显示“持仓”")
        items[5].holding = Holding(shares: 100, cost: 1200)
        XCTAssertEqual(WatchlistFilter.available(for: items), [.all, .cn, .hk, .us, .holdings])
        XCTAssertEqual(WatchlistFilter.hk.apply(items).map(\.symbol.rawValue), ["hkHSI", "hk00700"])
        XCTAssertEqual(WatchlistFilter.holdings.apply(items).map(\.symbol.rawValue), ["sh600519"])
        XCTAssertEqual(WatchlistFilter.all.apply(items).count, 8)

        let onlyCN = items.filter { $0.symbol.market.region == .cn && $0.holding == nil }
        XCTAssertEqual(WatchlistFilter.available(for: onlyCN), [], "只有一个市场、没有持仓时不显示筛选")
        XCTAssertEqual(WatchlistFilter.effective(.us, items: onlyCN), .all, "选中的市场没有了就回到全部")
        XCTAssertEqual(WatchlistFilter.effective(.hk, items: items), .hk)
    }
}

final class TableTests: XCTestCase {
    func testHoldingsTable() {
        let moutai = Symbol("sh600519")!
        let tencent = Symbol("hk00700")!
        let items = [
            WatchItem(symbol: Symbol("sh000001")!, name: "上证指数"),
            WatchItem(symbol: moutai, name: "贵州茅台", holding: Holding(shares: 100, cost: 1200)),
            WatchItem(symbol: tencent, name: "腾讯控股", holding: Holding(shares: 200, cost: 380)),
            WatchItem(symbol: Symbol("usAAPL")!, name: "苹果", holding: Holding(shares: 10, cost: 300)),
        ]
        let quotes: [Symbol: Quote] = [
            moutai: Quote(symbol: moutai, name: "贵州茅台", price: 1243.88, previousClose: 1237),
            tencent: Quote(symbol: tencent, name: "腾讯控股", price: 439.8, previousClose: 436.6, priceDecimals: 3),
        ]
        let rows = Portfolio.tableText(items: items, quotes: quotes).components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 3, "指数没有持仓，苹果没有行情，都不列")
        XCTAssertEqual(rows[0], "名称\t代码\t币种\t持有\t成本价\t现价\t市值\t持仓盈亏\t盈亏比例\t今日盈亏")
        XCTAssertEqual(rows[1], "贵州茅台\t600519\tCNY\t100\t1200\t1243.88\t124388.00\t4388.00\t3.66%\t688.00")
        XCTAssertEqual(rows[2], "腾讯控股\t00700\tHKD\t200\t380\t439.800\t87960.00\t11960.00\t15.74%\t640.00")
        XCTAssertEqual(Portfolio.tableText(items: Array(items.prefix(1)), quotes: quotes), "", "没有持仓时是空的")
    }
}
