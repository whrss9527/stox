import XCTest
@testable import StoxCore

final class TradeLogTests: XCTestCase {
    private func time(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ region: MarketRegion) -> Date {
        region.calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private let moutai = Symbol("sh600519")!

    /// 茅台：昨收 1240，现价 1250，行情时间是 2026-09-29 10:00。
    private func quote(day: Int = 29) -> Quote {
        Quote(symbol: moutai, name: "贵州茅台", price: 1250, previousClose: 1240, open: 1242, volume: 1000,
              timestamp: time(2026, 9, day, 10, 0, .cn))
    }

    func testTradeDay() {
        // 盘中记的是今天。
        XCTAssertEqual(Trade.day(for: .cn, now: time(2026, 9, 29, 10, 0, .cn), latestQuoteTime: time(2026, 9, 29, 9, 59, .cn)),
                       "2026-09-29")
        // 第二天开盘前补记，算前一个交易日。
        XCTAssertEqual(Trade.day(for: .cn, now: time(2026, 9, 30, 8, 0, .cn), latestQuoteTime: time(2026, 9, 29, 15, 0, .cn)),
                       "2026-09-29")
        // 收盘以后记的还是今天。
        XCTAssertEqual(Trade.day(for: .cn, now: time(2026, 9, 29, 20, 0, .cn), latestQuoteTime: time(2026, 9, 29, 15, 0, .cn)),
                       "2026-09-29")
        // 周六记的算周五。
        XCTAssertEqual(Trade.day(for: .cn, now: time(2026, 9, 26, 10, 0, .cn), latestQuoteTime: time(2026, 9, 25, 15, 0, .cn)),
                       "2026-09-25")
        // 国庆休市的工作日，行情停在节前最后一天。
        XCTAssertEqual(Trade.day(for: .cn, now: time(2026, 10, 5, 10, 30, .cn), latestQuoteTime: time(2026, 9, 30, 15, 0, .cn)),
                       "2026-09-30")
        // 美股盘前成交的，行情还是前一天收盘的，也算今天。
        XCTAssertEqual(Trade.day(for: .us, now: time(2026, 9, 29, 5, 0, .us), latestQuoteTime: time(2026, 9, 28, 16, 0, .us)),
                       "2026-09-29")
        XCTAssertEqual(Trade.day(for: .hk, now: time(2026, 9, 29, 20, 0, .hk), latestQuoteTime: nil), "2026-09-29", "没有行情时按现在")
    }

    func testDayProfitCountsTodaysTrades() {
        let quote = quote()
        XCTAssertEqual(Portfolio.dayProfit(shares: 100, quote: quote, trades: []), 1000, "没记买卖时是股数 × 涨跌额")

        // 昨天有 100 股，今天 1245 又买了 100 股：昨天的按涨跌额 +1000，今天买的按现价减买入价 +500。
        let bought = [Trade(side: .buy, shares: 100, price: 1245, day: "2026-09-29")]
        XCTAssertEqual(Portfolio.dayProfit(shares: 200, quote: quote, trades: bought), 1500)
        // 和“现在的市值 − 昨收时的市值 − 今天花的钱”一样。
        XCTAssertEqual(200 * 1250 - 100 * 1240 - 100 * 1245, 1500)

        // 昨天有 150 股，今天 1255 卖了 50 股：剩下的 +1000，卖掉的按卖出价减昨收 +750。
        let sold = [Trade(side: .sell, shares: 50, price: 1255, day: "2026-09-29", profit: 2750)]
        XCTAssertEqual(Portfolio.dayProfit(shares: 100, quote: quote, trades: sold), 1750)
        XCTAssertEqual(100 * 1250 - 150 * 1240 + 50 * 1255, 1750)

        // 别的日子的买卖不影响今天。
        let earlier = [Trade(side: .buy, shares: 100, price: 1100, day: "2026-09-28")]
        XCTAssertEqual(Portfolio.dayProfit(shares: 200, quote: quote, trades: earlier), 2000)

        let holding = Holding(shares: 200, cost: 1220)
        XCTAssertEqual(Portfolio.position(holding, quote: quote, trades: bought)?.dayProfit, 1500)
        XCTAssertEqual(Portfolio.position(holding, quote: quote)?.dayProfit, 2000)
    }

    func testSoldOutTodayStillCountsToday() throws {
        let trades = [
            Trade(side: .buy, shares: 100, price: 1200, day: "2026-09-01"),
            Trade(side: .sell, shares: 100, price: 1255, day: "2026-09-29", profit: 5500),
        ]
        let item = WatchItem(symbol: moutai, name: "贵州茅台", holding: nil, trades: trades)
        let summary = try XCTUnwrap(Portfolio.summaries(items: [item], quotes: [moutai: quote()]).first)
        XCTAssertEqual(summary.dayProfit, 1500, "今天卖掉的按卖出价减昨收")
        XCTAssertEqual(summary.count, 0, "已经没有持仓，不算一只")
        XCTAssertEqual(summary.marketValue, 0)

        XCTAssertTrue(Portfolio.summaries(items: [item], quotes: [moutai: quote(day: 30)]).isEmpty, "第二天就不算了")
        XCTAssertTrue(Portfolio.summaries(items: [WatchItem(symbol: moutai)], quotes: [moutai: quote()]).isEmpty)
    }

    func testRealizedProfit() {
        let sell = Trade.sell(100, at: 1300, from: Holding(shares: 200, cost: 1200), day: "2026-03-02")
        XCTAssertEqual(sell.profit, 10_000, "按卖出前的成本价算")
        XCTAssertEqual(sell.side, .sell)

        let items = [
            WatchItem(symbol: moutai, trades: [
                Trade(side: .sell, shares: 100, price: 1000, day: "2025-12-31", profit: -500),
                Trade(side: .buy, shares: 100, price: 1200, day: "2026-01-05"),
                sell,
            ]),
            WatchItem(symbol: Symbol("usAAPL")!, trades: [Trade(side: .sell, shares: 10, price: 300, day: "2026-09-28", profit: -200)]),
            WatchItem(symbol: Symbol("hk00700")!, trades: [Trade(side: .buy, shares: 100, price: 400, day: "2026-09-28")]),
        ]
        let realized = Portfolio.realizedProfit(items: items, since: "2026-01-01")
        XCTAssertEqual(realized.map(\.region), [.cn, .us], "只买没卖的不算")
        XCTAssertEqual(realized.map(\.profit), [10_000, -200])
        XCTAssertEqual(Portfolio.realizedProfit(items: items, since: "2025-01-01").first?.profit, 9_500)

        XCTAssertEqual(Portfolio.yearStart(now: time(2026, 9, 29, 10, 0, .cn)), "2026-01-01")
        XCTAssertEqual(Portfolio.yearStart(now: time(2026, 12, 31, 20, 0, .us)), "2027-01-01", "按北京的日期")
    }

    func testCodingAndLimit() throws {
        let item = WatchItem(symbol: moutai, name: "贵州茅台", holding: Holding(shares: 100, cost: 1200),
                             trades: [Trade(side: .sell, shares: 100, price: 1300, day: "2026-09-29", profit: 10_000)])
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(WatchItem.self, from: data), item)

        let empty = String(decoding: try JSONEncoder().encode(WatchItem(symbol: moutai)), as: UTF8.self)
        XCTAssertFalse(empty.contains("trades"), "没有买卖记录时不写这个字段")
        let old = try JSONDecoder().decode(WatchItem.self, from: Data(#"{"symbol":"sh600519","name":"贵州茅台"}"#.utf8))
        XCTAssertEqual(old.trades, [], "旧版本的数据没有买卖记录")
        let broken = try JSONDecoder().decode(WatchItem.self, from: Data(#"{"symbol":"sh600519","trades":"x"}"#.utf8))
        XCTAssertEqual(broken.trades, [], "读不懂的买卖记录当作没有")

        let many = (0..<Trade.limit).map { Trade(side: .buy, shares: 1, price: Double($0), day: "2026-09-29") }
        let appended = many.appending([Trade(side: .buy, shares: 1, price: 999, day: "2026-09-29")])
        XCTAssertEqual(appended.count, Trade.limit)
        XCTAssertEqual(appended.first?.price, 1, "丢掉最早的")
        XCTAssertEqual(appended.last?.price, 999)
    }
}
