import XCTest
@testable import StoxCore

final class IntradayTests: XCTestCase {
    func testParsesAShareMinutes() throws {
        // 头两条是 2026-09-28 抓取的原样。
        let json = #"""
        {"code":0,"msg":"","data":{"sh600519":{"data":{"data":["0930 1236.00 349 43136400.00","0931 1234.06 1635 201743930.45",
        "1130 1238.10 9000 1113600000.00","1300 1239.00 9100 1126000000.00","1500 1239.58 22537 2783140281.00","bad row","2561 1.0 1 1"],
        "date":"20260928"},"qt":{"sh600519":["1","贵州茅台"]}}}}
        """#
        let series = try XCTUnwrap(TencentMinuteParser.parse(Data(json.utf8), symbol: Symbol("sh600519")!))
        XCTAssertEqual(series.date, "20260928")
        XCTAssertEqual(series.points.count, 5, "格式不对的行跳过")
        XCTAssertEqual(series.points.first?.minute, 570)
        XCTAssertEqual(series.points.first?.price, 1236)
        XCTAssertEqual(series.points.last?.minute, 900)
        XCTAssertEqual(series.points.last?.price, 1239.58)
        XCTAssertEqual(series.high, 1239.58)
        XCTAssertEqual(series.low, 1234.06)

        // A 股的成交量是手：均价 = 成交额 / (手数 × 100)。
        XCTAssertEqual(try XCTUnwrap(series.points[0].average), 43_136_400 / 34_900, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(series.points[1].average), 201_743_930.45 / 163_500, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(series.latestAverage), 2_783_140_281 / 2_253_700, accuracy: 1e-9)
    }

    func testHongKongAverageUsesShares() throws {
        // 2026-09-28 抓取的腾讯控股前两分钟：港股的成交量是股数。
        let json = #"""
        {"code":0,"msg":"","data":{"hk00700":{"data":{"data":["0930 441.400 380150 167797970.000","0931 443.400 982872 434286946.200"],
        "date":"20260928"}}}}
        """#
        let series = try XCTUnwrap(TencentMinuteParser.parse(Data(json.utf8), symbol: Symbol("hk00700")!))
        XCTAssertEqual(try XCTUnwrap(series.points[0].average), 167_797_970 / 380_150, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(series.points[1].average), 434_286_946.2 / 982_872, accuracy: 1e-9)
    }

    func testIndexHasNoAverage() throws {
        let json = #"""
        {"code":0,"msg":"","data":{"sh000001":{"data":{"data":["0930 3878.41 3901496 6172666205.40","0931 3869.86 20844108 35445662366.20"],
        "date":"20260928"}}}}
        """#
        let series = try XCTUnwrap(TencentMinuteParser.parse(Data(json.utf8), symbol: Symbol("sh000001")!))
        XCTAssertEqual(series.points.count, 2)
        XCTAssertTrue(series.points.allSatisfy { $0.average == nil }, "指数的成交额是成分股加起来的")
        XCTAssertNil(series.latestAverage)
    }

    func testImplausibleAveragesAreDropped() throws {
        // 成交额对不上（比如接口只给了一部分）时算出来的均价不在当天价格范围里，不要。
        let json = #"""
        {"code":0,"msg":"","data":{"sz000001":{"data":{"data":["0930 11.30 100 1130.00","0931 11.31 200 50.00","0932 11.32 300 339300.00"],
        "date":"20260928"}}}}
        """#
        let series = try XCTUnwrap(TencentMinuteParser.parse(Data(json.utf8), symbol: Symbol("sz000001")!))
        XCTAssertNil(series.points[1].average)
        XCTAssertEqual(try XCTUnwrap(series.points[2].average), 339_300 / 30_000, accuracy: 1e-9)
    }

    func testParsesUSMinutesWithoutAmount() throws {
        let json = #"""
        {"code":0,"msg":"","data":{"usAAPL":{"data":{"data":["0930 341.58 303686","0931 341.58 1392198","1046 340.14 7887853"],
        "date":"20260928"},"qt":{"usAAPL":["real","苹果","AAPL.OQ","340.12"]}}}}
        """#
        let series = try XCTUnwrap(TencentMinuteParser.parse(Data(json.utf8), symbol: Symbol("usAAPL")!))
        XCTAssertEqual(series.points.map(\.minute), [570, 571, 646])
        XCTAssertEqual(series.points.last?.price, 340.14)

        // 美股没有成交额，按每分钟新增的成交量给价格加权。
        XCTAssertEqual(series.points[0].average, 341.58)
        XCTAssertEqual(try XCTUnwrap(series.points[1].average), 341.58, accuracy: 1e-9)
        let first: Double = 341.58 * 1_392_198
        let second: Double = 340.14 * Double(7_887_853 - 1_392_198)
        let expected = (first + second) / 7_887_853
        XCTAssertEqual(try XCTUnwrap(series.points[2].average), expected, accuracy: 1e-9)
    }

    func testEmptyOrGarbage() {
        let empty = #"{"code":0,"data":{"usAAPL.OQ":{"data":{"data":["  0"],"date":""}}}}"#
        let series = TencentMinuteParser.parse(Data(empty.utf8), symbol: Symbol("usAAPL")!)
        XCTAssertEqual(series?.points, [])
        XCTAssertNil(series?.date)
        XCTAssertNil(TencentMinuteParser.parse(Data("<html>".utf8), symbol: Symbol("usAAPL")!))
    }

    func testAxisTicks() {
        XCTAssertEqual(IntradayAxis.ticks(for: .cn), [
            AxisTick(position: 0, label: "09:30"), AxisTick(position: 0.5, label: "11:30/13:00"), AxisTick(position: 1, label: "15:00"),
        ])
        XCTAssertEqual(IntradayAxis.ticks(for: .hk).map(\.label), ["09:30", "12:00/13:00", "16:00"])
        XCTAssertEqual(IntradayAxis.ticks(for: .hk)[1].position, 150.0 / 330, accuracy: 1e-9, "港股上午 150 分钟、下午 180 分钟")
        XCTAssertEqual(IntradayAxis.ticks(for: .us), [
            AxisTick(position: 0, label: "09:30"), AxisTick(position: 0.5, label: "12:45"), AxisTick(position: 1, label: "16:00"),
        ])
    }

    func testAxisSkipsLunchBreak() {
        XCTAssertEqual(IntradayAxis.length(for: .cn), 240)
        XCTAssertEqual(IntradayAxis.length(for: .hk), 330)
        XCTAssertEqual(IntradayAxis.length(for: .us), 390)
        XCTAssertEqual(IntradayAxis.offset(of: 9 * 60 + 25, region: .cn), 0, "集合竞价放在最左边")
        XCTAssertEqual(IntradayAxis.offset(of: 9 * 60 + 30, region: .cn), 0)
        XCTAssertEqual(IntradayAxis.offset(of: 11 * 60 + 30, region: .cn), 120)
        XCTAssertEqual(IntradayAxis.offset(of: 12 * 60, region: .cn), 120, "午休不占位置")
        XCTAssertEqual(IntradayAxis.offset(of: 13 * 60 + 1, region: .cn), 121)
        XCTAssertEqual(IntradayAxis.offset(of: 15 * 60, region: .cn), 240)
        XCTAssertEqual(IntradayAxis.offset(of: 16 * 60 + 8, region: .hk), 330, "港股收市竞价放在最右边")
        XCTAssertEqual(IntradayAxis.offset(of: 18 * 60 + 31, region: .hk), 330)
        XCTAssertEqual(IntradayAxis.offset(of: 10 * 60 + 46, region: .us), 76)
    }

    func testMinuteURLs() {
        XCTAssertEqual(TencentProvider.minuteURL(for: Symbol("sh600519")!)?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh600519")
        XCTAssertEqual(TencentProvider.minuteURL(for: Symbol("hkHSI")!)?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=hkHSI")
        XCTAssertEqual(TencentProvider.minuteURL(for: Symbol("us.IXIC")!)?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/UsMinute/query?code=us.IXIC")
    }
}

final class FiveDayTests: XCTestCase {
    private let hk = Symbol("hk00700")!

    // 2026-09-28 抓取的五日分时结构（每天只留几条）。最近的一天在最前面。
    private let json = #"""
    {"code":0,"msg":"","data":{"hk00700":{"data":[
     {"date":"20260928","data":["0930 441.400 380150 167797970.000","1200 443.000 1 1","1608 439.800 15335550 6774063362.900"],"prec":"436.600"},
     {"date":"20260925","data":["0930 433.800 1 1","1608 436.600 2 2"],"prec":"433.000"},
     {"date":"20260924","data":["0930 440.000 1 1","1608 433.000 2 2"],"prec":"441.000"},
     {"date":"20260923","data":["0930 453.400 1 1","1608 441.000 2 2"],"prec":"451.600"},
     {"date":"20260922","data":["0930 442.800 1 1","1608 451.600 2 2"],"prec":"440.200"}],
     "qt":{},"vcm":""}}}
    """#

    func testParsesOldestFirst() throws {
        let series = try XCTUnwrap(TencentMultiDayParser.parse(Data(json.utf8), symbol: hk))
        XCTAssertEqual(series.days.map(\.date), ["20260922", "20260923", "20260924", "20260925", "20260928"])
        XCTAssertEqual(series.previousClose, 440.2, "基准线是第一天的昨收")
        XCTAssertEqual(series.dayPreviousCloses.last ?? nil, 436.6)
        XCTAssertEqual(series.pointCount, 11)
        XCTAssertEqual(series.days.last?.points.last?.minute, 16 * 60 + 8)
        XCTAssertEqual(series.days.last?.points.last?.price, 439.8)

        // 每天各算各的均价；前几天的成交额是凑数的，算出来不在价格范围里，不要。
        let today = try XCTUnwrap(series.days.last)
        XCTAssertEqual(try XCTUnwrap(today.points[0].average), 167_797_970 / 380_150, accuracy: 1e-9)
        XCTAssertNil(today.points[1].average)
        XCTAssertEqual(try XCTUnwrap(today.latestAverage), 6_774_063_362.9 / 15_335_550, accuracy: 1e-9)
        XCTAssertNil(series.days.first?.latestAverage)
    }

    func testUSKeyWithSuffixAndGarbage() throws {
        let us = #"{"code":0,"data":{"usAAPL.OQ":{"data":[{"date":"20260928","data":["0930 341.58 303686"],"prec":"341.07"}],"pandata":{}}}}"#
        let series = try XCTUnwrap(TencentMultiDayParser.parse(Data(us.utf8), symbol: Symbol("usAAPL")!))
        XCTAssertEqual(series.days.count, 1)
        XCTAssertEqual(series.previousClose, 341.07)
        XCTAssertNil(TencentMultiDayParser.parse(Data("oops".utf8), symbol: hk))
        let noClose = #"{"data":{"hk00700":{"data":[{"date":"20260928","data":[],"prec":""}]}}}"#
        XCTAssertNil(try XCTUnwrap(TencentMultiDayParser.parse(Data(noClose.utf8), symbol: hk)).previousClose)
    }

    func testAxisAndHover() throws {
        // 港股每天 330 分钟，五天一共 1650。
        XCTAssertEqual(MultiDayAxis.position(day: 0, minute: 570, days: 5, region: .hk), 0)
        XCTAssertEqual(MultiDayAxis.position(day: 1, minute: 570, days: 5, region: .hk), 0.2, accuracy: 1e-9)
        XCTAssertEqual(MultiDayAxis.position(day: 4, minute: 16 * 60, days: 5, region: .hk), 1, accuracy: 1e-9)

        let series = try XCTUnwrap(TencentMultiDayParser.parse(Data(json.utf8), symbol: hk))
        let first = try XCTUnwrap(series.point(nearest: 0.01, region: .hk))
        XCTAssertEqual(first.day, 0)
        XCTAssertEqual(first.point.price, 442.8)
        let last = try XCTUnwrap(series.point(nearest: 0.99, region: .hk))
        XCTAssertEqual(last.day, 4)
        XCTAssertEqual(last.point.price, 439.8)
        let noon = try XCTUnwrap(series.point(nearest: 0.8 + 150.0 / 1650, region: .hk))
        XCTAssertEqual(noon.point.minute, 12 * 60, "最后一天的中午")
    }

    func testFiveDayURLs() {
        XCTAssertEqual(TencentProvider.fiveDayURL(for: Symbol("sh600519")!)?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/day/query?code=sh600519")
        XCTAssertEqual(TencentProvider.fiveDayURL(for: Symbol("usAAPL")!, exchangeCode: "AAPL.OQ")?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/dayus/query?code=usAAPL.OQ")
        XCTAssertEqual(TencentProvider.fiveDayURL(for: Symbol("us.IXIC")!, exchangeCode: ".IXIC")?.absoluteString,
                       "https://web.ifzq.gtimg.cn/appstock/app/dayus/query?code=us.IXIC")
    }
}
