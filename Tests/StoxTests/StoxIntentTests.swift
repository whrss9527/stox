import XCTest
import StoxCore
@testable import Stox

@MainActor
final class StoxIntentTests: XCTestCase {
    func testPriceReturnsNumberAndUsesExistingSymbolNormalization() async throws {
        let price = try await StoxIntentSupport.price(code: "0700.HK") { symbol in
            XCTAssertEqual(symbol, Symbol("hk00700"))
            return Quote(symbol: symbol, name: "腾讯控股", price: 512.25, previousClose: 510)
        }
        XCTAssertEqual(price, 512.25)
    }

    func testInvalidInputNeverFetches() async {
        for code in ["", "AAPL;exit", "AAPL\n", String(repeating: "A", count: 65)] {
            do {
                _ = try await StoxIntentSupport.price(code: code) { _ in
                    XCTFail("无效证券不能联网")
                    return nil
                }
                XCTFail("必须报告输入错误")
            } catch {
                XCTAssertEqual(error as? StoxIntentError, .invalidSymbol)
            }
        }
    }

    func testMissingMismatchedAndNonfiniteQuoteNeverReturnAPrice() async {
        let symbol = Symbol("usAAPL")!
        for quote in [nil, Quote(symbol: Symbol("usMSFT")!, name: "微软", price: 1, previousClose: 1),
                      Quote(symbol: symbol, name: "苹果", price: .nan, previousClose: 1),
                      Quote(symbol: symbol, name: "苹果", price: .infinity, previousClose: 1)] {
            do {
                _ = try await StoxIntentSupport.price(code: symbol.rawValue) { _ in quote }
                XCTFail("不能返回无效价格")
            } catch {
                XCTAssertEqual(error as? StoxIntentError, .noQuote)
            }
        }
    }

    func testCancellationAfterProviderReturnsStillRejectsThePrice() async {
        let held = HeldIntentQuote()
        let task = Task {
            try await StoxIntentSupport.price(code: "AAPL", fetch: held.fetch)
        }
        await held.started()
        task.cancel()
        held.finish()
        do {
            _ = try await task.value
            XCTFail("取消后不能把价格交给后续操作")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

@MainActor
private final class HeldIntentQuote {
    private var pending: CheckedContinuation<Quote?, Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func fetch(_ symbol: Symbol) async -> Quote? {
        await withCheckedContinuation {
            pending = $0
            ready?.resume()
            ready = nil
        }
    }
    func started() async {
        if pending != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func finish() {
        pending?.resume(returning: Quote(symbol: Symbol("usAAPL")!, name: "苹果", price: 123, previousClose: 120))
        pending = nil
    }
}
