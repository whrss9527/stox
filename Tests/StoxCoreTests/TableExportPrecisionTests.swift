import XCTest
@testable import StoxCore

final class TableExportPrecisionTests: XCTestCase {
    private let symbol = Symbol("usAAPL")!

    func testCopiedHoldingsRestoreTinyAndHighPrecisionValuesInAllLanguages() throws {
        let holdings = [
            Holding(shares: 0.00004, cost: 100.123456),
            Holding(shares: 1.2345678901234567, cost: .leastNonzeroMagnitude),
            Holding(shares: .leastNonzeroMagnitude, cost: .greatestFiniteMagnitude),
            Holding(shares: .greatestFiniteMagnitude, cost: 0),
            Holding(shares: 1, cost: -0.0),
        ]
        let quote = Quote(symbol: symbol, name: "Apple", price: 1, previousClose: 1)
        try inEachLanguage { language in
            for holding in holdings {
                let original = WatchItem(symbol: symbol, name: "Apple", holding: holding)
                let table = Portfolio.tableText(items: [original], quotes: [symbol: quote])
                let preview = TableImport.parse(table)
                XCTAssertTrue(preview.canImport, "\(language): \(preview.problems)")
                let restored = try preview.applying(to: [], mode: .merge)
                let result = try XCTUnwrap(restored.first?.holding)
                XCTAssertEqual(result.shares.bitPattern, holding.shares.bitPattern, language)
                XCTAssertEqual(result.cost.bitPattern, holding.cost.bitPattern, language)
                XCTAssertEqual(try preview.applying(to: restored, mode: .merge), restored)
                XCTAssertEqual(try preview.applying(to: restored, mode: .replace), restored)
            }
        }
    }

    func testCopiedTradesRestoreOptionalAndSignedValuesWithoutDuplicateImports() throws {
        let trades = [
            Trade(side: .sell, shares: 0.00004, price: 100.123456, day: "2026-09-01",
                  profit: -1.2345678901234567, fee: 0.0049),
            Trade(side: .buy, shares: .leastNonzeroMagnitude, price: 1, day: "2026-09-01"),
            Trade(side: .sell, shares: .greatestFiniteMagnitude, price: 0, day: "2026-09-01",
                  profit: -0.0, fee: -0.0),
            Trade(side: .sell, shares: .leastNormalMagnitude, price: .greatestFiniteMagnitude,
                  day: "2026-09-01", profit: -.leastNonzeroMagnitude, fee: .leastNonzeroMagnitude),
            Trade(side: .sell, shares: 1, price: 0, day: "2026-09-01",
                  profit: -.greatestFiniteMagnitude, fee: .greatestFiniteMagnitude),
            Trade(side: .sell, shares: 1, price: 1, day: "2026-09-01", fee: 0),
        ]
        try inEachLanguage { language in
            for trade in trades {
                try assertTradeRoundTrip(trade, language: language)
            }
        }
    }

    func testCopiedDividendsPreserveZeroAndScientificBonusValues() throws {
        let bonuses: [Double?] = [nil, 0, -0.0, .leastNonzeroMagnitude,
                                  1.2345678901234567, .greatestFiniteMagnitude]
        try inEachLanguage { language in
            for bonus in bonuses {
                let trade = Trade(side: .dividend, shares: 1, price: 0.0049, day: "2026-09-01",
                                  profit: -0.0049123456789, bonus: bonus, fee: 0.0098123456789)
                try assertTradeRoundTrip(trade, language: language)
            }
        }
    }

    func testScientificNotationDoesNotRelaxImportValidation() {
        let holdingsHeader = "Symbol\tShares\tCost"
        XCTAssertTrue(TableImport.parse(holdingsHeader + "\nAAPL\t4E-05\t+1.234e+2").canImport)
        for shares in ["nan", "inf", "-inf", "1e309", "0", "-0.0", "-1e-5"] {
            XCTAssertFalse(TableImport.parse(holdingsHeader + "\nAAPL\t\(shares)\t1").canImport)
        }
        XCTAssertFalse(TableImport.parse(holdingsHeader + "\nAAPL\t1e308\t1e308").canImport)

        let tradeHeader = "Date\tSymbol\tType\tShares\tPrice\tFees\tRealized P&L\tBonus per share"
        for invalid in ["nan", "inf", "-inf", "1e309"] {
            for column in 4...7 {
                var row = ["2026-09-01", "AAPL", "dividend", "1", "0", "0", "0", "0"]
                row[column] = invalid
                XCTAssertFalse(TableImport.parse(tradeHeader + "\n" + row.joined(separator: "\t")).canImport)
            }
        }
        XCTAssertFalse(TableImport.parse(tradeHeader + "\n2026-09-01\tAAPL\tsell\t1e308\t1e308\t0\t0\t").canImport)
    }

    private func assertTradeRoundTrip(_ trade: Trade, language: String) throws {
        let original = WatchItem(symbol: symbol, name: "Apple", trades: [trade])
        let preview = TableImport.parse(Portfolio.tradesText(items: [original]))
        XCTAssertTrue(preview.canImport, "\(language): \(preview.problems)")
        let restored = try preview.applying(to: [], mode: .merge)
        let result = try XCTUnwrap(restored.first?.trades.first)
        XCTAssertEqual(result.side, trade.side, language)
        XCTAssertEqual(result.day, trade.day, language)
        XCTAssertEqual(result.shares.bitPattern, trade.shares.bitPattern, language)
        XCTAssertEqual(result.price.bitPattern, trade.price.bitPattern, language)
        XCTAssertEqual(result.fee?.bitPattern, trade.fee?.bitPattern, language)
        XCTAssertEqual(result.profit?.bitPattern, trade.profit?.bitPattern, language)
        XCTAssertEqual(result.bonus?.bitPattern, trade.bonus?.bitPattern, language)
        XCTAssertEqual(try preview.applying(to: [original], mode: .merge), [original], language)
        XCTAssertEqual(try preview.applying(to: restored, mode: .merge), restored, language)
        XCTAssertEqual(try preview.applying(to: restored, mode: .replace), restored, language)
    }

    private func inEachLanguage(_ body: (String) throws -> Void) throws {
        let original = AppLanguage.bundle
        defer { AppLanguage.bundle = original }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for (language, symbolHeader) in [("zh-Hans", "代码"), ("en", "Symbol"), ("zh-Hant", "代號")] {
            AppLanguage.bundle = try XCTUnwrap(Bundle(path: root.appendingPathComponent("Resources/\(language).lproj").path))
            let header = L("日期\t名称\t代码\t币种\t类型\t股数\t价格\t金额\t费用\t已实现盈亏")
            XCTAssertEqual(header.components(separatedBy: "\t")[2], symbolHeader)
            try body(language)
        }
    }
}
