import XCTest
@testable import StoxCore

final class TraditionalChineseTests: XCTestCase {
    func testNamesConvertOnlyForTraditionalDisplayAndKeepSourceAndCodes() throws {
        let symbol = Symbol("hk00700")!
        let item = WatchItem(symbol: symbol, name: "腾讯控股", alias: "腾讯", pinned: true)
        let quote = Quote(symbol: symbol, name: "腾讯控股", price: 300, previousClose: 299, englishName: "TENCENT")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(item)
        XCTAssertEqual(item.displayName(with: quote, english: false, traditional: true), "騰訊控股")
        XCTAssertEqual(item.tickerName(with: quote, english: false, traditional: true), "騰訊")
        XCTAssertEqual(item.displayName(with: nil, english: false, traditional: true), "騰訊控股")
        XCTAssertEqual(item.displayName(with: quote, english: true, traditional: true), "TENCENT")
        XCTAssertEqual(item.displayName(with: quote, english: false, traditional: false), "腾讯控股")
        XCTAssertEqual(item.name, "腾讯控股")
        XCTAssertEqual(quote.name, "腾讯控股")
        XCTAssertEqual(item.symbol.rawValue, "hk00700")
        XCTAssertEqual(try encoder.encode(item), encoded)
        XCTAssertEqual(try JSONDecoder().decode(WatchItem.self, from: encoded).name, "腾讯控股")
    }

    func testIndicesFundsAndSearchResultsUseTraditionalNames() {
        XCTAssertEqual(AppLanguage.securityName("恒生指数", traditional: true), "恆生指數")
        XCTAssertEqual(AppLanguage.securityName("招商中证白酒", traditional: true), "招商中證白酒")
        XCTAssertEqual(AppLanguage.securityName("BRK.B 00700", traditional: true), "BRK.B 00700")
        let symbol = Symbol("hkHSI")!
        let result = SearchResult(symbol: symbol, name: "恒生指数", typeCode: "ZS")
        XCTAssertEqual(result.displayName(quote: nil, english: false, traditional: true), "恆生指數")
        XCTAssertEqual(result.name, "恒生指数")
        XCTAssertEqual(WatchItem(symbol: symbol, name: result.name).automaticTickerName(with: nil, english: false, traditional: true), "恆生指數")
    }

    func testRealTraditionalTableLoadsAndFormatsPlaceholders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(path: root.appendingPathComponent("Resources/zh-Hant.lproj").path))
        XCTAssertEqual(bundle.localizedString(forKey: "设置…", value: nil, table: nil), "設定…")
        let header = bundle.localizedString(forKey: "名称\t代码\t币种\t持有\t成本价\t现价\t市值\t持仓盈亏\t盈亏比例\t今日盈亏\t分组", value: nil, table: nil)
        XCTAssertEqual(header.components(separatedBy: "\t")[1], "代號")
        let template = bundle.localizedString(forKey: "第 %@ 行", value: nil, table: nil)
        XCTAssertEqual(AppLanguage.format(template, ["3"]), "第 3 行")
    }
}
