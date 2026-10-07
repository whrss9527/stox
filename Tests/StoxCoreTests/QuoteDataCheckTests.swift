import XCTest
@testable import StoxCore

final class QuoteDataCheckTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-07T10:00:00Z")!

    func testReviewedResponsesAndHolidayAgeWindowPass() throws {
        for source in [QuoteDataSource.tencent, .sina] {
            let raw = try XCTUnwrap(source.snapshot())
            XCTAssertEqual(QuoteDataCheck.differences(raw, source: source, symbols: QuoteDataCheck.defaultSymbols, now: now), [])
        }
    }

    func testShiftedFieldsAndMissingRecordsAreReported() throws {
        let raw = try XCTUnwrap(QuoteDataSource.tencent.snapshot())
        let records = TencentQuoteParser.records(in: raw)
        var fields = records[0].1.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        fields.insert("shifted", at: 3)
        let shifted = "v_\(records[0].0)=\"\(fields.joined(separator: "~"))\";"
        let differences = QuoteDataCheck.differences(shifted, source: .tencent, symbols: QuoteDataCheck.defaultSymbols, now: now)
        XCTAssertTrue(differences.contains { $0.contains("fields=89, snapshot=88") })
        XCTAssertTrue(differences.contains { $0.contains("hk00700: missing raw record") })
    }

    func testPriceVolumeTimestampAndYearHighDriftAreReported() throws {
        let raw = try XCTUnwrap(QuoteDataSource.tencent.snapshot())
        let record = try XCTUnwrap(TencentQuoteParser.records(in: raw).first)
        let fields = record.1.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        for (index, value, expected) in [(3, "999999", "price"), (4, "0", "previousClose"), (35, "1/1/1", "amount/volume"),
                                          (30, "20200101120000", "timestamp"), (67, "1", "high52Week"), (67, "", "high52Week")] {
            var changed = fields
            changed[index] = value
            let modified = "v_\(record.0)=\"\(changed.joined(separator: "~"))\";"
            let differences = QuoteDataCheck.differences(modified, source: .tencent, symbols: [Symbol(record.0)!], now: now)
            XCTAssertTrue(differences.contains { $0.contains(expected) }, "\(index): \(differences)")
        }
    }

    func testAgeOverrideIsExplicitAndFutureQuotesStillFail() throws {
        let raw = try XCTUnwrap(QuoteDataSource.tencent.snapshot())
        let nextMonth = now.addingTimeInterval(30 * 86400)
        let differences = QuoteDataCheck.differences(raw, source: .tencent, symbols: QuoteDataCheck.defaultSymbols, now: nextMonth)
        XCTAssertTrue(differences.contains { $0.contains("timestamp") })
        XCTAssertEqual(QuoteDataCheck.differences(raw, source: .tencent, symbols: QuoteDataCheck.defaultSymbols, now: nextMonth, maxAgeDays: 40), [])
        XCTAssertFalse(QuoteDataCheck.differences(raw, source: .tencent, symbols: QuoteDataCheck.defaultSymbols, now: now.addingTimeInterval(-20 * 86400)).isEmpty)
    }
}
