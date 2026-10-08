import XCTest
@testable import StoxCore

final class MarketClockTests: XCTestCase {
    /// 2026-09-28 是周一。
    private func at(_ region: MarketRegion, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        region.calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testChinaSessions() {
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 28, 9, 0)), .closed)
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 28, 9, 20)), .preMarket)
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 28, 9, 30)), .trading)
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 28, 11, 29)), .trading)
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 28, 11, 30)), .lunchBreak)
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 28, 13, 0)), .trading)
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 28, 14, 59)), .trading)
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 28, 15, 0)), .closed)
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 26, 10, 0)), .closed, "周六")
        XCTAssertEqual(MarketClock.phase(for: .cn, at: at(.cn, 27, 10, 0)), .closed, "周日")
    }

    func testHongKongSessions() {
        XCTAssertEqual(MarketClock.phase(for: .hk, at: at(.hk, 28, 9, 15)), .preMarket)
        XCTAssertEqual(MarketClock.phase(for: .hk, at: at(.hk, 28, 12, 30)), .lunchBreak)
        XCTAssertEqual(MarketClock.phase(for: .hk, at: at(.hk, 28, 16, 5)), .trading)
        XCTAssertEqual(MarketClock.phase(for: .hk, at: at(.hk, 28, 16, 10)), .closed)
    }

    func testUnitedStatesSessionsUseEasternTime() {
        XCTAssertEqual(MarketClock.phase(for: .us, at: at(.us, 28, 3, 59)), .closed)
        XCTAssertEqual(MarketClock.phase(for: .us, at: at(.us, 28, 8, 0)), .preMarket)
        XCTAssertEqual(MarketClock.phase(for: .us, at: at(.us, 28, 9, 30)), .trading)
        XCTAssertEqual(MarketClock.phase(for: .us, at: at(.us, 28, 16, 0)), .afterHours)
        XCTAssertEqual(MarketClock.phase(for: .us, at: at(.us, 28, 20, 0)), .closed)
        // 北京时间周一 22:00 = 美东周一 10:00（夏令时）。
        let beijing = at(.cn, 28, 22, 0)
        XCTAssertEqual(MarketClock.phase(for: .us, at: beijing), .trading)
        // 北京时间周六 03:00 = 美东周五 15:00。
        XCTAssertEqual(MarketClock.phase(for: .us, at: at(.cn, 26, 3, 0)), .trading)
    }

    func testHolidayDetectedFromStaleQuotes() {
        // 国庆节 2026-10-01 周四：时间表显示交易中，但最新行情停在 9 月 30 日。
        let now = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 10, minute: 0))!
        let lastTrade = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15, minute: 0))!
        XCTAssertEqual(MarketClock.phase(for: .cn, at: now), .trading)
        XCTAssertEqual(MarketClock.effectivePhase(for: .cn, at: now, latestQuoteTime: lastTrade), .closed)
        XCTAssertEqual(MarketClock.effectivePhase(for: .cn, at: now, latestQuoteTime: now), .trading)
        XCTAssertEqual(MarketClock.effectivePhase(for: .cn, at: now, latestQuoteTime: nil), .trading)
        // 刚开盘的宽限期内不判定为休市。
        let justOpened = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9, minute: 31))!
        XCTAssertEqual(MarketClock.effectivePhase(for: .cn, at: justOpened, latestQuoteTime: lastTrade), .trading)
    }

    func testHongKongHalfDayWaitsUntilAfterNormalLunchAndDelayedReopening() {
        let calendar = MarketRegion.hk.calendar
        func time(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 12, day: 24, hour: hour, minute: minute))!
        }
        let latest = time(12, 0)
        for minute in [0, 20, 59] {
            XCTAssertEqual(MarketClock.effectivePhase(for: .hk, at: time(12, minute), latestQuoteTime: latest), .lunchBreak)
        }
        XCTAssertEqual(MarketClock.effectivePhase(for: .hk, at: time(13, 20), latestQuoteTime: latest), .trading)
        let now = time(13, 20).addingTimeInterval(1)
        let phase = MarketClock.effectivePhase(for: .hk, at: now, latestQuoteTime: latest)
        XCTAssertEqual(phase, .closed)
        XCTAssertEqual(CloseSummary.closedDay(region: .hk, phase: phase, latestQuoteTime: latest, now: now), "2026-12-24")
        XCTAssertEqual(RefreshPolicy.interval(base: 5, phases: [phase], slowWhenIdle: true), 60)
        // 正常交易日，下午第一批有延迟的行情仍然应当算交易中。
        XCTAssertEqual(MarketClock.effectivePhase(for: .hk, at: now, latestQuoteTime: time(13, 5)), .trading)
    }

    func testUSEarlyCloseInStandardTimeAndRecovery() {
        let calendar = MarketRegion.us.calendar
        let latest = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 13))!
        let boundary = latest.addingTimeInterval(10 * 60)
        XCTAssertEqual(MarketClock.effectivePhase(for: .us, at: boundary, latestQuoteTime: latest), .trading)
        let now = boundary.addingTimeInterval(1)
        let phase = MarketClock.effectivePhase(for: .us, at: now, latestQuoteTime: latest)
        XCTAssertEqual(phase, .closed)
        XCTAssertEqual(CloseSummary.closedDay(region: .us, phase: phase, latestQuoteTime: latest, now: now), "2026-11-27")
        XCTAssertEqual(MarketClock.effectivePhase(for: .us, at: now, latestQuoteTime: now), .trading)
        XCTAssertEqual(MarketClock.effectivePhase(for: .us, at: now, latestQuoteTime: nil), .trading)
    }

    func testSameDayStalenessAndSessionGraceForEveryStockMarket() {
        for region in [MarketRegion.cn, .hk, .us] {
            let threshold: TimeInterval = region == .hk ? 20 * 60 : 10 * 60
            let opened = at(region, 28, 9, 30)
            let preopen = opened.addingTimeInterval(-60)
            XCTAssertEqual(MarketClock.effectivePhase(for: region, at: opened.addingTimeInterval(threshold), latestQuoteTime: preopen), .trading)
            XCTAssertEqual(MarketClock.effectivePhase(for: region, at: opened.addingTimeInterval(threshold + 1), latestQuoteTime: preopen), .closed)
            let latest = at(region, 28, 10, 0)
            XCTAssertEqual(MarketClock.effectivePhase(for: region, at: latest.addingTimeInterval(threshold), latestQuoteTime: latest), .trading)
            XCTAssertEqual(MarketClock.effectivePhase(for: region, at: latest.addingTimeInterval(threshold + 1), latestQuoteTime: latest), .closed)
        }
        let morning = at(.cn, 28, 11, 30)
        XCTAssertEqual(MarketClock.effectivePhase(for: .cn, at: at(.cn, 28, 12, 30), latestQuoteTime: morning), .lunchBreak)
        XCTAssertEqual(MarketClock.effectivePhase(for: .cn, at: at(.cn, 28, 13, 10), latestQuoteTime: morning), .trading)
        XCTAssertEqual(MarketClock.effectivePhase(for: .cn, at: at(.cn, 28, 13, 11), latestQuoteTime: morning), .closed)
        XCTAssertEqual(MarketClock.effectivePhase(for: .cn, at: at(.cn, 28, 13, 11), latestQuoteTime: at(.cn, 28, 13, 10)), .trading)
    }

    func testExtendedSessionsAreNotClosedByStaleRegularQuotes() {
        let latest = at(.us, 28, 16, 0)
        XCTAssertEqual(MarketClock.effectivePhase(for: .us, at: at(.us, 28, 17, 0), latestQuoteTime: latest), .afterHours)
        XCTAssertEqual(MarketClock.effectivePhase(for: .us, at: at(.us, 29, 8, 0), latestQuoteTime: latest), .preMarket)
    }

    func testQuoteFailuresBackOffAndSuccessfulRecoveryResetsTheSchedule() {
        var retry = QuoteRetryBackoff()
        XCTAssertEqual(retry.interval(base: 3), 3)
        for delay in [6.0, 12, 24, 48, 60, 60, 60] {
            retry.failed()
            XCTAssertEqual(retry.interval(base: 3), delay)
        }
        retry.reset()
        XCTAssertEqual(retry.failures, 0)
        XCTAssertEqual(retry.interval(base: 3), 3)
        retry.failed()
        XCTAssertEqual(retry.interval(base: 3), 6)
        XCTAssertEqual(retry.interval(base: 60), 60)
        XCTAssertEqual(QuoteRetryBackoff().interval(base: 120), 120)
    }

    func testRefreshPolicy() {
        XCTAssertEqual(RefreshPolicy.interval(base: 5, phases: [.closed, .trading], slowWhenIdle: true), 5)
        XCTAssertEqual(RefreshPolicy.interval(base: 5, phases: [.closed, .lunchBreak], slowWhenIdle: true), 60)
        XCTAssertEqual(RefreshPolicy.interval(base: 5, phases: [], slowWhenIdle: true), 60)
        XCTAssertEqual(RefreshPolicy.interval(base: 5, phases: [.closed], slowWhenIdle: false), 5)
        XCTAssertEqual(RefreshPolicy.interval(base: 120, phases: [.closed], slowWhenIdle: true), 120)
        XCTAssertEqual(RefreshPolicy.interval(base: 0, phases: [.trading], slowWhenIdle: true), 1)
    }
}
