import XCTest
@testable import StoxCore

final class FundTests: XCTestCase {
    // 2026-09-29 从腾讯行情接口抓取的场外基金（原样）。
    static let sample = #"""
    v_jj161725="161725~招商中证白酒指数A~0.0000~0.0000~~0.5166~2.2327~-0.8065~2026-09-28~";
    v_jj110022="110022~易方达消费行业股票~0.0000~0.0000~~2.7540~2.7540~-0.9709~2026-09-28~";
    v_jj000000="000000~没有净值~0.0000~0.0000~~0.0000~0.0000~0~~";
    """#

    func testParsesNetAssetValue() throws {
        let quotes = TencentQuoteParser.parse(Self.sample)
        XCTAssertEqual(quotes.count, 2, "没有净值的跳过")
        let fund = try XCTUnwrap(quotes[Symbol("jj161725")!])
        XCTAssertEqual(fund.name, "招商中证白酒指数A")
        XCTAssertEqual(fund.price, 0.5166, "现价是单位净值")
        XCTAssertEqual(fund.cumulativeNAV, 2.2327)
        XCTAssertEqual(fund.changePercent, -0.8065)
        XCTAssertEqual(fund.previousClose, 0.5166 / (1 - 0.008065), accuracy: 1e-9, "上一个净值按涨跌幅倒推")
        XCTAssertEqual(fund.change, fund.price - fund.previousClose, accuracy: 1e-12)
        XCTAssertEqual(fund.direction, .down)
        XCTAssertEqual(fund.priceDecimals, 4)
        XCTAssertEqual(fund.timestamp, MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 15)))
        XCTAssertTrue(fund.hasTraded, "有净值就算，提醒和盈亏照常")
        XCTAssertNil(fund.orderBook)
        XCTAssertNil(fund.high52Week)
        XCTAssertEqual(quotes[Symbol("jj110022")!]?.cumulativeNAV, 2.754)
    }

    func testSymbols() throws {
        let fund = try XCTUnwrap(Symbol("jj161725"))
        XCTAssertTrue(fund.isFund)
        XCTAssertFalse(fund.isIndex)
        XCTAssertEqual(fund.market.region, .cn, "算在人民币里")
        XCTAssertEqual(fund.market.label, "基")
        XCTAssertNil(Symbol("jj16172"), "场外基金是 6 位代码")
        XCTAssertEqual(SymbolInput.parse("161725.OF"), fund)
        XCTAssertEqual(SymbolInput.parse("jj161725"), fund)
        XCTAssertEqual(SymbolInput.parse("161725")?.rawValue, "sz161725", "只输数字时还是当作场内的 LOF")
        XCTAssertTrue(SymbolInput.isExplicitCode("161725.OF"))

        XCTAssertNil(QuoteLinks.xueqiu(fund))
        XCTAssertEqual(QuoteLinks.web(fund)?.title, "天天基金")
        XCTAssertEqual(QuoteLinks.web(fund)?.url.absoluteString, "https://fund.eastmoney.com/161725.html")
        XCTAssertEqual(QuoteLinks.web(Symbol("sh600519")!)?.title, "雪球")
    }

    func testHoldingAndDayProfit() throws {
        let fund = try XCTUnwrap(TencentQuoteParser.parse(Self.sample)[Symbol("jj161725")!])
        // 1 万份，成本 0.5 元：市值是份额 × 单位净值，今日盈亏是份额 × 净值的涨跌。
        let position = try XCTUnwrap(Portfolio.position(Holding(shares: 10_000, cost: 0.5), quote: fund))
        XCTAssertEqual(position.marketValue, 5166, accuracy: 1e-9)
        XCTAssertEqual(position.totalProfit, 166, accuracy: 1e-9)
        XCTAssertEqual(position.dayProfit, 10_000 * fund.change, accuracy: 1e-9)
        XCTAssertLessThan(position.dayProfit, 0)
    }
}
