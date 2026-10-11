import Foundation

extension ProfitHistory {
    public static let backfillLimit = 60
    /// 60 个已结束的交易日、前一天昨收，另留一根给今天尚未收盘的 K 线。
    public static let backfillFetchCount = backfillLimit + 2

    /// 只补没有记录的日期。按交易记录倒推股数，交易当天不估算；一个市场的数据不齐时整天跳过。
    /// 没有交易记录的手填持仓视为这段时间一直持有，结果始终标为估算。
    public mutating func backfill(items: [WatchItem], series: [Symbol: KlineSeries], now: Date) {
        let candidates = items.filter {
            $0.symbol.canHold && ($0.holding != nil || !$0.trades.isEmpty || !$0.unknownTrades.isEmpty)
        }
        for region in MarketRegion.allCases {
            let holdings = candidates.filter { $0.symbol.market.region == region }
            guard !holdings.isEmpty, holdings.allSatisfy({ $0.unknownTrades.isEmpty }) else { continue }
            let today = Self.day(of: now, region: region)
            var prices: [Symbol: [String: (close: Double, previous: Double)]] = [:]
            var days = Set<String>()
            for item in holdings {
                guard let source = series[item.symbol], source.symbol == item.symbol, source.period == .day else { continue }
                let candles = source.candles.sorted { $0.date < $1.date }
                // 重复、非法日期或价格使昨收不可靠，不从这份数据估算。
                guard Set(candles.map(\.date)).count == candles.count,
                      candles.allSatisfy({ candle in
                          guard let date = KlineCalendar.date(from: candle.date, region: region) else { return false }
                          let weekday = region.calendar.component(.weekday, from: date)
                          return Self.day(of: date, region: region) == candle.date && weekday != 1 && weekday != 7
                              && candle.close > 0 && candle.close.isFinite
                      }) else { continue }
                var values: [String: (close: Double, previous: Double)] = [:]
                for index in candles.indices.dropFirst() where candles[index].date < today {
                    let candle = candles[index]
                    values[candle.date] = (candle.close, candles[index - 1].close)
                    days.insert(candle.date)
                }
                prices[item.symbol] = values
            }
            for day in days.sorted().suffix(Self.backfillLimit) {
                guard !records.contains(where: { $0.region == region && $0.day == day }) else { continue }
                var total = 0.0
                var held = false
                var complete = true
                for item in holdings {
                    guard let shares = Self.shares(of: item, on: day) else { complete = false; break }
                    guard shares > 0 else { continue }
                    guard let value = prices[item.symbol]?[day] else { complete = false; break }
                    total += shares * (value.close - value.previous)
                    held = true
                }
                guard complete, held, total.isFinite else { continue }
                appendEstimated(ProfitRecord(day: day, region: region, dayProfit: total, estimated: true))
            }
        }
        sortAndPrune()
    }

    private static func shares(of item: WatchItem, on day: String) -> Double? {
        guard item.holding.map(\.isValid) ?? true,
              !item.trades.contains(where: { $0.day == day }),
              item.trades.allSatisfy({ trade in
                  guard let date = KlineCalendar.date(from: trade.day, region: item.symbol.market.region) else { return false }
                  return Self.day(of: date, region: item.symbol.market.region) == trade.day
                      && trade.shares > 0 && trade.shares.isFinite && trade.price >= 0 && trade.price.isFinite
                      && (trade.bonus ?? 0) >= 0 && (trade.bonus ?? 0).isFinite
              }) else { return nil }
        // 达到日志上限时，更早的交易可能已丢弃，不猜它们之前的持仓。
        if item.trades.count >= Trade.limit, let oldest = item.trades.map(\.day).min(), day <= oldest { return nil }
        var shares = item.holding?.shares ?? 0
        let trades = item.trades.enumerated().sorted {
            $0.element.day == $1.element.day ? $0.offset > $1.offset : $0.element.day > $1.element.day
        }
        for (_, trade) in trades where trade.day > day {
            switch trade.side {
            case .buy: shares -= trade.shares
            case .sell: shares += trade.shares
            case .dividend: shares -= trade.shares * (trade.bonus ?? 0)
            }
            guard shares.isFinite, shares >= -1e-9 else { return nil }
            shares = max(shares, 0)
        }
        return shares
    }
}
