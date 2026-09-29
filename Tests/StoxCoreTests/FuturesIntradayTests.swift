import XCTest
@testable import StoxCore

final class FuturesIntradayTests: XCTestCase {
    // 2026-09-29 从新浪抓取的纽约黄金分时（开头和结尾几条，原样）。
    static let gold = #"""
    /*<script>location.href='//sina.com';</script>*/
    var t1hf_GC=({"minLine_1d":[["2026-09-29","4168.400","cme","","06:00","4148.545","0","0","4149.832","2026-09-29 06:00:00"],["06:01","4150.843","0","0","4149.419","2026-09-29 06:01:00"],["06:02","4150.380","0","0","4149.491","2026-09-29 06:02:00"],["13:55","4174.653","0","0","4161.102","2026-09-29 13:55:00"],["13:56","4172.462","0","0","4161.134","2026-09-29 13:56:00"]]});
    """#

    // 恒指期货的交易日从前一天 17:15 的夜盘开始（原样，节选）。
    static let hangSeng = #"""
    var t1hf_HSI=({"minLine_1d":[["2026-09-29","24684.000","hkex","","17:15","24646.010","65","89235","24657.827","2026-09-28 17:15:00"],["17:16","24635.000","26","89235","24656.450","2026-09-28 17:16:00"],["14:18","24505.550","88","124316","24521.258","2026-09-29 14:18:00"]]});
    """#

    private func beijing(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        MarketRegion.global.calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testParsesTheMinuteLine() throws {
        let symbol = Symbol("hf_GC")!
        let series = try XCTUnwrap(SinaFuturesMinuteParser.parse(Data(Self.gold.utf8), symbol: symbol))
        XCTAssertEqual(series.date, "20260929")
        XCTAssertEqual(series.start, beijing(29, 6, 0), "从第一条的时间算起")
        XCTAssertEqual(series.points.map(\.minute), [0, 1, 2, 475, 476], "离开盘多少分钟")
        XCTAssertEqual(series.points.first?.price, 4148.545, "第一条的价格在交易日、昨结算、交易所后面")
        XCTAssertEqual(series.points.last?.price, 4172.462)
        XCTAssertNil(series.points[1].average, "新浪按价格算的均价不用")
        XCTAssertNil(series.points[1].volume, "纽约的期货成交量都是 0")
        XCTAssertEqual(IntradayAxis.timeLabel(of: 476, start: series.start, region: .global), "13:56")

        XCTAssertEqual(
            SinaFuturesMinuteParser.url(for: symbol)?.absoluteString,
            "https://stock2.finance.sina.com.cn/futures/api/jsonp.php/var%20t1hf_GC=/GlobalFuturesService.getGlobalFuturesMinLine?symbol=GC"
        )
        XCTAssertNil(SinaFuturesMinuteParser.url(for: Symbol("whUSDCNY")!))
        XCTAssertNil(SinaFuturesMinuteParser.parse(Data(#"var t1hf_W=({"minLine_1d":[]});"#.utf8), symbol: symbol))
        XCTAssertNil(SinaFuturesMinuteParser.parse(Data("<html>".utf8), symbol: symbol))
    }

    func testTradingDayStartsTheEveningBefore() throws {
        let series = try XCTUnwrap(SinaFuturesMinuteParser.parse(Data(Self.hangSeng.utf8), symbol: Symbol("hf_HSI")!))
        XCTAssertEqual(series.start, beijing(28, 17, 15))
        XCTAssertEqual(series.points.map(\.minute), [0, 1, 21 * 60 + 3])
        XCTAssertEqual(IntradayAxis.ticks(for: .global, start: series.start).map(\.label), ["17:15", "05:15", "17:15"])
        XCTAssertEqual(IntradayAxis.timeLabel(of: 21 * 60 + 3, start: series.start, region: .global), "14:18")
    }

    func testAxis() {
        XCTAssertEqual(IntradayAxis.length(for: .global), 24 * 60)
        XCTAssertEqual(IntradayAxis.offset(of: 475, region: .global), 475, "期货的 minute 就是横轴上的位置")
        XCTAssertEqual(IntradayAxis.ticks(for: .global, start: beijing(29, 6, 0)).map(\.label), ["06:00", "18:00", "06:00"])
        XCTAssertEqual(IntradayAxis.ticks(for: .global, start: beijing(29, 6, 0)).map(\.position), [0, 0.5, 1])
        XCTAssertEqual(IntradayAxis.ticks(for: .global), [], "没有开盘时刻时不标")
        XCTAssertEqual(IntradayAxis.ticks(for: .cn).map(\.label), ["09:30", "11:30/13:00", "15:00"], "股票照旧")
        XCTAssertEqual(IntradayAxis.timeLabel(of: 571, start: nil, region: .cn), "09:31")
    }

    func testSparklineFollowsTheQuote() throws {
        let series = try XCTUnwrap(SinaFuturesMinuteParser.parse(Data(Self.gold.utf8), symbol: Symbol("hf_GC")!))
        let sparkline = try XCTUnwrap(Sparkline(series: series, region: .global))
        XCTAssertEqual(sparkline.start, series.start)
        // 24 小时分 48 段，每段半小时：13:56 是开盘后 7 小时 56 分，第 15 段。
        XCTAssertEqual(sparkline.values[15], 4172.462)
        XCTAssertEqual(sparkline.values[0], 4150.380)
        XCTAssertNil(sparkline.values[16])

        func quote(_ price: Double, at time: Date) -> Quote {
            Quote(symbol: Symbol("hf_GC")!, name: "纽约黄金", price: price, previousClose: 4168.4, timestamp: time)
        }
        // 14:20 的行情落在第 16 段；过了半夜照样算在这个交易日里。
        XCTAssertEqual(sparkline.updating(with: quote(4175, at: beijing(29, 14, 20)), region: .global).values[16], 4175)
        XCTAssertEqual(sparkline.updating(with: quote(4180, at: beijing(30, 1, 0)), region: .global).values[38], 4180)
        // 下一个交易日的行情不画在这一天上。
        XCTAssertEqual(sparkline.updating(with: quote(4190, at: beijing(30, 6, 10)), region: .global), sparkline)
    }
}
