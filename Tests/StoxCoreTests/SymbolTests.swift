import XCTest
@testable import StoxCore

final class SymbolTests: XCTestCase {
    func testRawValueRoundTrip() {
        for raw in ["sh600519", "sz000001", "bj920819", "hk00700", "hkHSI", "usAAPL", "us.IXIC", "usBRK.B"] {
            XCTAssertEqual(Symbol(raw)?.rawValue, raw)
        }
    }

    func testNormalization() {
        XCTAssertEqual(Symbol("hk700")?.rawValue, "hk00700")
        XCTAssertEqual(Symbol("usaapl")?.rawValue, "usAAPL")
        XCTAssertEqual(Symbol("HKhsi")?.rawValue, "hkHSI")
        XCTAssertNil(Symbol("sh60051"))
        XCTAssertNil(Symbol("sh6005199"))
        XCTAssertNil(Symbol("hk123456"))
        XCTAssertNil(Symbol("xx600519"))
        XCTAssertNil(Symbol("us123"))
    }

    func testIsIndex() {
        XCTAssertTrue(Symbol("sh000001")!.isIndex)
        XCTAssertTrue(Symbol("sz399006")!.isIndex)
        XCTAssertTrue(Symbol("bj899050")!.isIndex)
        XCTAssertTrue(Symbol("hkHSI")!.isIndex)
        XCTAssertTrue(Symbol("us.IXIC")!.isIndex)
        XCTAssertFalse(Symbol("sz000001")!.isIndex)
        XCTAssertFalse(Symbol("hk00700")!.isIndex)
        XCTAssertFalse(Symbol("usAAPL")!.isIndex)
    }

    func testDisplayCode() {
        XCTAssertEqual(Symbol("us.IXIC")!.displayCode, "IXIC")
        XCTAssertEqual(Symbol("hk00700")!.displayCode, "00700")
    }

    func testCodable() throws {
        let symbol = Symbol("usBRK.B")!
        let data = try JSONEncoder().encode([symbol])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["usBRK.B"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Symbol].self, from: data), [symbol])
    }

    func testExplicitCode() {
        for input in ["600519", "sh600519", "700", "0700.HK", "usAAPL", "us.IXIC", "hkHSI", "AAPL.US"] {
            XCTAssertTrue(SymbolInput.isExplicitCode(input), input)
        }
        for input in ["gzmt", "aapl", "AAPL", "茅台", "", "1234567", "hk"] {
            XCTAssertFalse(SymbolInput.isExplicitCode(input), input)
        }
    }

    func testUserInput() {
        let cases: [(String, String?)] = [
            ("sh600519", "sh600519"),
            ("SH600519", "sh600519"),
            ("600519", "sh600519"),
            ("600519.SS", "sh600519"),
            ("000001.SZ", "sz000001"),
            ("000001", "sz000001"),
            ("300750", "sz300750"),
            ("688981", "sh688981"),
            ("510300", "sh510300"),
            ("159915", "sz159915"),
            ("113050", "sh113050"),
            ("123100", "sz123100"),
            ("920819", "bj920819"),
            ("830799", "bj830799"),
            ("430047", "bj430047"),
            ("700", "hk00700"),
            ("00700", "hk00700"),
            ("0700.HK", "hk00700"),
            ("hkHSI", "hkHSI"),
            ("aapl", "usAAPL"),
            ("AAPL", "usAAPL"),
            ("brk.b", "usBRK.B"),
            ("us.IXIC", "us.IXIC"),
            ("usTSLA", "usTSLA"),
            ("USO", "usUSO"),
            ("SHOP", "usSHOP"),
            ("  6005 19 ", "sh600519"),
            ("", nil),
            ("1234567", nil),
            ("茅台", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SymbolInput.parse(input)?.rawValue, expected, "输入：\(input)")
        }
    }
}
