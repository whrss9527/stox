import XCTest
@testable import StoxCore

final class KlineTests: XCTestCase {
    private let moutai = Symbol("sh600519")!
    private let apple = Symbol("usAAPL")!

    // MARK: - 解析

    func testParsesForwardAdjustedDays() throws {
        // 2026-09-28 抓取的平安银行日 K（节选），其中一根带着分红信息。
        let json = #"""
        {"code":0,"msg":"","data":{"sz000001":{"qfqday":[["2026-09-23","11.451","11.461","11.501","11.371","759457.000"],
        ["2026-09-24","11.350","11.300","11.470","11.290","1043819.000",{"nd":"2026","fh_sh":"2.49","FHcontent":"10派2.49元"}],
        ["2026-09-28","11.280","11.300","11.410","11.270","715341.000"]],"qt":{},"prec":"11.30","version":"16"}}}
        """#
        let series = try XCTUnwrap(TencentKlineParser.parse(Data(json.utf8), symbol: Symbol("sz000001")!, period: .day))
        XCTAssertEqual(series.period, .day)
        XCTAssertEqual(series.candles.count, 3)
        XCTAssertEqual(series.candles[1], Candle(date: "2026-09-24", open: 11.35, close: 11.30, high: 11.47, low: 11.29, volume: 1_043_819),
                       "开 收 高 低 成交量的顺序")
        XCTAssertEqual(series.candles[1].direction, .down)
        XCTAssertEqual(series.candles[2].direction, .up)
        XCTAssertNil(series.changePercent(at: 0), "第一根没有前一根")
        XCTAssertEqual(try XCTUnwrap(series.changePercent(at: 1)), (11.30 - 11.461) / 11.461 * 100, accuracy: 1e-9)
        XCTAssertNil(series.changePercent(at: 3))
    }

    func testIndexUsesPlainKey() throws {
        let json = #"""
        {"code":0,"msg":"","data":{"sh000001":{"day":[["2026-09-24","3925.320","3888.370","3930.500","3888.370","438530412.000"],
        ["2026-09-28","3878.410","3823.620","3878.410","3806.670","452350675.000"]],"qt":{}}}}
        """#
        let series = try XCTUnwrap(TencentKlineParser.parse(Data(json.utf8), symbol: Symbol("sh000001")!, period: .day))
        XCTAssertEqual(series.candles.map(\.close), [3888.37, 3823.62])
        XCTAssertNil(TencentKlineParser.parse(Data(json.utf8), symbol: Symbol("sh000001")!, period: .week), "没有这个周期")
    }

    func testUSKeyCarriesExchangeSuffix() throws {
        let json = #"""
        {"code":0,"msg":"","data":{"usAAPL.OQ":{"qfqweek":[["2026-09-25","336.04","341.07","345.34","333.05","30002507.00"],
        ["2026-09-28","340.37","340.98","342.99","339.32","13597309.00"]],"pandata":{},"qt":{}}}}
        """#
        let series = try XCTUnwrap(TencentKlineParser.parse(Data(json.utf8), symbol: apple, period: .week))
        XCTAssertEqual(series.symbol, apple)
        XCTAssertEqual(series.candles.map(\.date), ["2026-09-25", "2026-09-28"])
    }

    func testHongKongRowsWithExtraFields() throws {
        let json = #"""
        {"code":0,"msg":"","data":{"hk00700":{"qfqmonth":[["2026-09-28","441.400","439.800","447.000","438.600","15335550.000",
        {"cqr":"2026-09-28","HGcontent":"回购22.70万股"},"0.170","677406.336"]],"fsStartDate":"","qt":{}}}}
        """#
        let series = try XCTUnwrap(TencentKlineParser.parse(Data(json.utf8), symbol: Symbol("hk00700")!, period: .month))
        XCTAssertEqual(series.candles, [Candle(date: "2026-09-28", open: 441.4, close: 439.8, high: 447, low: 438.6, volume: 15_335_550)],
                       "港股的成交量是股数，后面的回购信息不影响")
    }

    func testSkipsBrokenRows() throws {
        let json = #"""
        {"code":0,"data":{"sh600519":{"qfqday":[["2026-09-24","0","1237.000","1256.130","1231.050","1"],
        ["20260925","1250","1237","1256","1231","1"],["2026-09-26","1250"],"oops",
        ["2026-09-28",1236,1243.88,1240,1250,"28218.000"]]}}}
        """#
        let series = try XCTUnwrap(TencentKlineParser.parse(Data(json.utf8), symbol: moutai, period: .day))
        XCTAssertEqual(series.candles.count, 1, "价格为 0、日期格式不对、字段不够的行都跳过")
        XCTAssertEqual(series.candles[0].high, 1243.88, "最高价至少是开盘、收盘里较高的")
        XCTAssertEqual(series.candles[0].low, 1236, "最低价至多是开盘、收盘里较低的")
        XCTAssertNil(TencentKlineParser.parse(Data("<html>".utf8), symbol: moutai, period: .day))
        XCTAssertNil(TencentKlineParser.parse(Data(#"{"code":0,"data":{}}"#.utf8), symbol: moutai, period: .day))
    }

    // MARK: - 地址

    func testKlineURLs() {
        XCTAssertEqual(TencentProvider.klineURL(for: moutai, period: .day, count: 60)?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=sh600519,day,,,60,qfq")
        XCTAssertEqual(TencentProvider.klineURL(for: Symbol("hk00700")!, period: .week, count: 60)?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/hkfqkline/get?param=hk00700,week,,,60,qfq")
        XCTAssertEqual(TencentProvider.klineURL(for: apple, period: .month, count: 60, exchangeCode: "AAPL.OQ")?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usAAPL.OQ,month,,,60,qfq")
        XCTAssertEqual(TencentProvider.klineURL(for: Symbol("usBRK.B")!, period: .day, count: 60, exchangeCode: "BRK.B.N")?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usBRK.B.N,day,,,60,qfq")
        XCTAssertEqual(TencentProvider.klineURL(for: Symbol("us.IXIC")!, period: .day, count: 60, exchangeCode: ".IXIC")?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=us.IXIC,day,,,60,qfq")
        XCTAssertEqual(TencentProvider.klineURL(for: moutai, period: .day, count: 60, exchangeCode: "600519")?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=sh600519,day,,,60,qfq", "A 股不用交易所代码")
    }

    func testQuotesCarryExchangeCode() {
        let us = TencentQuoteParser.parse(Fixtures.unitedStates)
        XCTAssertEqual(us[apple]?.exchangeCode, "AAPL.OQ")
        XCTAssertEqual(us[Symbol("usBRK.B")!]?.exchangeCode, "BRK.B.N")
        XCTAssertEqual(us[Symbol("us.IXIC")!]?.exchangeCode, ".IXIC")
        XCTAssertEqual(TencentQuoteParser.parse(Fixtures.aShares)[moutai]?.exchangeCode, "600519")
    }

    // MARK: - 用最新行情更新

    private func quote(_ symbol: Symbol, price: Double, open: Double, high: Double, low: Double, volume: Double = 100, time: String) -> Quote {
        Quote(
            symbol: symbol, name: "", price: price, previousClose: 1, open: open, high: high, low: low, volume: volume,
            timestamp: TencentQuoteParser.parseTimestamp(time, timeZone: symbol.market.region.timeZone)
        )
    }

    private func series(_ period: KlinePeriod, _ candles: [Candle], symbol: Symbol? = nil) -> KlineSeries {
        KlineSeries(symbol: symbol ?? moutai, period: period, candles: candles)
    }

    func testMergeUpdatesToday() {
        let old = series(.day, [
            Candle(date: "2026-09-25", open: 1250, close: 1237, high: 1256, low: 1231),
            Candle(date: "2026-09-28", open: 1236, close: 1240, high: 1242, low: 1230),
        ])
        let merged = old.merging(quote(moutai, price: 1243.88, open: 1236, high: 1244.01, low: 1228.1, time: "20260928141019"))
        XCTAssertEqual(merged.candles.count, 2)
        XCTAssertEqual(merged.candles[1], Candle(date: "2026-09-28", open: 1236, close: 1243.88, high: 1244.01, low: 1228.1))
    }

    func testMergeAppendsNewDay() {
        let old = series(.day, [Candle(date: "2026-09-25", open: 1250, close: 1237, high: 1256, low: 1231)])
        let merged = old.merging(quote(moutai, price: 1240, open: 1236, high: 1241, low: 1235, time: "20260928093500"))
        XCTAssertEqual(merged.candles.last, Candle(date: "2026-09-28", open: 1236, close: 1240, high: 1241, low: 1235))

        // 开盘前还没有成交：不补。
        let early = old.merging(quote(moutai, price: 1237, open: 0, high: 0, low: 0, volume: 0, time: "20260928091500"))
        XCTAssertEqual(early, old)
        // 美股盘前：有成交量但还没有开盘价，不补今天这一根。
        let apple = series(.day, [Candle(date: "2026-09-25", open: 336.04, close: 341.07, high: 341.67, low: 334.53)], symbol: Symbol("usAAPL")!)
        let premarket = apple.merging(quote(Symbol("usAAPL")!, price: 341.07, open: 0, high: 0, low: 0, volume: 1200, time: "2026-09-28 08:30:00"))
        XCTAssertEqual(premarket, apple)
        // 行情比 K 线还旧：不动。
        let stale = old.merging(quote(moutai, price: 1200, open: 1210, high: 1220, low: 1190, time: "20260924150000"))
        XCTAssertEqual(stale, old)
    }

    func testMergeUsesExchangeLocalDate() {
        // 美东 9 月 28 日 20:00 已经是北京时间 29 日，按交易所当地日期归到 28 日。
        let old = series(.day, [Candle(date: "2026-09-28", open: 340.37, close: 341.0, high: 342.99, low: 339.32)], symbol: apple)
        let merged = old.merging(quote(apple, price: 341.5, open: 340.37, high: 343, low: 339.32, time: "2026-09-28 20:00:00"))
        XCTAssertEqual(merged.candles.count, 1)
        XCTAssertEqual(merged.candles[0].close, 341.5)
        XCTAssertEqual(merged.candles[0].high, 343)
    }

    func testMergeWeeks() {
        let week = series(.week, [
            Candle(date: "2026-09-18", open: 1277, close: 1257, high: 1285, low: 1254),
            Candle(date: "2026-09-24", open: 1259, close: 1237, high: 1271.5, low: 1231.05),
        ])
        // 同一周（9 月 24 日是周四，25 日是周五）：收盘换成现价，高低点取更极端的。
        let sameWeek = week.merging(quote(moutai, price: 1260, open: 1240, high: 1275, low: 1235, time: "20260925150000"))
        XCTAssertEqual(sameWeek.candles.count, 2)
        XCTAssertEqual(sameWeek.candles[1], Candle(date: "2026-09-25", open: 1259, close: 1260, high: 1275, low: 1231.05))
        // 下一周的周一：新开一根。
        let nextWeek = week.merging(quote(moutai, price: 1243.88, open: 1236, high: 1244.01, low: 1228.1, time: "20260928150000"))
        XCTAssertEqual(nextWeek.candles.count, 3)
        XCTAssertEqual(nextWeek.candles[2], Candle(date: "2026-09-28", open: 1236, close: 1243.88, high: 1244.01, low: 1228.1))
    }

    func testMergeMonths() {
        let month = series(.month, [
            Candle(date: "2026-08-31", open: 1350.6, close: 1299.52, high: 1363.35, low: 1270.33),
            Candle(date: "2026-09-25", open: 1295, close: 1237, high: 1338.86, low: 1231),
        ])
        let sameMonth = month.merging(quote(moutai, price: 1243.88, open: 1236, high: 1244.01, low: 1228.1, time: "20260928150000"))
        XCTAssertEqual(sameMonth.candles.count, 2)
        XCTAssertEqual(sameMonth.candles[1], Candle(date: "2026-09-28", open: 1295, close: 1243.88, high: 1338.86, low: 1228.1))
        let nextMonth = month.merging(quote(moutai, price: 1250, open: 1245, high: 1252, low: 1240, time: "20261008100000"))
        XCTAssertEqual(nextMonth.candles.count, 3)
        XCTAssertEqual(nextMonth.candles[2].date, "2026-10-08")
        XCTAssertEqual(nextMonth.candles[2].open, 1245)
    }

    func testMergeWithoutDataChangesNothing() {
        let empty = series(.day, [])
        XCTAssertEqual(empty.merging(quote(moutai, price: 1, open: 1, high: 1, low: 1, time: "20260928100000")), empty)
        let one = series(.day, [Candle(date: "2026-09-25", open: 1, close: 1, high: 1, low: 1)])
        let noTime = Quote(symbol: moutai, name: "", price: 2, previousClose: 1, open: 2, high: 2, low: 2, volume: 1)
        XCTAssertEqual(one.merging(noTime), one)
    }
}

final class ChartLayoutTests: XCTestCase {
    func testCandleLayout() {
        let full = CandleLayout(count: 60, width: 300)
        XCTAssertEqual(full.slot, 5)
        XCTAssertEqual(full.bodyWidth, 3.5, accuracy: 1e-9)
        XCTAssertEqual(full.centerX(of: 0), 2.5)
        XCTAssertEqual(full.centerX(of: 59), 297.5)
        XCTAssertEqual(full.index(at: 0), 0)
        XCTAssertEqual(full.index(at: 7.4), 1)
        XCTAssertEqual(full.index(at: 299.9), 59)
        XCTAssertEqual(full.index(at: -5), 0)
        XCTAssertEqual(full.index(at: 500), 59)

        // 新股只有 3 根：按 40 格分，靠左排，右边空着的地方算最后一根。
        let few = CandleLayout(count: 3, width: 320)
        XCTAssertEqual(few.slot, 8)
        XCTAssertEqual(few.bodyWidth, 5.6, accuracy: 1e-9)
        XCTAssertEqual(few.index(at: 20), 2)
        XCTAssertEqual(few.index(at: 300), 2)
        XCTAssertEqual(CandleLayout(count: 1, width: 1000).bodyWidth, 8, "最宽 8")
        XCTAssertEqual(CandleLayout(count: 400, width: 200).bodyWidth, 1, "最窄 1")
        XCTAssertNil(CandleLayout(count: 0, width: 300).index(at: 10))
    }

    func testNearestIntradayPoint() {
        let series = IntradaySeries(symbol: Symbol("sh600519")!, date: nil, points: [
            IntradayPoint(minute: 570, price: 1), IntradayPoint(minute: 571, price: 2),
            IntradayPoint(minute: 690, price: 3), IntradayPoint(minute: 781, price: 4),
        ])
        XCTAssertEqual(series.point(nearest: 0, region: .cn)?.price, 1)
        XCTAssertEqual(series.point(nearest: 0.9, region: .cn)?.price, 2)
        XCTAssertEqual(series.point(nearest: 119, region: .cn)?.price, 3, "11:30 在第 120 分钟")
        XCTAssertEqual(series.point(nearest: 200, region: .cn)?.price, 4, "还没到的时间取最新的点")
        XCTAssertNil(IntradaySeries(symbol: Symbol("sh600519")!, date: nil, points: []).point(nearest: 10, region: .cn))
    }
}

final class VolumeTests: XCTestCase {
    private let moutai = Symbol("sh600519")!

    func testMergeKeepsTheFetchedVolume() throws {
        let series = KlineSeries(symbol: moutai, period: .day, candles: [
            Candle(date: "2026-09-25", open: 1230, close: 1237, high: 1240, low: 1228, volume: 30_000),
            Candle(date: "2026-09-28", open: 1236, close: 1239, high: 1242, low: 1230, volume: 22_000),
        ])
        let timestamp = TencentQuoteParser.parseTimestamp("20260928150000", timeZone: MarketRegion.cn.timeZone)
        let quote = Quote(symbol: moutai, name: "贵州茅台", price: 1243.88, previousClose: 1237, open: 1236, high: 1244.01,
                          low: 1228.1, volume: 2_823_700, timestamp: timestamp)
        let merged = series.merging(quote)
        XCTAssertEqual(merged.candles.last?.close, 1243.88)
        XCTAssertEqual(merged.candles.last?.volume, 22_000, "行情里的成交量单位不一样，沿用接口给的")

        let nextDay = TencentQuoteParser.parseTimestamp("20260929100000", timeZone: MarketRegion.cn.timeZone)
        var tomorrow = quote
        tomorrow.timestamp = nextDay
        let appended = series.merging(tomorrow)
        XCTAssertEqual(appended.candles.count, 3)
        XCTAssertNil(appended.candles.last?.volume, "新补的一根等下一次请求再画成交量")

        let data = KlineChartData(series: appended)
        XCTAssertEqual(data.maxVolume, 30_000)
        XCTAssertNil(KlineChartData(series: KlineSeries(symbol: moutai, period: .day, candles: [
            Candle(date: "2026-09-28", open: 1, close: 1, high: 1, low: 1),
        ])).maxVolume)
    }
}

final class MovingAverageTests: XCTestCase {
    /// 收盘价依次是 closes 的日 K，开盘比收盘低 1，最高高 2，最低低 3。
    private func series(closes: [Double]) -> KlineSeries {
        let candles = closes.enumerated().map { index, close in
            Candle(date: String(format: "2026-%02d-%02d", 1 + index / 28, 1 + index % 28),
                   open: close - 1, close: close, high: close + 2, low: close - 3)
        }
        return KlineSeries(symbol: Symbol("sh600519")!, period: .day, candles: candles)
    }

    func testAveragesCoverTheVisibleCandles() throws {
        // 80 根，收盘价 1、2、…、80：显示最后 60 根（21…80），三条均线在第一根就都有值。
        let data = KlineChartData(series: series(closes: (1...80).map(Double.init)))
        XCTAssertEqual(KlineChartData.fetchCount, 80)
        XCTAssertEqual(data.period, .day)
        XCTAssertEqual(data.candles.count, 60)
        XCTAssertEqual(data.candles.first?.close, 21)
        XCTAssertEqual(data.averages.count, 3)
        XCTAssertEqual(data.averages[0].first ?? nil, 19, "17 到 21 的平均")
        XCTAssertEqual(data.averages[1].first ?? nil, 16.5, "12 到 21 的平均")
        XCTAssertEqual(data.averages[2].first ?? nil, 11.5, "2 到 21 的平均")
        XCTAssertEqual(data.averages[0].last ?? nil, 78)
        XCTAssertTrue(data.averages.allSatisfy { $0.count == 60 && !$0.contains(where: { $0 == nil }) })
        XCTAssertEqual(data.changes.count, 60)
        XCTAssertEqual(try XCTUnwrap(data.changes.first ?? nil), 5, accuracy: 1e-9, "第一根的前一根来自多取的历史：20 到 21")
        XCTAssertEqual(try XCTUnwrap(data.totalChangePercent), 300, accuracy: 1e-9, "第一根开盘 20，最后收盘 80")
    }

    func testShortHistory() {
        // 新股只有 12 根：全都显示，MA5 从第 5 根开始有，MA20 一直没有。
        let data = KlineChartData(series: series(closes: (1...12).map(Double.init)))
        XCTAssertEqual(data.candles.count, 12)
        XCTAssertNil(data.changes[0])
        XCTAssertTrue(data.averages[0].prefix(4).allSatisfy { $0 == nil })
        XCTAssertEqual(data.averages[0][4], 3)
        XCTAssertTrue(data.averages[2].allSatisfy { $0 == nil })

        let empty = KlineChartData(series: series(closes: []))
        XCTAssertTrue(empty.candles.isEmpty)
        XCTAssertEqual(empty.averages.map(\.count), [0, 0, 0])
        XCTAssertNil(empty.priceRange(includingAverages: true))
        XCTAssertNil(empty.totalChangePercent)
    }

    func testRangeIncludesAverages() throws {
        // 前 20 根在 100，后 60 根跌到 10：MA20 开头还在高处，画均线时纵轴要容下它。
        let closes = Array(repeating: 100.0, count: 20) + Array(repeating: 10.0, count: 60)
        let data = KlineChartData(series: series(closes: closes))
        let candlesOnly = try XCTUnwrap(data.priceRange(includingAverages: false))
        XCTAssertEqual(candlesOnly.low, 7)
        XCTAssertEqual(candlesOnly.high, 12)
        let withAverages = try XCTUnwrap(data.priceRange(includingAverages: true))
        XCTAssertEqual(withAverages.low, 7)
        XCTAssertEqual(withAverages.high, (19 * 100 + 10) / 20, accuracy: 1e-9)
    }
}
