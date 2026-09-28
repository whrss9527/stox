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
