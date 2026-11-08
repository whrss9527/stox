import Foundation

/// Binance USDT 现货的公开字段；不把滚动 24 小时开盘价当作日 K 开盘价。
public enum CryptoQuoteParser {
    public static func parse(_ data: Data, symbols: [Symbol], now: Date = Date()) -> [Symbol: Quote] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let rows: [[String: Any]]
        if let array = object as? [Any] { rows = array.compactMap { $0 as? [String: Any] } }
        else if let row = object as? [String: Any], row["symbol"] != nil { rows = [row] }
        else { return [:] }
        let requested = Dictionary(symbols.filter(\.isCrypto).map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        var quotes: [Symbol: Quote] = [:]
        for row in rows {
            guard let code = row["symbol"] as? String, let symbol = requested[code],
                  let entry = CryptoCatalog.entry(for: symbol),
                  let price = CryptoNumber.positive(row["lastPrice"]),
                  let reference = CryptoNumber.positive(row["openPrice"]),
                  let high = CryptoNumber.positive(row["highPrice"]),
                  let low = CryptoNumber.positive(row["lowPrice"]), low <= high,
                  price >= low, price <= high, reference >= low, reference <= high,
                  let volume = CryptoNumber.nonnegative(row["volume"]),
                  let amount = CryptoNumber.nonnegative(row["quoteVolume"]),
                  let change = CryptoNumber.finite(row["priceChange"]),
                  let percent = CryptoNumber.finite(row["priceChangePercent"]),
                  let opening = CryptoNumber.milliseconds(row["openTime"], latest: now),
                  let closing = CryptoNumber.milliseconds(row["closeTime"], latest: now), closing >= opening,
                  closing - opening <= 90_000_000
            else { continue }
            quotes[symbol] = Quote(symbol: symbol, name: entry.name, price: price, previousClose: reference,
                open: reference, high: high, low: low, change: change, changePercent: percent,
                volume: volume, amount: amount, timestamp: Date(timeIntervalSince1970: closing / 1000),
                priceDecimals: CryptoCatalog.priceDecimals(for: price), exchangeCode: code, englishName: entry.english)
        }
        return quotes
    }
}

public enum CryptoKlineParser {
    struct Bar {
        let openTime: Double
        let closeTime: Double
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
    }

    static func bars(_ data: Data, now: Date, maximumDuration: TimeInterval) -> [Bar] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var bars: [Double: Bar] = [:]
        for case let row as [Any] in rows {
            guard row.count >= 7,
                  let openTime = CryptoNumber.milliseconds(row[0], latest: now),
                  let closeTime = CryptoNumber.milliseconds(row[6], latest: now.addingTimeInterval(maximumDuration)),
                  closeTime >= openTime, closeTime - openTime <= maximumDuration * 1000,
                  let open = CryptoNumber.positive(row[1]), let high = CryptoNumber.positive(row[2]),
                  let low = CryptoNumber.positive(row[3]), let close = CryptoNumber.positive(row[4]),
                  low <= min(open, close), high >= max(open, close), low <= high,
                  let volume = CryptoNumber.nonnegative(row[5])
            else { continue }
            bars[openTime] = Bar(openTime: openTime, closeTime: closeTime, open: open, high: high, low: low, close: close, volume: volume)
        }
        return bars.values.sorted { $0.openTime < $1.openTime }
    }

    public static func intraday(_ data: Data, symbol: Symbol, now: Date) -> IntradaySeries? {
        guard CryptoCatalog.entry(for: symbol) != nil else { return nil }
        let end = floor(now.timeIntervalSince1970 * 1000)
        let start = Date(timeIntervalSince1970: (end - 86_400_000) / 1000)
        let points = bars(data, now: now, maximumDuration: 300).filter {
            $0.openTime >= end - 86_400_000 && $0.openTime <= end
        }.suffix(288).map { bar in
            let minute = Int((min(bar.closeTime, end) - start.timeIntervalSince1970 * 1000) / 60_000)
            return IntradayPoint(minute: min(max(minute, 0), 1440), price: bar.close, volume: bar.volume)
        }
        guard !points.isEmpty else { return nil }
        return IntradaySeries(symbol: symbol, date: day(start), points: points, start: start)
    }

    public static func kline(_ data: Data, symbol: Symbol, period: KlinePeriod, count: Int, now: Date) -> KlineSeries? {
        guard CryptoCatalog.entry(for: symbol) != nil else { return nil }
        let duration: TimeInterval
        switch period { case .day: duration = 86_400; case .week: duration = 604_800; case .month: duration = 31 * 86_400 }
        let candles = bars(data, now: now, maximumDuration: duration).suffix(min(max(count, 1), KlineChartData.fetchCount)).map { bar in
            // 交易所按 UTC 周期起点标识蜡烛；未完成周/月不能随着“现在”跨午夜改日期。
            Candle(date: day(Date(timeIntervalSince1970: bar.openTime / 1000)),
                   open: bar.open, close: bar.close, high: bar.high, low: bar.low, volume: bar.volume)
        }
        guard !candles.isEmpty else { return nil }
        return KlineSeries(symbol: symbol, period: period, candles: candles)
    }

    private static func day(_ date: Date) -> String {
        let parts = MarketRegion.crypto.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

enum CryptoNumber {
    static func finite(_ raw: Any?) -> Double? {
        let value: Double?
        if let string = raw as? String { value = Double(string) }
        else if let number = raw as? NSNumber, String(cString: number.objCType) != "c" { value = number.doubleValue }
        else { value = nil }
        guard let value, value.isFinite else { return nil }
        return value
    }
    static func positive(_ raw: Any?) -> Double? { finite(raw).flatMap { $0 > 0 ? $0 : nil } }
    static func nonnegative(_ raw: Any?) -> Double? { finite(raw).flatMap { $0 >= 0 ? $0 : nil } }
    static func milliseconds(_ raw: Any?, latest: Date) -> Double? {
        guard let value = finite(raw), value.rounded() == value, value >= 1_262_304_000_000,
              value <= latest.timeIntervalSince1970 * 1000 + 300_000 else { return nil }
        return value
    }
}
