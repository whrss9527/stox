import XCTest
@testable import StoxCore

/// 菜单栏上下两行的排法：价格在上、涨跌幅在下；盈亏是金额在上、比例在下。
final class StackedTickerTests: XCTestCase {
    private let summaries = [
        PortfolioSummary(region: .cn, marketValue: 147_000, costValue: 145_000, dayProfit: 688, count: 2),
        PortfolioSummary(region: .hk, marketValue: 87_960, costValue: 76_000, dayProfit: -12_345.6, count: 1),
        PortfolioSummary(region: .us, marketValue: 3_404, costValue: 3_000, dayProfit: 0.001, count: 1),
    ]

    func testStacksPriceOverPercent() {
        let maotai = Symbol("sh600519")!
        let items = [
            WatchItem(symbol: maotai, name: "贵州茅台", alias: "茅台", pinned: true),
            WatchItem(symbol: Symbol("hk00700")!, name: "腾讯控股", pinned: true),
        ]
        let quotes = [maotai: Quote(symbol: maotai, name: "贵州茅台", price: 1239.58, previousClose: 1237, change: 2.58, changePercent: 0.21)]
        let blocks = MenuBarTicker.entries(items: items, quotes: quotes, options: TickerOptions()).map(MenuBarTicker.stacked)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].label?.text, "茅台", "名称在左边")
        XCTAssertEqual(blocks[0].top?.text, "1239.58", "价格在上")
        XCTAssertEqual(blocks[0].bottom?.text, "+0.21%", "涨跌幅在下")
        XCTAssertEqual(blocks[0].top?.direction, .up)
        XCTAssertEqual(blocks[0].bottom?.direction, .up)
        XCTAssertEqual(blocks[0].text, "茅台 1239.58 +0.21%", "读屏和诊断用的文字和一行排法一样")
        XCTAssertEqual(blocks[1].text, "腾讯控股 -- --", "还没有行情")

        let noName = MenuBarTicker.entries(items: items, quotes: quotes, options: TickerOptions(showName: false)).map(MenuBarTicker.stacked)
        XCTAssertNil(noName[0].label)
        XCTAssertEqual(noName[0].top?.text, "1239.58")
        XCTAssertEqual(noName[0].bottom?.text, "+0.21%")

        let percentOnly = MenuBarTicker.entries(items: items, quotes: quotes, options: TickerOptions(showPrice: false))
            .map(MenuBarTicker.stacked)
        XCTAssertNil(percentOnly[0].top, "关掉价格时只剩涨跌幅，它单独一行")
        XCTAssertEqual(percentOnly[0].bottom?.text, "+0.21%")
    }

    func testStacksProfitAmountOverPercent() {
        let blocks = MenuBarTicker.stackedProfit(summaries, kind: .day)
        XCTAssertEqual(blocks.count, 3, "每种货币一段")
        XCTAssertEqual(blocks.map { $0.label?.text }, ["今日", nil, nil], "“今日”只写在第一段左边")
        let inline = MenuBarTicker.profitParts(summaries, kind: .day)
        let hidden = MenuBarTicker.profitParts(summaries, kind: .day, hidingAmounts: true)
        XCTAssertEqual(blocks.map { $0.top?.text }, inline.dropFirst().map(\.text), "上面是金额，和一行排法里的一样")
        XCTAssertEqual(blocks.map { $0.bottom?.text }, hidden.dropFirst().map(\.text), "下面是比例，和隐藏金额时一样")
        XCTAssertEqual(blocks.map { $0.bottom?.direction }, [.up, .down, .flat], "比例和金额同样的颜色")

        let hiding = MenuBarTicker.stackedProfit(summaries, kind: .total, hidingAmounts: true)
        XCTAssertEqual(hiding.map { $0.top?.text }, [nil, nil, nil], "隐藏金额时没有金额")
        XCTAssertEqual(hiding.map { $0.bottom?.text }, ["+1.38%", "+15.74%", "+13.47%"], "持仓盈亏相对成本")

        let rates = ExchangeRates(hkdCNY: 0.85, usdCNY: 7)
        let combined = MenuBarTicker.stackedProfit(summaries, kind: .total, rates: rates)
        XCTAssertEqual(combined.map(\.text), ["持仓 +¥1.50万 +6.50%"], "有汇率时折成人民币合成一段")
        XCTAssertTrue(MenuBarTicker.stackedProfit([], kind: .day).isEmpty)
    }

    func testLayoutSyncs() throws {
        let settings = SyncedSettings(showName: true, tickerLayout: TickerLayout.stacked.rawValue)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(SyncedSettings.self, from: data), settings)
        let old = try JSONDecoder().decode(SyncedSettings.self, from: Data(#"{"showName":true}"#.utf8))
        XCTAssertNil(old.tickerLayout, "旧版本写的没有这一项")
        XCTAssertEqual(
            SyncedSettings(tickerLayout: "stacked").overlaid(with: SyncedSettings(refreshInterval: 5)).tickerLayout, "stacked",
            "对方没有这一项时保留自己的"
        )
        XCTAssertEqual(TickerLayout(rawValue: "stacked"), .stacked)
        XCTAssertEqual(TickerLayout.allCases.map(\.title), ["一行", "上下两行"])
    }
}
