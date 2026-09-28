import XCTest
@testable import StoxCore

final class SinaTests: XCTestCase {
    // 2026-09-28 从新浪接口抓取的真实返回（节选）。
    static let sample = #"""
    var hq_str_sh600519="贵州茅台,1236.000,1237.000,1243.880,1244.010,1228.100,1243.770,1243.880,2821830,3488720613.000,100,1243.770,100,1243.750,100,1243.570,200,1243.500,100,1243.470,319,1243.880,2000,1243.900,1000,1243.910,900,1243.920,100,1243.930,2026-09-28,15:34:59,00,D|1900|2363372.00";
    var hq_str_sh000001="上证指数,3878.4088,3888.3738,3823.6206,3878.4088,3806.6708,0,0,452350675,804543704708,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2026-09-28,16:19:58,00,";
    var hq_str_sh510300="沪深300ETF华泰柏瑞,4.499,4.515,4.417,4.503,4.397,4.417,4.418,986408900,4373095288.000,1329100,4.417,1976800,4.416,5080000,4.415,1313600,4.414,1288700,4.413,246600,4.418,167300,4.419,1094700,4.420,401000,4.421,414600,4.422,2026-09-28,15:34:59,00,D|372200|1644007.40";
    var hq_str_hk00700="TENCENT,腾讯控股,441.400,436.600,447.000,438.600,439.800,3.200,0.733,439.79999,440.00000,6774063362,15335550,0.000,0.000,675.134,411.000,2026/09/28,16:08";
    var hq_str_hkHSI="HSI,恒生指数,24554.580,24510.090,24767.220,24554.580,24642.510,132.420,0.540,0.00000,0.00000,177482238,10228271685,0.000,0.000,28056.100,22518.000,2026/09/28,16:09";
    var hq_str_gb_aapl="苹果,340.1500,-0.27,2026-09-29 01:08:08,-0.9200,340.3700,342.9880,339.3200,345.3400,242.8900,14511201,39239159,4964210936888,8.30,40.980000,0.00,0.78,0.00,0.00,14594181793,63,0.0000,0.00,0.00,,Sep 28 01:08PM EDT,341.0700,0,1,2026,4950995982.0000,0.0000,0.0000,0.0000,0.0000,341.0700";
    var hq_str_gb_brk$b="伯克希尔B,504.5950,-0.18,2026-09-29 01:08:07,-0.8850,505.0000,507.2400,503.4300,537.7400,464.0100,1396082,5210974,1080337895000,33.59,15.020000,0.00,0.15,0.00,0.00,2141000000,69,0.0000,0.00,0.00,,Sep 28 01:07PM EDT,505.4800,0,1,2026,705045059.0000,0.0000,0.0000,0.0000,0.0000,505.4300";
    var hq_str_gb_ixic="纳斯达克,26862.3250,-0.76,2026-09-29 01:08:08,-206.3915,26935.7616,26990.0163,26709.6879,27288.7910,20690.2500,3476639378,7640582475,0,0.00,--,0.00,0.00,0.00,0.00,0,0,0.0000,0.00,0.00,,Sep 28 01:08PM EDT,27068.7165,0,1,2026,0.0000,0.0000,0.0000,0.0000,0.0000,0.0000";
    var hq_str_sh999999="";
    """#

    private let symbols = ["sh600519", "sh000001", "sh510300", "hk00700", "hkHSI", "usAAPL", "usBRK.B", "us.IXIC", "sh999999"]
        .compactMap(Symbol.init)

    func testCodes() {
        XCTAssertEqual(symbols.map(SinaProvider.code(for:)),
                       ["sh600519", "sh000001", "sh510300", "hk00700", "hkHSI", "gb_aapl", "gb_brk$b", "gb_ixic", "sh999999"])
        XCTAssertEqual(SinaProvider.quoteURL(for: Array(symbols.prefix(2)) + [Symbol("usBRK.B")!])?.absoluteString,
                       "https://hq.sinajs.cn/list=sh600519,sh000001,gb_brk$b")
    }

    func testParsesAllMarkets() throws {
        let quotes = SinaQuoteParser.parse(Self.sample, symbols: symbols)
        XCTAssertEqual(quotes.count, 8, "查不到的代码跳过")

        let moutai = try XCTUnwrap(quotes[Symbol("sh600519")!])
        XCTAssertEqual(moutai.name, "贵州茅台")
        XCTAssertEqual(moutai.price, 1243.88)
        XCTAssertEqual(moutai.previousClose, 1237)
        XCTAssertEqual(moutai.open, 1236)
        XCTAssertEqual(moutai.high, 1244.01)
        XCTAssertEqual(moutai.low, 1228.1)
        XCTAssertEqual(moutai.change, 6.88, accuracy: 1e-9)
        XCTAssertEqual(moutai.volume, 2_821_830)
        XCTAssertEqual(moutai.amount, 3_488_720_613)
        XCTAssertEqual(moutai.priceDecimals, 2, "新浪给三位小数，股票按两位显示")
        XCTAssertEqual(moutai.timestamp.map { QuoteFormatter.time($0, timeZone: MarketRegion.cn.timeZone) }, "15:34:59")

        let index = try XCTUnwrap(quotes[Symbol("sh000001")!])
        XCTAssertEqual(index.volume, 45_235_067_500, "上证指数的成交量是手")
        XCTAssertEqual(index.priceDecimals, 2)
        XCTAssertEqual(quotes[Symbol("sh510300")!]?.priceDecimals, 3, "ETF 三位小数")

        let tencent = try XCTUnwrap(quotes[Symbol("hk00700")!])
        XCTAssertEqual(tencent.name, "腾讯控股")
        XCTAssertEqual(tencent.price, 439.8)
        XCTAssertEqual(tencent.previousClose, 436.6)
        XCTAssertEqual(tencent.volume, 15_335_550)
        XCTAssertEqual(tencent.amount, 6_774_063_362)
        XCTAssertEqual(tencent.high52Week, 675.134)
        XCTAssertEqual(tencent.priceDecimals, 3)
        let hsi = try XCTUnwrap(quotes[Symbol("hkHSI")!])
        XCTAssertEqual(hsi.volume, 0)
        XCTAssertEqual(hsi.amount, 177_482_238_000, "恒指的成交额是千港元")

        let apple = try XCTUnwrap(quotes[Symbol("usAAPL")!])
        XCTAssertEqual(apple.price, 340.15)
        XCTAssertEqual(apple.previousClose, 341.07)
        XCTAssertEqual(apple.changePercent, (340.15 - 341.07) / 341.07 * 100, accuracy: 1e-9)
        XCTAssertEqual(apple.marketCap, 4_964_210_936_888)
        XCTAssertEqual(apple.peRatio, 40.98)
        XCTAssertEqual(apple.priceDecimals, 2)
        XCTAssertEqual(apple.timestamp.map { QuoteFormatter.time($0, timeZone: MarketRegion.us.timeZone) }, "13:08:08",
                       "北京时间换成美东时间")
        XCTAssertEqual(quotes[Symbol("usBRK.B")!]?.name, "伯克希尔B")
        let nasdaq = try XCTUnwrap(quotes[Symbol("us.IXIC")!])
        XCTAssertNil(nasdaq.marketCap)
        XCTAssertNil(nasdaq.peRatio)
        XCTAssertEqual(nasdaq.amount, 0)
    }

    func testPreOpenPriceFallsBackToPreviousClose() throws {
        let text = #"var hq_str_sz000001="平安银行,0.000,11.300,0.000,0.000,0.000,0.000,0.000,0,0.000,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2026-09-29,09:05:00,00";"#
        let quote = try XCTUnwrap(SinaQuoteParser.parse(text, symbols: [Symbol("sz000001")!])[Symbol("sz000001")!])
        XCTAssertEqual(quote.price, 11.3)
        XCTAssertEqual(quote.change, 0)
        XCTAssertFalse(quote.hasTraded)
    }

    func testGarbage() {
        XCTAssertTrue(SinaQuoteParser.parse("Forbidden", symbols: symbols).isEmpty)
        XCTAssertTrue(SinaQuoteParser.parse(#"var hq_str_sh600519="贵州茅台,1";"#, symbols: symbols).isEmpty)
        XCTAssertTrue(SinaQuoteParser.parse(#"var hq_str_gb_aapl="苹果,abc";"#, symbols: symbols).isEmpty)
    }
}

final class FailoverTests: XCTestCase {
    private struct Fake: QuoteProvider {
        var quotes: [Symbol: Quote] = [:]
        var error: ProviderError?

        func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
            if let error { throw error }
            return quotes
        }

        func search(_ query: String) async throws -> [SearchResult] { [] }
    }

    private let symbol = Symbol("sh600519")!
    private var one: [Symbol: Quote] { [symbol: Quote(symbol: symbol, name: "贵州茅台", price: 1, previousClose: 1)] }
    private var other: [Symbol: Quote] { [symbol: Quote(symbol: symbol, name: "贵州茅台", price: 2, previousClose: 1)] }

    func testUsesPrimaryWhenItWorks() async throws {
        let result = try await QuoteFailover.fetchQuotes([symbol], primary: Fake(quotes: one), backup: Fake(quotes: other))
        XCTAssertEqual(result.source, .primary)
        XCTAssertEqual(result.quotes[symbol]?.price, 1)
    }

    func testFallsBackWhenPrimaryFailsOrIsEmpty() async throws {
        let failed = try await QuoteFailover.fetchQuotes(
            [symbol], primary: Fake(error: ProviderError.badStatus(502)), backup: Fake(quotes: other)
        )
        XCTAssertEqual(failed.source, .backup)
        XCTAssertEqual(failed.quotes[symbol]?.price, 2)

        let empty = try await QuoteFailover.fetchQuotes([symbol], primary: Fake(), backup: Fake(quotes: other))
        XCTAssertEqual(empty.source, .backup)

        let skipped = try await QuoteFailover.fetchQuotes(
            [symbol], primary: Fake(quotes: one), backup: Fake(quotes: other), skipPrimary: true
        )
        XCTAssertEqual(skipped.source, .backup, "主数据源刚失败过时直接用备用的")
    }

    func testReportsThePrimaryError() async {
        do {
            _ = try await QuoteFailover.fetchQuotes(
                [symbol], primary: Fake(error: ProviderError.badStatus(502)), backup: Fake(error: ProviderError.badStatus(403))
            )
            XCTFail("两个都失败时应该抛出错误")
        } catch {
            XCTAssertEqual(error as? ProviderError, .badStatus(502))
        }
        do {
            _ = try await QuoteFailover.fetchQuotes([symbol], primary: Fake(error: ProviderError.badStatus(502)), backup: Fake())
            XCTFail("备用的也没有数据时应该抛出主数据源的错误")
        } catch {
            XCTAssertEqual(error as? ProviderError, .badStatus(502))
        }
    }

    func testEmptyEverywhereStaysOnPrimary() async throws {
        let result = try await QuoteFailover.fetchQuotes([symbol], primary: Fake(), backup: Fake())
        XCTAssertEqual(result.source, .primary)
        XCTAssertTrue(result.quotes.isEmpty)
        let noBackup = try await QuoteFailover.fetchQuotes([symbol], primary: Fake(quotes: one), backup: nil, skipPrimary: true)
        XCTAssertEqual(noBackup.source, .primary, "没有备用数据源时不能跳过主数据源")
    }
}
