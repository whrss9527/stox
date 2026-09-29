import Foundation

/// A 股个股和 ETF 当天的资金流向。逐笔成交按一笔的金额分成超大单、大单、中单、小单：主力是超大单加大单，
/// 散户是中单加小单（腾讯的口径是一笔成交额不少于 20 万元或者不少于 6 万股算主力）。金额都是元，负数是净流出。
public struct FundFlow: Equatable, Sendable {
    /// 主力净流入：主力流入减主力流出。
    public var mainNetInflow: Double
    public var mainInflow: Double
    public var mainOutflow: Double
    public var retailInflow: Double
    public var retailOutflow: Double
    /// 超大单、大单、中单、小单各自的净流入。
    public var superNet: Double
    public var bigNet: Double
    public var mediumNet: Double
    public var smallNet: Double
    /// 主力净流入在全部 A 股里从大到小排第几；ETF 没有。
    public var rank: Rank?
    /// 接口给的一句话小结，例如“主力净流入额市场排名10/5571，占流通市值比例0.02%；……”。
    public var note: String?
    /// 当天每分钟累计的主力净流入，从早到晚。
    public var trend: [FundFlowPoint]
    /// 之前几个交易日（不含今天）每天的主力净流入，从早到晚。
    public var days: [FundFlowDay]

    public struct Rank: Equatable, Sendable {
        public var position: Int
        public var total: Int

        public init(position: Int, total: Int) {
            self.position = position
            self.total = total
        }
    }

    public init(
        mainNetInflow: Double,
        mainInflow: Double = 0,
        mainOutflow: Double = 0,
        retailInflow: Double = 0,
        retailOutflow: Double = 0,
        superNet: Double = 0,
        bigNet: Double = 0,
        mediumNet: Double = 0,
        smallNet: Double = 0,
        rank: Rank? = nil,
        note: String? = nil,
        trend: [FundFlowPoint] = [],
        days: [FundFlowDay] = []
    ) {
        self.mainNetInflow = mainNetInflow
        self.mainInflow = mainInflow
        self.mainOutflow = mainOutflow
        self.retailInflow = retailInflow
        self.retailOutflow = retailOutflow
        self.superNet = superNet
        self.bigNet = bigNet
        self.mediumNet = mediumNet
        self.smallNet = smallNet
        self.rank = rank
        self.note = note
        self.trend = trend
        self.days = days
    }

    public var direction: PriceDirection { PriceDirection(mainNetInflow) }

    /// 之前几个交易日加起来的主力净流入；没有时为 nil。
    public var daysTotal: Double? {
        days.isEmpty ? nil : days.reduce(0) { $0 + $1.mainNetInflow }
    }

    /// 画图时纵轴的范围：包含 0 和每分钟的累计值。没有分时数据时为 nil。
    public var trendRange: ClosedRange<Double>? {
        guard !trend.isEmpty else { return nil }
        let values = trend.map(\.mainNetInflow)
        let low = min(0, values.min() ?? 0), high = max(0, values.max() ?? 0)
        guard high > low else { return nil }
        return low...high
    }

    /// 横轴上离 offset（0 到 IntradayAxis.length）最近的点，鼠标悬停时用。
    public func point(nearest offset: Double) -> FundFlowPoint? {
        trend.min { lhs, rhs in
            abs(Double(IntradayAxis.offset(of: lhs.minute, region: .cn)) - offset)
                < abs(Double(IntradayAxis.offset(of: rhs.minute, region: .cn)) - offset)
        }
    }
}

/// 资金流向分时里的一分钟。
public struct FundFlowPoint: Equatable, Sendable {
    /// 交易所当地时间，自零点起的分钟数，和分时图一样。
    public var minute: Int
    /// 到这一分钟为止累计的主力净流入（元）。
    public var mainNetInflow: Double
    /// 这一分钟的价格；没有时为 nil。
    public var price: Double?

    public init(minute: Int, mainNetInflow: Double, price: Double? = nil) {
        self.minute = minute
        self.mainNetInflow = mainNetInflow
        self.price = price
    }
}

/// 某一个交易日的主力净流入。
public struct FundFlowDay: Equatable, Sendable {
    /// `2026-09-28`
    public var date: String
    public var mainNetInflow: Double

    public init(date: String, mainNetInflow: Double) {
        self.date = date
        self.mainNetInflow = mainNetInflow
    }
}

/// 腾讯的资金流向接口：
/// `https://proxy.finance.qq.com/cgi/cgi-bin/fundflow/hsfundtab?code=sh600519&type=todayFundFlow,todayFundTrend,fiveDayFundFlow`。
///
/// type 可以一次要几样，逗号分开：`todayFundFlow` 是当天的合计，`todayFundTrend` 是每分钟的累计，
/// `fiveDayFundFlow` 是之前 5 个交易日每天的主力净流入。只有 A 股个股和 ETF 有，港股、美股、指数不请求。
public enum TencentFundFlow {
    public static let endpoint = "https://proxy.finance.qq.com/cgi/cgi-bin/fundflow/hsfundtab"

    /// 这只有没有资金流向：沪深北的个股和 ETF（指数、场外基金、港股、美股没有）。
    public static func supports(_ symbol: Symbol) -> Bool {
        switch symbol.market {
        case .sh, .sz, .bj: return !symbol.isIndex
        case .hk, .us, .jj: return false
        }
    }

    public static func url(for symbol: Symbol) -> URL? {
        guard supports(symbol) else { return nil }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "code", value: symbol.rawValue),
            URLQueryItem(name: "type", value: "todayFundFlow,todayFundTrend,fiveDayFundFlow"),
        ]
        return components?.url
    }

    /// 解析 `{"code":0,"msg":"ok","data":{"todayFundFlow":{"mainNetIn":"248174709","mainIn":"1139175994",…},
    /// "todayFundTrend":{"minList":[{"time":"202609290930","Price":"1241.74","MainNetInflow":"18315130",…}]},
    /// "fiveDayFundFlow":{"DayMainNetInList":[{"date":"2026-09-21","mainNetIn":"-26867603"},…]}}}`。
    /// 数字都是字符串。没有当天的合计（code 不是 0、这只没有资金流向）时返回 nil。
    public static func parse(_ data: Data) -> FundFlow? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? Int ?? (root["code"] as? String).flatMap(Int.init)) == 0,
              let body = root["data"] as? [String: Any],
              let today = body["todayFundFlow"] as? [String: Any],
              let mainNet = number(today["mainNetIn"])
        else { return nil }
        let summary = today["summary"] as? [String: Any]
        return FundFlow(
            mainNetInflow: mainNet,
            mainInflow: number(today["mainIn"]) ?? 0,
            mainOutflow: number(today["mainOut"]) ?? 0,
            retailInflow: number(today["retailIn"]) ?? 0,
            retailOutflow: number(today["retailOut"]) ?? 0,
            superNet: number(today["superFlow"]) ?? 0,
            bigNet: number(today["bigFlow"]) ?? 0,
            mediumNet: number(today["normalFlow"]) ?? 0,
            smallNet: number(today["smallFlow"]) ?? 0,
            rank: rank(summary?["rank"] as? String),
            note: note(summary?["s0"] as? String),
            trend: trend(body["todayFundTrend"] as? [String: Any]),
            days: days(body["fiveDayFundFlow"] as? [String: Any])
        )
    }

    /// `10/5571`：第 10 名，一共 5571 只。
    static func rank(_ text: String?) -> FundFlow.Rank? {
        guard let parts = text?.split(separator: "/"), parts.count == 2,
              let position = Int(parts[0]), let total = Int(parts[1]), position > 0, total >= position
        else { return nil }
        return FundFlow.Rank(position: position, total: total)
    }

    /// 接口的小结。ETF 没有排名，开头会多一个逗号，去掉。
    static func note(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "，,；; ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 每分钟的累计主力净流入。time 是 `202609290930`，取最后 4 位的时、分。
    static func trend(_ value: [String: Any]?) -> [FundFlowPoint] {
        guard let rows = value?["minList"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let time = row["time"] as? String, time.count >= 4,
                  let hour = Int(time.suffix(4).prefix(2)), let minute = Int(time.suffix(2)),
                  let flow = number(row["MainNetInflow"])
            else { return nil }
            return FundFlowPoint(minute: hour * 60 + minute, mainNetInflow: flow, price: number(row["Price"]).flatMap { $0 > 0 ? $0 : nil })
        }
        .sorted { $0.minute < $1.minute }
    }

    static func days(_ value: [String: Any]?) -> [FundFlowDay] {
        guard let rows = value?["DayMainNetInList"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let date = row["date"] as? String, !date.isEmpty, let flow = number(row["mainNetIn"]) else { return nil }
            return FundFlowDay(date: date, mainNetInflow: flow)
        }
        .sorted { $0.date < $1.date }
    }

    /// 数字大多是字符串，偶尔是数。
    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let text = value as? String {
            number = Double(text)
        } else {
            number = (value as? NSNumber)?.doubleValue
        }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
}
