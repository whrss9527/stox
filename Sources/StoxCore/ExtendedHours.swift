import Foundation

/// 美股个股盘前或盘后的最新成交。
public struct ExtendedHoursQuote: Sendable, Equatable {
    public enum Session: Sendable, Equatable {
        case preMarket, afterHours

        public var displayName: String {
            switch self {
            case .preMarket: return L("盘前")
            case .afterHours: return L("盘后")
            }
        }
    }

    public var session: Session
    public var price: Double
    /// 成交时间；接口没给时为 nil。
    public var time: Date?

    public init(session: Session, price: Double, time: Date? = nil) {
        self.session = session
        self.price = price
        self.time = time
    }

    /// 这笔成交是不是紧跟在这份行情后面：盘后的要和行情是同一天，盘前的要晚于行情那天。
    /// 接口有时还没切到最新的时段，对不上时不用，免得拿昨天的盘后价和今天的收盘价比。
    public func follows(_ quote: Quote) -> Bool {
        guard let time, let quoteTime = quote.timestamp else { return true }
        let calendar = MarketRegion.us.calendar
        let day = calendar.startOfDay(for: time)
        let quoteDay = calendar.startOfDay(for: quoteTime)
        switch session {
        case .afterHours: return day == quoteDay
        case .preMarket: return day > quoteDay
        }
    }

    /// 相对常规交易收盘价的涨跌和涨跌幅。常规交易时段以外行情里的现价不再变：
    /// 盘后时是当天的收盘价，盘前时是上一个交易日的收盘价。和行情对不上时为 nil。
    public func change(from quote: Quote) -> (change: Double, percent: Double)? {
        guard price > 0, quote.price > 0, follows(quote) else { return nil }
        let change = price - quote.price
        return (change, change / quote.price * 100)
    }
}

/// 解析腾讯美股 K 线（`usfqkline`）和分时（`UsMinute`）接口返回里的 `pandata`：
///
/// `{"last":"338.43","volume":"31458547","pct":"-0.77","netchange":"-2.64","time":"2026-09-28 16:03:14","tag":"after","season":"EST"}`
///
/// `last` 是盘前或盘后的最新成交价，`tag` 是 `pre`（盘前）或 `after`（盘后），`time` 是美东时间。
/// `pct`、`netchange` 相对的是前一个交易日的收盘，盘后时把当天常规交易的涨跌也算进去了，所以不用，
/// 涨跌按行情里的收盘价自己算。常规交易时段里 `last` 是 -1。
public enum TencentExtendedHoursParser {
    public static func parse(_ data: Data) -> ExtendedHoursQuote? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = json["data"] as? [String: Any],
              // 只请求了一只，键是带交易所后缀的代码（usAAPL.OQ），直接取唯一的那个。
              all.count == 1,
              let entry = all.values.first as? [String: Any],
              let pandata = entry["pandata"] as? [String: Any]
        else { return nil }
        return parse(pandata: pandata)
    }

    static func parse(pandata: [String: Any]) -> ExtendedHoursQuote? {
        let last: Double?
        if let text = pandata["last"] as? String {
            last = Double(text)
        } else {
            last = (pandata["last"] as? NSNumber)?.doubleValue
        }
        guard let price = last, price > 0 else { return nil }
        let time = (pandata["time"] as? String).flatMap {
            TencentQuoteParser.parseTimestamp($0, timeZone: MarketRegion.us.timeZone)
        }
        let tag = (pandata["tag"] as? String)?.lowercased() ?? ""
        let session: ExtendedHoursQuote.Session
        if tag.hasPrefix("pre") || tag.hasPrefix("before") {
            session = .preMarket
        } else if tag.hasPrefix("after") || tag.hasPrefix("post") {
            session = .afterHours
        } else {
            // 认不出标签时按美东时间分：中午以前是盘前，以后是盘后。
            guard let time else { return nil }
            session = MarketRegion.us.calendar.component(.hour, from: time) < 12 ? .preMarket : .afterHours
        }
        return ExtendedHoursQuote(session: session, price: price, time: time)
    }
}
