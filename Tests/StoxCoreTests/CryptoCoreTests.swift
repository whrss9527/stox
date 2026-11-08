import XCTest
@testable import StoxCore

final class CryptoCoreTests: XCTestCase {
    private func utc(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testExplicitPairsKeepStableIdentityWithoutStealingStockTickers() throws {
        let bitcoin = try XCTUnwrap(Symbol("ccBTCUSDT"))
        XCTAssertEqual(bitcoin.market, .crypto)
        XCTAssertEqual(bitcoin.market.rawValue, "cc")
        XCTAssertEqual(bitcoin.rawValue, "ccBTCUSDT")
        XCTAssertEqual(bitcoin.displayCode, "BTC/USDT")
        for input in ["BTCUSDT", "btc/usdt", "ccBTCUSDT", "CCBTCUSDT", " BTC / USDT "] {
            XCTAssertEqual(SymbolInput.parse(input), bitcoin, input)
            XCTAssertTrue(SymbolInput.isExplicitCode(input), input)
        }
        for ticker in ["BTC", "ETH", "SOL", "BNB", "CCL"] {
            XCTAssertEqual(SymbolInput.parse(ticker)?.rawValue, "us" + ticker)
            XCTAssertFalse(SymbolInput.isExplicitCode(ticker))
        }
        XCTAssertEqual(SymbolInput.parse("ccl")?.rawValue, "usCCL")
        XCTAssertEqual(SymbolInput.parse("ccep")?.rawValue, "usCCEP")
        XCTAssertNil(Symbol("ccBTC"))
        for input in ["BTC/USD", "FOOUSDT", "ccFOOUSDT", "ccBTC//USDT"] {
            XCTAssertNil(SymbolInput.parse(input), input)
        }
        XCTAssertNil(Symbol(market: .crypto, code: "FOOUSDT"))
        XCTAssertEqual(try JSONDecoder().decode(Symbol.self, from: JSONEncoder().encode(bitcoin)), bitcoin)
        XCTAssertEqual(SymbolInput.parseList("BTC BTC/USDT ETHUSDT BTCUSDT")?.symbols.map(\.rawValue),
                       ["usBTC", "ccBTCUSDT", "ccETHUSDT"])
    }

    func testCatalogSearchCanCoexistWithStocksAndUsesCanonicalPairs() throws {
        XCTAssertEqual(CryptoCatalog.entries.count, 10)
        XCTAssertEqual(Set(CryptoCatalog.entries.map(\.id)).count, 10)
        XCTAssertTrue(CryptoCatalog.symbols.allSatisfy(\.isCrypto))
        for entry in CryptoCatalog.entries {
            XCTAssertEqual(entry.id, entry.symbol.rawValue)
            XCTAssertEqual(CryptoCatalog.symbol(for: entry.code), entry.symbol)
            XCTAssertEqual(CryptoCatalog.search(entry.symbol.displayCode).map(\.symbol), [entry.symbol])
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertFalse(entry.english.isEmpty)
        }
        XCTAssertEqual(CryptoCatalog.search("BTC").map(\.symbol.rawValue), ["ccBTCUSDT"])
        XCTAssertEqual(CryptoCatalog.search(" BTC / USDT ").map(\.symbol.rawValue), ["ccBTCUSDT"])
        XCTAssertEqual(CryptoCatalog.symbol(for: "cc BTC / USDT")?.rawValue, "ccBTCUSDT")
        XCTAssertEqual(CryptoCatalog.search("比特币").first?.symbol.rawValue, "ccBTCUSDT")
        XCTAssertEqual(CryptoCatalog.search("Ethereum").first?.symbol.rawValue, "ccETHUSDT")
        XCTAssertEqual(CryptoCatalog.search("dog").first?.symbol.rawValue, "ccDOGEUSDT")
        XCTAssertTrue(CryptoCatalog.search("b").isEmpty)
        XCTAssertTrue(CryptoCatalog.search("BTC", limit: 0).isEmpty)
        XCTAssertNil(CryptoCatalog.symbol(for: "BTC"))
        XCTAssertEqual(EnglishName.name(try XCTUnwrap(Symbol("ccBTCUSDT")), quote: nil), "Bitcoin")
        XCTAssertEqual(EnglishName.shortName(try XCTUnwrap(Symbol("ccBTCUSDT")), quote: nil), "BTC/USDT")
    }

    func testWeekendCrossDayAndStaleDataKeepPollingAroundTheClock() {
        let region = MarketRegion.crypto
        XCTAssertEqual(region.timeZone.secondsFromGMT(), 0)
        XCTAssertEqual(region.currency, "USDT")
        let dates = ["2026-11-06T23:59:59Z", "2026-11-07T00:00:00Z", "2026-11-08T23:59:59Z", "2026-11-09T00:00:00Z"]
        for value in dates {
            let now = utc(value)
            XCTAssertEqual(MarketClock.phase(for: region, at: now), .trading)
            for latest in [nil, now.addingTimeInterval(-7 * 86400), now.addingTimeInterval(3600)] {
                let phase = MarketClock.effectivePhase(for: region, at: now, latestQuoteTime: latest)
                XCTAssertEqual(phase, .trading)
                XCTAssertEqual(RefreshPolicy.interval(base: 5, phases: [phase], slowWhenIdle: true), 5)
            }
        }
    }

    func testContinuousUTCAxisAndRollingWindowSurviveMidnight() throws {
        let region = MarketRegion.crypto
        XCTAssertEqual(IntradayAxis.length(for: region), 1440)
        XCTAssertEqual(IntradayAxis.offset(of: 0, region: region), 0)
        XCTAssertEqual(IntradayAxis.offset(of: 1440, region: region), 1440)
        XCTAssertEqual(IntradayAxis.ticks(for: region).map(\.label), ["00:00", "12:00", "24:00"])
        let start = utc("2026-11-07T18:45:00Z")
        XCTAssertEqual(IntradayAxis.ticks(for: region, start: start).map(\.label), ["18:45", "06:45", "18:45"])
        XCTAssertEqual(IntradayAxis.timeLabel(of: 315, start: start, region: region), "00:00")
        XCTAssertEqual(IntradayAxis.timeLabel(of: 1440, start: start, region: region), "18:45")
        let series = IntradaySeries(symbol: try XCTUnwrap(Symbol("ccBTCUSDT")), date: "20261107",
                                   points: [IntradayPoint(minute: 0, price: 100), IntradayPoint(minute: 315, price: 101),
                                            IntradayPoint(minute: 1439, price: 102)], start: start)
        XCTAssertEqual(series.point(nearest: 316, region: region)?.minute, 315)
        XCTAssertEqual(series.point(nearest: 1438, region: region)?.minute, 1439)
    }

    func testQuoteOnlyCapabilitiesAndUntrustedHoldingsNeverEnterPortfolio() throws {
        let symbol = try XCTUnwrap(Symbol("ccBTCUSDT"))
        XCTAssertFalse(symbol.canHold)
        XCTAssertFalse(symbol.isIndex)
        XCTAssertFalse(symbol.isGlobal)
        XCTAssertTrue(symbol.hasIntraday)
        XCTAssertTrue(symbol.hasKline)
        XCTAssertFalse(symbol.hasFiveDay)
        XCTAssertTrue(try XCTUnwrap(Symbol("usAAPL")).hasFiveDay)
        var item = WatchItem(symbol: symbol)
        item.holding = Holding(shares: 1, cost: 100)
        let quote = Quote(symbol: symbol, name: "Bitcoin", price: 150, previousClose: 100)
        XCTAssertTrue(quote.hasTraded, "连续市场的有效价格不需要股票的开盘/成交量字段")
        XCTAssertFalse(Quote(symbol: symbol, name: "Bitcoin", price: 0, previousClose: 100).hasTraded)
        XCTAssertTrue(Portfolio.summaries(items: [item], quotes: [symbol: quote]).isEmpty)
        XCTAssertNil(Portfolio.position(try XCTUnwrap(item.holding), quote: quote))
        XCTAssertFalse(TencentFundFlow.supports(symbol))
        let rates = ExchangeRates(hkdCNY: 0.9, usdCNY: 7)
        XCTAssertTrue(rates.toCNY(.crypto).isNaN, "没有 USDT/CNY 汇率，不能把 USDT 当 USD")
        let summaries = [PortfolioSummary(region: .cn, marketValue: 1, costValue: 1, dayProfit: 0, count: 1),
                         PortfolioSummary(region: .crypto, marketValue: 1, costValue: 1, dayProfit: 0, count: 1)]
        XCTAssertNil(Portfolio.combined(summaries, rates: rates))
    }

    func testUnknownFuturePairAndItsFieldsSurviveEditsAndSyncRoundTrip() throws {
        let source = Data(#"{"watchlist":[{"symbol":"ccBTCUSDT","name":"Bitcoin"},{"symbol":"ccFUTUREUSDT","futureVenue":{"precision":12},"futureNetwork":"chain-v2"}],"settings":{}}"#.utf8)
        var content = try JSONDecoder().decode(SyncContent.self, from: source)
        XCTAssertEqual(content.watchlist.map(\.symbol.rawValue), ["ccBTCUSDT"])
        XCTAssertEqual(content.unknownWatchItems.count, 1)
        let unknown = content.unknownWatchItems
        content.watchlist[0].alias = "BTC"
        let roundTrip = try JSONDecoder().decode(SyncContent.self, from: JSONEncoder().encode(content))
        XCTAssertEqual(roundTrip.unknownWatchItems, unknown)
        XCTAssertEqual(roundTrip.watchlist[0].alias, "BTC")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(roundTrip)) as? [String: Any])
        let items = try XCTUnwrap(json["watchlist"] as? [[String: Any]])
        XCTAssertEqual(items[1]["futureNetwork"] as? String, "chain-v2")
        XCTAssertEqual((items[1]["futureVenue"] as? [String: Int])?["precision"], 12)
    }

    func testRollingTickerDoesNotOverwriteUTCDailyWeeklyOrMonthlyCandles() throws {
        let symbol = try XCTUnwrap(Symbol("ccBTCUSDT"))
        let candle = Candle(date: "2026-11-07", open: 100, close: 110, high: 115, low: 95, volume: 42)
        for period in [KlinePeriod.day, .week, .month] {
            let series = KlineSeries(symbol: symbol, period: period, candles: [candle])
            for time in ["2026-11-07T23:59:59Z", "2026-11-08T00:00:01Z", "2026-12-01T00:00:01Z"] {
                let rolling = Quote(symbol: symbol, name: "Bitcoin", price: 120, previousClose: 80,
                                    open: 80, high: 200, low: 50, volume: 9999, timestamp: utc(time))
                XCTAssertEqual(series.merging(rolling), series, "\(period) \(time)")
            }
        }
    }

    func testPricePrecisionDoesNotDisplayEightTrailingZerosForLargeCoins() {
        XCTAssertEqual(CryptoCatalog.priceDecimals(for: 65000), 2)
        XCTAssertEqual(CryptoCatalog.priceDecimals(for: 1.2345), 4)
        XCTAssertEqual(CryptoCatalog.priceDecimals(for: 0.125), 6)
        XCTAssertEqual(CryptoCatalog.priceDecimals(for: 0.00125), 8)
        XCTAssertEqual(CryptoCatalog.priceDecimals(for: 0.00000125), 8)
        XCTAssertEqual(CryptoCatalog.priceDecimals(for: .nan), 2)
        XCTAssertEqual(QuoteFormatter.price(65000, decimals: CryptoCatalog.priceDecimals(for: 65000)), "65000.00")
        XCTAssertNotEqual(QuoteFormatter.volume(100, market: .crypto), QuoteFormatter.volume(100, market: .us))
        XCTAssertTrue(QuoteFormatter.volume(0.00001, market: .crypto).contains("0.00001"))
    }

    func testEightDecimalPricesAndChangesDoNotCollapseToZeroOrNegativeZero() {
        XCTAssertEqual(QuoteFormatter.price(0.00000012, decimals: 8), "0.00000012")
        XCTAssertEqual(QuoteFormatter.change(-0.00000012, decimals: 8), "-0.00000012")
        XCTAssertEqual(QuoteFormatter.change(0.00000012, decimals: 8), "+0.00000012")
        XCTAssertEqual(QuoteFormatter.change(-0.000000004, decimals: 8), "0.00000000")
        XCTAssertEqual(QuoteFormatter.change(-0.000000004, decimals: 99), "0.00000000")
        XCTAssertEqual(QuoteFormatter.fixed(1.23456789, decimals: 7), "1.2345679")
        XCTAssertEqual(QuoteFormatter.fixed(1.23456789, decimals: 8), "1.23456789")
    }

    func testRollingSparklineTailFollowsQuotesOnlyUntilItsBoundedRefreshGrace() throws {
        let symbol = try XCTUnwrap(Symbol("ccBTCUSDT"))
        let start = utc("2026-11-07T12:00:00Z")
        let end = start.addingTimeInterval(86400)
        let sparkline = Sparkline(values: [100, 110, 120], date: "20261107", start: start)
        for seconds in [-1.0, 0, 120, 121] {
            let quote = Quote(symbol: symbol, name: "Bitcoin", price: 125, previousClose: 100,
                              timestamp: end.addingTimeInterval(seconds))
            let updated = sparkline.updating(with: quote, region: .crypto)
            XCTAssertEqual(updated.values, seconds <= 120 ? [100, 110, 125] : sparkline.values, "\(seconds)")
            XCTAssertEqual(updated.start, start, "实时尾点不能平移历史时间轴")
            XCTAssertEqual(updated.date, sparkline.date)
            let empty = Sparkline(values: [], start: start)
            XCTAssertEqual(empty.updating(with: quote, region: .crypto), empty)
        }
        let global = try XCTUnwrap(Symbol("hf_CL"))
        for seconds in [0.0, 120, 121] {
            let quote = Quote(symbol: global, name: "WTI", price: 125, previousClose: 100,
                              timestamp: end.addingTimeInterval(seconds))
            XCTAssertEqual(sparkline.updating(with: quote, region: .global), sparkline, "期货仍严格限于原24小时")
        }
    }
}
