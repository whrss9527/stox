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
    public static let weekdayTitles = [L("一"), L("二"), L("三"), L("四"), L("五"), L("六"), L("日")]

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

    /// `2026年9月`，英文界面是 `September 2026`。
    public var title: String { AppLanguage.monthTitle(year: year, month: month) }

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

/// 盈亏日历按年看：12 个月各自记下的今日盈亏加起来。
public struct ProfitYear: Equatable, Sendable {
    public struct Month: Equatable, Sendable, Identifiable {
        /// 1 到 12。
        public var month: Int
        /// 这个月记下的今日盈亏加起来；一天都没记时为 nil。
        public var total: Double?
        /// 记了几个交易日。
        public var recordedDays: Int

        public var id: Int { month }
    }

    public var year: Int
    public var months: [Month]

    /// region 这个市场在 year 年的 12 个月。
    public init(history: ProfitHistory, region: MarketRegion, year: Int) {
        // 同一天记了两次时用后面的，和按月看一样。
        let profits = Dictionary(
            history.records.filter { $0.region == region }.map { ($0.day, $0.dayProfit) },
            uniquingKeysWith: { _, last in last }
        )
        var totals: [Int: (total: Double, days: Int)] = [:]
        for (day, profit) in profits {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, parts[0] == year, (1...12).contains(parts[1]) else { continue }
            let current = totals[parts[1]] ?? (0, 0)
            totals[parts[1]] = (current.total + profit, current.days + 1)
        }
        self.year = year
        self.months = (1...12).map { month in
            Month(month: month, total: totals[month]?.total, recordedDays: totals[month]?.days ?? 0)
        }
    }

    /// 有记录的月份。
    public var recordedMonths: [Month] { months.filter { $0.total != nil } }

    /// 这一年记下的今日盈亏加起来；一个月都没有时为 nil。
    public var total: Double? {
        let months = recordedMonths
        return months.isEmpty ? nil : months.reduce(0) { $0 + ($1.total ?? 0) }
    }

    /// 赚了的月数、亏了的月数（不到一分钱的不算）。
    public var profitMonths: Int { recordedMonths.filter { ($0.total ?? 0) >= 0.005 }.count }
    public var lossMonths: Int { recordedMonths.filter { ($0.total ?? 0) <= -0.005 }.count }

    /// 赚（亏）得最多的一个月的数，画格子的底色深浅时用；没有记录时为 nil。
    public var largestMagnitude: Double? {
        recordedMonths.compactMap { $0.total.map(abs) }.max()
    }

    /// `2026年`，英文界面是 `2026`。
    public var title: String { AppLanguage.isEnglish ? "\(year)" : "\(year)年" }  // l10n-ignore

    /// 某个市场有记录的最早、最晚的年份，翻页时用；没有记录时为 nil。
    public static func yearRange(of history: ProfitHistory, region: MarketRegion) -> ClosedRange<Int>? {
        ProfitCalendar.monthRange(of: history, region: region).map { ($0.lowerBound / 12)...($0.upperBound / 12) }
    }
}
