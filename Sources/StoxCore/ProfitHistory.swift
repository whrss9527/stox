import Foundation

/// 一个市场一个交易日收盘后的持仓盈亏。
public struct ProfitRecord: Codable, Equatable, Sendable {
    /// 交易日，交易所当地的日期，例如 `2026-09-28`。
    public var day: String
    public var region: MarketRegion
    public var dayProfit: Double
    /// 日 K 只能估算每日变化，不能可靠还原历史成本、市值。
    public var totalProfit: Double?
    public var marketValue: Double?
    public var estimated: Bool

    public init(day: String, region: MarketRegion, dayProfit: Double, totalProfit: Double? = nil,
                marketValue: Double? = nil, estimated: Bool = false) {
        self.day = day
        self.region = region
        self.dayProfit = dayProfit
        self.totalProfit = totalProfit
        self.marketValue = marketValue
        self.estimated = estimated
    }

    private enum CodingKeys: String, CodingKey { case day, region, dayProfit, totalProfit, marketValue, estimated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        region = try c.decode(MarketRegion.self, forKey: .region)
        dayProfit = try c.decode(Double.self, forKey: .dayProfit)
        totalProfit = try c.decodeIfPresent(Double.self, forKey: .totalProfit)
        marketValue = try c.decodeIfPresent(Double.self, forKey: .marketValue)
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
    }
}

/// 每个交易日收盘后记下的持仓盈亏，按市场分开，只在这台 Mac 上；缺失日期可用日 K 估算补齐。
public struct ProfitHistory: Codable, Equatable, Sendable {
    /// 每个市场最多留这么多个交易日，大约一年。
    public static let keepDays = 250

    public private(set) var records: [ProfitRecord]

    public init(records: [ProfitRecord] = []) {
        self.records = records
    }

    /// 记下（或者更新）某个市场某个交易日的数，同一天再记就换成新的。
    public mutating func record(_ summary: PortfolioSummary, day: String) {
        let record = ProfitRecord(
            day: day, region: summary.region, dayProfit: summary.dayProfit,
            totalProfit: summary.totalProfit, marketValue: summary.marketValue
        )
        records.removeAll { $0.day == day && $0.region == summary.region }
        records.append(record)
        sortAndPrune()
    }

    mutating func sortAndPrune() {
        records.sort { $0.day == $1.day ? $0.region.rawValue < $1.region.rawValue : $0.day < $1.day }
        for region in MarketRegion.allCases {
            let days = records.filter { $0.region == region }.map(\.day)
            guard days.count > Self.keepDays else { continue }
            let dropped = Set(days.prefix(days.count - Self.keepDays))
            records.removeAll { $0.region == region && dropped.contains($0.day) }
        }
    }

    mutating func appendEstimated(_ record: ProfitRecord) {
        guard !records.contains(where: { $0.day == record.day && $0.region == record.region }) else { return }
        records.append(record)
    }

    /// 全部记录，制表符分隔，按日期从早到晚，粘贴到 Numbers、Excel 就是一张表；没有记录时是空的。
    public var tableText: String {
        guard !records.isEmpty else { return "" }
        let lines = records.map { record in
            [
                record.day,
                record.region.currency,
                QuoteFormatter.fixed(record.dayProfit, decimals: 2),
                record.totalProfit.map { QuoteFormatter.fixed($0, decimals: 2) } ?? "",
                record.marketValue.map { QuoteFormatter.fixed($0, decimals: 2) } ?? "",
                record.estimated ? L("估算") : "",
            ].joined(separator: "\t")
        }
        return ([L("日期\t币种\t今日盈亏\t持仓盈亏\t市值\t估算")] + lines).joined(separator: "\n")
    }

    /// 有记录的市场，按 A 股、港股、美股排。
    public var regions: [MarketRegion] {
        MarketRegion.allCases.filter { region in records.contains { $0.region == region } }
    }

    /// 某个市场最近 limit 个交易日的记录，从早到晚。
    public func recent(_ region: MarketRegion, limit: Int) -> [ProfitRecord] {
        Array(records.filter { $0.region == region }.suffix(max(limit, 0)))
    }

    /// 某个市场从 day（含）以来记下的今日盈亏加起来。
    public func dayProfitTotal(_ region: MarketRegion, since day: String) -> Double {
        records.filter { $0.region == region && $0.day >= day }.reduce(0) { $0 + $1.dayProfit }
    }

    /// day 所在的那一周的周一。
    public static func weekStart(of day: String, region: MarketRegion) -> String {
        guard let date = KlineCalendar.date(from: day, region: region),
              let start = KlineCalendar.calendar(for: region).dateInterval(of: .weekOfYear, for: date)?.start
        else { return day }
        return KlineCalendar.dayString(start, region: region)
    }

    /// 某个时刻在交易所当地是哪一天。
    public static func day(of date: Date, region: MarketRegion) -> String {
        KlineCalendar.dayString(date, region: region)
    }

    /// day 所在的那个月的 1 号。
    public static func monthStart(of day: String) -> String {
        String(day.prefix(8)) + "01"
    }
}
