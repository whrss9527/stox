import XCTest
@testable import StoxCore

final class SparklineTests: XCTestCase {
    private let symbol = Symbol("sh600519")!

    func testBucketsFollowTheTradingSessions() {
        // A 股 240 分钟分 48 段，每段 5 分钟；午休不占位置，11:30 和 13:00 在同一段。
        XCTAssertEqual(Sparkline.bucket(of: 9 * 60 + 30, region: .cn), 0)
        XCTAssertEqual(Sparkline.bucket(of: 9 * 60 + 34, region: .cn), 0)
        XCTAssertEqual(Sparkline.bucket(of: 9 * 60 + 35, region: .cn), 1)
        XCTAssertEqual(Sparkline.bucket(of: 11 * 60 + 30, region: .cn), 24)
        XCTAssertEqual(Sparkline.bucket(of: 12 * 60, region: .cn), 24, "午休归到上午收盘")
        XCTAssertEqual(Sparkline.bucket(of: 13 * 60, region: .cn), 24)
        XCTAssertEqual(Sparkline.bucket(of: 15 * 60, region: .cn), 47, "收盘那一分钟算最后一段")
        XCTAssertEqual(Sparkline.bucket(of: 9 * 60, region: .cn), 0, "开盘前算第一段")
        // 美股 390 分钟，收盘后的盘后也算最后一段。
        XCTAssertEqual(Sparkline.bucket(of: 16 * 60 + 30, region: .us), 47)
        XCTAssertEqual(Sparkline.bucket(of: 12 * 60 + 45, region: .us), 24)
    }

    func testTakesTheLastPriceInEachBucket() throws {
        let series = IntradaySeries(symbol: symbol, date: "20260929", points: [
            IntradayPoint(minute: 570, price: 10.0),
            IntradayPoint(minute: 574, price: 10.2),
            IntradayPoint(minute: 690, price: 10.5),
            IntradayPoint(minute: 780, price: 10.4),
            IntradayPoint(minute: 900, price: 10.6),
        ])
        let sparkline = try XCTUnwrap(Sparkline(series: series, region: .cn))
        XCTAssertEqual(sparkline.values.count, Sparkline.buckets)
        XCTAssertEqual(sparkline.values[0], 10.2)
        XCTAssertEqual(sparkline.values[24], 10.4, "11:30 和 13:00 在同一段，取后面的")
        XCTAssertEqual(sparkline.values[47], 10.6)
        XCTAssertNil(sparkline.values[1], "这一段没有点")
        XCTAssertEqual(sparkline.values.compactMap { $0 }.count, 3)
        XCTAssertEqual(sparkline.date, "20260929")

        XCTAssertNil(Sparkline(series: IntradaySeries(symbol: symbol, date: "20260929", points: []), region: .cn))
    }

    func testFollowsTheLiveQuote() throws {
        let series = IntradaySeries(symbol: symbol, date: "20260929", points: [IntradayPoint(minute: 570, price: 10.0)])
        let sparkline = try XCTUnwrap(Sparkline(series: series, region: .cn))
        let calendar = MarketRegion.cn.calendar
        let time = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10, minute: 1))!
        let quote = Quote(symbol: symbol, name: "贵州茅台", price: 10.3, previousClose: 10, open: 10, volume: 100, timestamp: time)
        let updated = sparkline.updating(with: quote, region: .cn)
        XCTAssertEqual(updated.values[6], 10.3, "10:01 是第 31 分钟，落在第 6 段")
        XCTAssertEqual(updated.values[0], 10.0)

        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 14, minute: 59))!
        var old = quote
        old.timestamp = yesterday
        XCTAssertEqual(sparkline.updating(with: old, region: .cn), sparkline, "不是这一天的行情不动")
        old.timestamp = nil
        XCTAssertEqual(sparkline.updating(with: old, region: .cn), sparkline)
        XCTAssertEqual(sparkline.updating(with: nil, region: .cn), sparkline)
    }

    func testRangeIncludesThePreviousClose() throws {
        let sparkline = Sparkline(values: [10.2, nil, 10.5, 10.4])
        XCTAssertEqual(sparkline.range(reference: 10), 10...10.5)
        XCTAssertEqual(sparkline.range(reference: 0), 10.2...10.5, "没有昨收时只看价格")
        // 几乎没动：至少留出昨收的 0.4%。
        let flat = try XCTUnwrap(Sparkline(values: [100, 100.01]).range(reference: 100))
        XCTAssertEqual(flat.upperBound - flat.lowerBound, 0.4, accuracy: 1e-9)
        XCTAssertEqual((flat.upperBound + flat.lowerBound) / 2, 100.005, accuracy: 1e-9)
        XCTAssertNil(Sparkline(values: [nil, nil]).range(reference: 10))
    }
}
