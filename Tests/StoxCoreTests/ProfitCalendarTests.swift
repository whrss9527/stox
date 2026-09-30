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

    func testSummarisesTheYear() throws {
        var history = history()
        history.record(PortfolioSummary(region: .cn, marketValue: 1000, costValue: 900, dayProfit: -400, count: 1), day: "2026-03-02")
        history.record(PortfolioSummary(region: .cn, marketValue: 1000, costValue: 900, dayProfit: 70, count: 1), day: "2025-12-31")
        let year = ProfitYear(history: history, region: .cn, year: 2026)
        XCTAssertEqual(year.title, "2026年")
        XCTAssertEqual(year.months.count, 12)
        XCTAssertEqual(year.months[8].total ?? 0, 250.001, accuracy: 1e-9, "9 月")
        XCTAssertEqual(year.months[8].recordedDays, 4)
        XCTAssertEqual(year.months[7].total, 30, "8 月 31 号")
        XCTAssertEqual(year.months[2].total, -400)
        XCTAssertNil(year.months[0].total, "1 月没有记录")
        XCTAssertEqual(year.months[0].recordedDays, 0)
        XCTAssertEqual(year.recordedMonths.map(\.month), [3, 8, 9], "去年 12 月的不算")
        XCTAssertEqual(try XCTUnwrap(year.total), -119.999, accuracy: 1e-9)
        XCTAssertEqual(year.profitMonths, 2)
        XCTAssertEqual(year.lossMonths, 1)
        XCTAssertEqual(year.largestMagnitude, 400)

        XCTAssertEqual(ProfitYear(history: history, region: .hk, year: 2026).recordedMonths.map(\.month), [9], "港币分开算")
        let empty = ProfitYear(history: history, region: .us, year: 2026)
        XCTAssertNil(empty.total)
        XCTAssertNil(empty.largestMagnitude)
        XCTAssertEqual(ProfitYear.yearRange(of: history, region: .cn), 2025...2026)
        XCTAssertNil(ProfitYear.yearRange(of: history, region: .us))
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
