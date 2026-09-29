import Foundation

/// 盈亏日历里的一个月：按周一到周日排成几行，每天一格，记过的那天格子里是它的今日盈亏。
public struct ProfitCalendar: Equatable, Sendable {
    public struct Cell: Equatable, Sendable, Identifiable {
        /// 这个月的第几天。
        public var day: Int
        /// `2026-09-28`
        public var date: String
        /// 那天收盘后记下的今日盈亏；周末、节假日、那天没开机时为 nil。
        public var dayProfit: Double?
        /// 是不是周六、周日。
        public var isWeekend: Bool

        public var id: String { date }
    }

    public var year: Int
    public var month: Int
    /// 第一行前面空几格：这个月 1 号是周几，周一是 0，周日是 6。
    public var leadingBlanks: Int
    public var cells: [Cell]

    /// 一周几天：周一到周日。
    public static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]

    /// region 这个市场在 year 年 month 月的日历。
    public init(history: ProfitHistory, region: MarketRegion, year: Int, month: Int) {
        let calendar = region.calendar
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)) ?? Date(timeIntervalSince1970: 0)
        let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        // weekday：周日是 1、周一是 2……周六是 7。
        let weekday = calendar.component(.weekday, from: first)
        let profits = Dictionary(
            history.records.filter { $0.region == region }.map { ($0.day, $0.dayProfit) },
            uniquingKeysWith: { _, last in last }
        )
        self.year = year
        self.month = month
        self.leadingBlanks = (weekday + 5) % 7
        self.cells = (1...max(days, 1)).map { day in
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            let column = ((weekday + 5) % 7 + day - 1) % 7
            return Cell(day: day, date: date, dayProfit: profits[date], isWeekend: column >= 5)
        }
    }

    /// 这个月里记过的交易日。
    public var recordedDays: [Cell] { cells.filter { $0.dayProfit != nil } }

    /// 这个月记下的今日盈亏加起来；一天都没有时为 nil。
    public var total: Double? {
        let days = recordedDays
        return days.isEmpty ? nil : days.reduce(0) { $0 + ($1.dayProfit ?? 0) }
    }

    /// 赚了的天数、亏了的天数（不到一分钱的不算）。
    public var profitDays: Int { recordedDays.filter { ($0.dayProfit ?? 0) >= 0.005 }.count }
    public var lossDays: Int { recordedDays.filter { ($0.dayProfit ?? 0) <= -0.005 }.count }

    /// 赚得最多的一天的数，画格子的底色深浅时用；没有记录时为 nil。
    public var largestMagnitude: Double? {
        recordedDays.compactMap { $0.dayProfit.map(abs) }.max()
    }

    /// `2026年9月`
    public var title: String { "\(year)年\(month)月" }

    /// 往前、往后挪 offset 个月。
    public static func shift(year: Int, month: Int, by offset: Int) -> (year: Int, month: Int) {
        let index = year * 12 + (month - 1) + offset
        return (index / 12, index % 12 + 1)
    }

    /// 某个市场有记录的最早、最晚的月份，翻页时用；没有记录时为 nil。
    public static func monthRange(of history: ProfitHistory, region: MarketRegion) -> ClosedRange<Int>? {
        let months = history.records.filter { $0.region == region }.compactMap { record -> Int? in
            let parts = record.day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return parts[0] * 12 + parts[1] - 1
        }
        guard let low = months.min(), let high = months.max() else { return nil }
        return low...high
    }
}
