import XCTest
@testable import StoxCore

final class StoxLinkTests: XCTestCase {
    func testCommandsUseExistingSymbolFormats() throws {
        XCTAssertEqual(StoxLink(try XCTUnwrap(URL(string: "stox://show"))), .show)
        XCTAssertEqual(StoxLink(try XCTUnwrap(URL(string: "STOX://show/"))), .show)
        XCTAssertEqual(StoxLink(try XCTUnwrap(URL(string: "stox://add?code=600519"))), .add(try XCTUnwrap(Symbol("sh600519"))))
        XCTAssertEqual(StoxLink(try XCTUnwrap(URL(string: "stox://quote?code=usAAPL"))), .quote(try XCTUnwrap(Symbol("usAAPL"))))
        XCTAssertEqual(StoxLink(try XCTUnwrap(URL(string: "stox://quote?code=0700.HK"))), .quote(try XCTUnwrap(Symbol("hk00700"))))
    }

    func testMalformedOrUnknownCommandsAreRejected() throws {
        for text in ["https://show", "stox://unknown", "stox://show/path", "stox://show?code=AAPL",
                     "stox://user@show", "stox://show:80", "stox://show#fragment", "stox://quote",
                     "stox://quote?code", "stox://quote?code=", "stox://quote?code=%20",
                     "stox://quote?code=AAPL&code=MSFT", "stox://quote?code=AAPL&extra=1",
                     "stox://quote?Code=AAPL", "stox://quote?code=%0aAAPL", "stox://add?code=600519%3Bexit",
                     "stox://quote?code=" + String(repeating: "A", count: 65)] {
            XCTAssertNil(StoxLink(try XCTUnwrap(URL(string: text))), text)
        }
    }
}
