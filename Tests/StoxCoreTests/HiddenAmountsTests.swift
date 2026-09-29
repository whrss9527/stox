import XCTest
@testable import StoxCore

/// “隐藏金额”：菜单栏、收盘小结和止盈止损提醒里不写金额，只写比例。
final class HiddenAmountsTests: XCTestCase {
    private let summaries = [
        PortfolioSummary(region: .cn, marketValue: 147_000, costValue: 145_000, dayProfit: 688, count: 2),
        PortfolioSummary(region: .hk, marketValue: 87_960, costValue: 76_000, dayProfit: -12_345.6, count: 1),
        PortfolioSummary(region: .us, marketValue: 3_404, costValue: 3_000, dayProfit: 0.001, count: 1),
    ]

    func testMenuBarShowsThePercent() {
        let parts = MenuBarTicker.dayProfitParts(summaries, hidingAmounts: true)
        XCTAssertEqual(parts.map(\.text), ["今日", "+0.47%", "-12.31%", "0.00%"], "相对昨日市值的比例，每种货币一段")
        XCTAssertEqual(parts.map(\.direction), [.flat, .up, .down, .flat], "颜色和不隐藏时一样")

        // 有汇率时折成人民币合成一段：(688 - 12345.6 × 0.85 + 0.001 × 7) / 昨日市值合计。
        let rates = ExchangeRates(hkdCNY: 0.85, usdCNY: 7)
        let combined = MenuBarTicker.dayProfitParts(summaries, rates: rates, hidingAmounts: true)
        XCTAssertEqual(combined.map(\.text), ["今日", "-3.84%"])
        XCTAssertEqual(combined.last?.direction, .down)
    }

    func testMenuBarCanShowTheHoldingProfit() {
        // 持仓盈亏：市值减成本，隐藏金额时相对成本。
        let parts = MenuBarTicker.profitParts(summaries, kind: .total)
        XCTAssertEqual(parts.map(\.text), ["持仓", "+¥2000", "+HK$1.20万", "+$404"])
        XCTAssertEqual(parts.map(\.direction), [.flat, .up, .up, .up])
        let hidden = MenuBarTicker.profitParts(summaries, kind: .total, hidingAmounts: true)
        XCTAssertEqual(hidden.map(\.text), ["持仓", "+1.38%", "+15.74%", "+13.47%"])
        // 有汇率时折成人民币：(2000 + 11960 × 0.85 + 404 × 7) / (145000 + 76000 × 0.85 + 3000 × 7)。
        let rates = ExchangeRates(hkdCNY: 0.85, usdCNY: 7)
        XCTAssertEqual(MenuBarTicker.profitParts(summaries, kind: .total, rates: rates).map(\.text), ["持仓", "+¥1.50万"])
        XCTAssertEqual(MenuBarTicker.profitParts(summaries, kind: .total, rates: rates, hidingAmounts: true).map(\.text), ["持仓", "+6.50%"])
        XCTAssertEqual(MenuBarTicker.profitParts(summaries, kind: .day), MenuBarTicker.dayProfitParts(summaries), "今日盈亏和原来一样")
        XCTAssertEqual(MenuBarProfit.total.title, "持仓盈亏")
    }

    func testCloseSummaryLeavesOutAmounts() throws {
        let time = { (text: String) in TencentQuoteParser.parseTimestamp(text, timeZone: MarketRegion.cn.timeZone)! }
        let note = try XCTUnwrap(CloseSummary.due(
            region: .cn, phase: .closed, summary: summaries[0],
            latestQuoteTime: time("20260928150003"), now: time("20260928160000"), lastSentDay: nil,
            movers: [.init(name: "贵州茅台", changePercent: 0.56), .init(name: "平安银行", changePercent: -0.09)],
            hidingAmounts: true
        ))
        XCTAssertEqual(note.title, "A股收盘 今日盈亏 +0.47%")
        XCTAssertEqual(note.body, "持仓盈亏 +1.38%。涨得最多的是贵州茅台 +0.56%，跌得最多的是平安银行 -0.09%")
    }

    func testTakeProfitAlertLeavesOutTheAmount() throws {
        let symbol = Symbol("sh600519")!
        let time = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 10))!
        let quote = Quote(symbol: symbol, name: "贵州茅台", price: 1200, previousClose: 1200, open: 1200, volume: 100, timestamp: time)
        var trigger = AlertTrigger(
            symbol: symbol, name: "贵州茅台", condition: .profitAbove, threshold: 20, quote: quote,
            holding: Holding(shares: 100, cost: 1000)
        )
        XCTAssertEqual(trigger.body, "现价 1200.00，成本 1000.00，持仓盈亏 +20000.00（+20.00%）")
        trigger.hidesAmounts = true
        XCTAssertEqual(trigger.body, "现价 1200.00，成本 1000.00，持仓盈亏 +20.00%")

        // 成本是 0（送的股）时没有比例，写 ****。
        trigger.holding = Holding(shares: 100, cost: 0)
        XCTAssertEqual(trigger.body, "现价 1200.00，成本 0.00，持仓盈亏 ****")
    }
}
