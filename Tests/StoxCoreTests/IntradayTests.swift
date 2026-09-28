import XCTest
@testable import StoxCore

final class IntradayTests: XCTestCase {
    func testParsesAShareMinutes() throws {
        let json = #"""
        {"code":0,"msg":"","data":{"sh600519":{"data":{"data":["0930 1236.00 349 43136400.00","0931 1234.06 1635 201743930.45",
        "1130 1238.10 9000 1111.00","1300 1239.00 9100 2222.00","1500 1239.58 22537 2783140281.00","bad row","2561 1.0 1 1"],
        "date":"20260928"},"qt":{"sh600519":["1","贵州茅台"]}}}}
        """#
        let series = try XCTUnwrap(TencentMinuteParser.parse(Data(json.utf8), symbol: Symbol("sh600519")!))
        XCTAssertEqual(series.date, "20260928")
        XCTAssertEqual(series.points.count, 5, "格式不对的行跳过")
        XCTAssertEqual(series.points.first, IntradayPoint(minute: 570, price: 1236))
        XCTAssertEqual(series.points.last, IntradayPoint(minute: 900, price: 1239.58))
        XCTAssertEqual(series.high, 1239.58)
        XCTAssertEqual(series.low, 1234.06)
    }

    func testParsesUSMinutesWithoutAmount() throws {
        let json = #"""
        {"code":0,"msg":"","data":{"usAAPL":{"data":{"data":["0930 341.58 303686","0931 341.58 1392198","1046 340.14 7887853"],
        "date":"20260928"},"qt":{"usAAPL":["real","苹果","AAPL.OQ","340.12"]}}}}
        """#
        let series = try XCTUnwrap(TencentMinuteParser.parse(Data(json.utf8), symbol: Symbol("usAAPL")!))
        XCTAssertEqual(series.points.map(\.minute), [570, 571, 646])
        XCTAssertEqual(series.points.last?.price, 340.14)
    }

    func testEmptyOrGarbage() {
        let empty = #"{"code":0,"data":{"usAAPL.OQ":{"data":{"data":["  0"],"date":""}}}}"#
        let series = TencentMinuteParser.parse(Data(empty.utf8), symbol: Symbol("usAAPL")!)
        XCTAssertEqual(series?.points, [])
        XCTAssertNil(series?.date)
        XCTAssertNil(TencentMinuteParser.parse(Data("<html>".utf8), symbol: Symbol("usAAPL")!))
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
        XCTAssertEqual(series.days.last?.points.last, IntradayPoint(minute: 16 * 60 + 8, price: 439.8))
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
