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
