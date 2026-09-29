import XCTest
@testable import StoxCore

final class ProfitCalendarTests: XCTestCase {
    private func history() -> ProfitHistory {
        var history = ProfitHistory()
        let days: [(String, MarketRegion, Double)] = [
            ("2026-08-31", .cn, 30),
            ("2026-09-21", .cn, 100),
            ("2026-09-22", .cn, -50),
            ("2026-09-24", .cn, 0.001),
            ("2026-09-28", .cn, 200),
            ("2026-09-28", .hk, -10),
        ]
        for (day, region, profit) in days {
            history.record(PortfolioSummary(region: region, marketValue: 1000, costValue: 900, dayProfit: profit, count: 1), day: day)
        }
        return history
    }

    func testLaysOutTheMonthFromMonday() {
        let calendar = ProfitCalendar(history: history(), region: .cn, year: 2026, month: 9)
        XCTAssertEqual(calendar.title, "2026年9月")
        XCTAssertEqual(calendar.leadingBlanks, 1, "2026 年 9 月 1 号是周二")
        XCTAssertEqual(calendar.cells.count, 30)
        XCTAssertEqual(calendar.cells.first?.date, "2026-09-01")
        XCTAssertEqual(calendar.cells.filter(\.isWeekend).map(\.day), [5, 6, 12, 13, 19, 20, 26, 27])
        XCTAssertEqual(calendar.cells[20].dayProfit, 100, "21 号")
        XCTAssertNil(calendar.cells[24].dayProfit, "25 号中秋节没有记录")
        XCTAssertEqual(calendar.cells[27].dayProfit, 200, "只算这个市场的，港股那天的不混进来")

        XCTAssertEqual(ProfitCalendar(history: history(), region: .cn, year: 2026, month: 2).cells.count, 28)
        XCTAssertEqual(ProfitCalendar(history: history(), region: .cn, year: 2026, month: 3).leadingBlanks, 6, "2026 年 3 月 1 号是周日")
    }

    func testSummarisesTheMonth() throws {
        let calendar = ProfitCalendar(history: history(), region: .cn, year: 2026, month: 9)
        XCTAssertEqual(calendar.recordedDays.count, 4)
        XCTAssertEqual(try XCTUnwrap(calendar.total), 250.001, accuracy: 1e-9, "上个月 31 号的不算")
        XCTAssertEqual(calendar.profitDays, 2)
        XCTAssertEqual(calendar.lossDays, 1, "不到一分钱的不算赚也不算亏")
        XCTAssertEqual(calendar.largestMagnitude, 200)

        let empty = ProfitCalendar(history: history(), region: .us, year: 2026, month: 9)
        XCTAssertNil(empty.total)
        XCTAssertNil(empty.largestMagnitude)
        XCTAssertEqual(empty.profitDays + empty.lossDays, 0)
    }

    func testMonthNavigation() throws {
        func shifted(_ year: Int, _ month: Int, _ offset: Int) -> [Int] {
            let result = ProfitCalendar.shift(year: year, month: month, by: offset)
            return [result.year, result.month]
        }
        XCTAssertEqual(shifted(2026, 1, -1), [2025, 12])
        XCTAssertEqual(shifted(2026, 12, 1), [2027, 1])
        XCTAssertEqual(shifted(2026, 9, -13), [2025, 8])

        let range = try XCTUnwrap(ProfitCalendar.monthRange(of: history(), region: .cn))
        XCTAssertEqual(range.lowerBound, 2026 * 12 + 7, "最早是 8 月")
        XCTAssertEqual(range.upperBound, 2026 * 12 + 8, "最晚是 9 月")
        XCTAssertNil(ProfitCalendar.monthRange(of: history(), region: .us))
    }
}
