import XCTest
@testable import StoxCore

final class TableImportTests: XCTestCase {
    func testHeadersCanBeReorderedAndExtraExportColumnsAreIgnored() throws {
        let preview = TableImport.parse("\u{feff}分组\t成本价\t代码\t持有\t名称\t市值\r\n科技\t10\tsh600519\t100\t茅台\t1234\r\n")
        XCTAssertTrue(preview.canImport)
        let row = try XCTUnwrap(preview.rows.first)
        XCTAssertEqual(row.holding, Holding(shares: 100, cost: 10))
        XCTAssertEqual(row.group, "科技")
        XCTAssertEqual(row.symbol.rawValue, "sh600519")
    }

    func testEnglishAndTraditionalHeadersParseIncludingCurrencyCheck() {
        let preview = TableImport.parse("Name\tSymbol\tCurrency\tShares\tCost\nApple\tAAPL\tUSD\t3\t100")
        XCTAssertTrue(preview.canImport)
        let traditional = TableImport.parse("名稱\t代號\t幣種\t持有\t成本價\n騰訊\thk00700\tHKD\t100\t300")
        XCTAssertTrue(traditional.canImport)
        XCTAssertFalse(TableImport.parse("代码\t币种\t持有\t成本价\n00700\tCNY\t10\t1").canImport)
    }

    func testRoundTripsExportedHoldingsIncludingFundsAndZeroCost() throws {
        let symbols = [Symbol("sh600519")!, Symbol("sz000001")!, Symbol("jj161725")!, Symbol("usAAPL")!]
        let items = symbols.map { WatchItem(symbol: $0, name: $0.rawValue, holding: Holding(shares: 10, cost: 0), group: "科技") }
        let quotes = Dictionary(uniqueKeysWithValues: symbols.map { ($0, Quote(symbol: $0, name: $0.rawValue, price: 20, previousClose: 19)) })
        let preview = TableImport.parse(Portfolio.tableText(items: items, quotes: quotes))
        XCTAssertTrue(preview.canImport, "\(preview.problems)")
        XCTAssertEqual(try preview.applying(to: [], mode: .merge), items)
    }

    func testRoundTripsTradesWithFeesAndDecoratedBonusDividend() throws {
        let symbol = Symbol("sz000001")!
        let trades = [Trade(side: .buy, shares: 10, price: 10, day: "2026-09-01", fee: 1),
                      Trade(side: .dividend, shares: 10, price: 0.5, day: "2026-09-02", profit: 4, bonus: 0.4, fee: 1),
                      Trade(side: .sell, shares: 10, price: 20, day: "2026-09-03", profit: -2, fee: 2)]
        let original = WatchItem(symbol: symbol, name: "平安银行", trades: trades)
        let preview = TableImport.parse(Portfolio.tradesText(items: [original]))
        XCTAssertTrue(preview.canImport, "\(preview.problems)")
        XCTAssertEqual(try preview.applying(to: [], mode: .merge), [original])
        let english = TableImport.parse("Date\tSymbol\tType\tShares\tPrice\n2026-09-02\tsz000001\tDividend (bonus 0.4 per share)\t10\t0.5")
        XCTAssertTrue(english.canImport)
        XCTAssertEqual(english.rows.first?.trade?.bonus, 0.4)
    }

    func testErrorsIdentifyOriginalLineAndPreventPartialCommit() {
        let preview = TableImport.parse("\n代码\t持有\t成本价\nsh600519\t100\t10\nsh000001\t1\t1\nAAPL\tNaN\t1\nMSFT\t1\t-1\nTSLA\t1\t1\textra")
        XCTAssertEqual(preview.rows.count, 1)
        XCTAssertEqual(preview.problems.map(\.line), [4, 5, 6, 7])
        XCTAssertFalse(preview.canImport)
        XCTAssertThrowsError(try preview.applying(to: [], mode: .merge))
    }

    func testDuplicateHoldingsAndTradesAreDeduplicatedAndConflictsRejected() throws {
        let table = "代码\t持有\t成本价\nAAPL\t10\t0\nAAPL\t10\t0"
        let preview = TableImport.parse(table)
        XCTAssertTrue(preview.canImport)
        XCTAssertEqual(preview.duplicates, 1)
        XCTAssertEqual(preview.rows.count, 1)
        XCTAssertFalse(TableImport.parse(table + "\nAAPL\t20\t0").canImport)
        let trades = TableImport.parse("日期\t代码\t类型\t股数\t价格\n2026-09-01\tAAPL\t买入\t10\t100\n2026-09-01\tAAPL\t买入\t10\t100")
        let once = try trades.applying(to: [], mode: .merge)
        XCTAssertEqual(try trades.applying(to: once, mode: .merge), once)
        XCTAssertEqual(trades.duplicates, 1)
    }

    func testMergeAndReplacePreservePreferencesAndSeparateHoldingsFromLogs() throws {
        let symbol = Symbol("usAAPL")!, other = Symbol("usMSFT")!
        var old = WatchItem(symbol: symbol, name: "Old", alias: "Mine", pinned: true, alert: PriceAlert(priceAbove: 123),
                            holding: Holding(shares: 2, cost: 3), note: "keep", group: "keep",
                            trades: [Trade(side: .buy, shares: 2, price: 3, day: "2026-08-01")])
        old.unknownTrades = [PreservedJSONItem(index: 0, value: .object(["side": .string("future")]))]
        let items = [old, WatchItem(symbol: other, holding: Holding(shares: 5, cost: 50))]
        let table = TableImport.parse("代码\t持有\t成本价\nAAPL\t10\t10")
        let merge = try table.applying(to: items, mode: .merge)
        XCTAssertEqual(merge[0].alias, "Mine")
        XCTAssertEqual(merge[0].alert, old.alert)
        XCTAssertEqual(merge[0].group, "keep", "没提供分组列就保留")
        XCTAssertEqual(merge[0].unknownTrades, old.unknownTrades)
        XCTAssertEqual(merge[0].trades, old.trades)
        XCTAssertEqual(merge[1].holding, items[1].holding)
        let replace = try table.applying(to: items, mode: .replace)
        XCTAssertNil(replace[1].holding)
        XCTAssertEqual(replace[0].note, old.note)
        let logs = TableImport.parse("日期\t代码\t类型\t股数\t价格\n2026-09-01\tAAPL\t卖出\t1\t20")
        let result = try logs.applying(to: items, mode: .replace)
        XCTAssertEqual(result[0].holding, old.holding, "日志不重放交易")
        XCTAssertEqual(result[0].unknownTrades, old.unknownTrades)
        XCTAssertNil(result[0].trades[0].profit, "未提供历史利润时不拿当前成本猜")
        XCTAssertEqual(items[0], old, "预览不写原数组，取消时不需要回滚")
    }

    func testMalformedNumbersDatesHeadersAndBonusAreRejected() {
        for header in ["代码\t持有", "代码\t代码\t持有\t成本价"] { XCTAssertFalse(TableImport.parse(header + "\nAAPL\t1\t1\t1").canImport) }
        for day in ["2026-02-30", "2026-9-01", "invalid"] {
            XCTAssertFalse(TableImport.parse("代码\t日期\t类型\t股数\t价格\nAAPL\t\(day)\t买入\t1\t1").canImport)
        }
        for fee in ["-1", "NaN", "inf", "abc"] {
            XCTAssertFalse(TableImport.parse("代码\t日期\t类型\t股数\t价格\t费用\nAAPL\t2026-09-01\t买入\t1\t1\t\(fee)").canImport)
        }
        XCTAssertFalse(TableImport.parse("代码\t日期\t类型\t股数\t价格\t每股送转\nAAPL\t2026-09-01\t买入\t1\t1\t0.5").canImport)
    }

    func testTradeLimitNeverSilentlyDropsOldRecords() throws {
        let symbol = Symbol("usAAPL")!
        let old = WatchItem(symbol: symbol, trades: (0..<Trade.limit).map { Trade(side: .buy, shares: Double($0 + 1), price: 10, day: "2026-09-01") })
        let preview = TableImport.parse("代码\t日期\t类型\t股数\t价格\nAAPL\t2026-09-02\t买入\t1\t1")
        XCTAssertThrowsError(try preview.applying(to: [old], mode: .merge))
        XCTAssertEqual(try preview.applying(to: [old], mode: .replace)[0].trades.count, 1)
        let large = "代码\t持有\t成本价\n" + Array(repeating: "AAPL\t1\t1", count: 1002).joined(separator: "\n")
        XCTAssertFalse(TableImport.parse(large).canImport)
    }
}
