import AppKit
import XCTest
import StoxCore
@testable import Stox

@MainActor
final class StoxLinkHandlerTests: XCTestCase {
    private let symbol = Symbol("sh600519")!

    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("stox-link-test-" + UUID().uuidString))
        board.clearContents()
        board.setString("原内容", forType: .string)
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    func testCopiesFreshQuoteWithExchangePrecision() async {
        let board = board()
        let handler = StoxLinkHandler(pasteboard: board, show: {}, add: { _ in }, fetch: { symbol in
            Quote(symbol: symbol, name: "贵州茅台", price: 1234.5, previousClose: 1230, priceDecimals: 2)
        })
        await handler.handle(.quote(symbol))?.value
        XCTAssertEqual(board.string(forType: .string), "贵州茅台 sh600519 1234.50")
    }

    func testNewCommandAndCancelRejectDelayedQuote() async {
        for cancel in [false, true] {
            let board = board(), gate = HeldLinkQuote()
            var shown = 0
            let handler = StoxLinkHandler(pasteboard: board, show: { shown += 1 }, add: { _ in }, fetch: gate.fetch)
            let old = handler.handle(.quote(symbol))
            await gate.started()
            if cancel { handler.cancel() } else { handler.handle(.show) }
            gate.finish(Quote(symbol: symbol, name: "旧结果", price: 1, previousClose: 1))
            await old?.value
            XCTAssertEqual(board.string(forType: .string), "原内容")
            XCTAssertEqual(shown, cancel ? 0 : 1)
        }
    }

    func testUserClipboardChangeRejectsDelayedQuote() async {
        let board = board(), gate = HeldLinkQuote()
        let handler = StoxLinkHandler(pasteboard: board, show: {}, add: { _ in }, fetch: gate.fetch)
        let task = handler.handle(.quote(symbol))
        await gate.started()
        board.clearContents(); board.setString("用户新复制", forType: .string)
        gate.finish(Quote(symbol: symbol, name: "迟到", price: 1, previousClose: 1))
        await task?.value
        XCTAssertEqual(board.string(forType: .string), "用户新复制")
    }

    func testMissingWrongAndInvalidPricesLeaveClipboardUnchanged() async {
        for quote in [nil, Quote(symbol: Symbol("usAAPL")!, name: "错误证券", price: 1, previousClose: 1),
                      Quote(symbol: symbol, name: "非数字", price: .nan, previousClose: 1)] {
            let board = board()
            let handler = StoxLinkHandler(pasteboard: board, show: {}, add: { _ in }, fetch: { _ in quote })
            await handler.handle(.quote(symbol))?.value
            XCTAssertEqual(board.string(forType: .string), "原内容")
        }
    }

    func testColdStartInboxPreservesOrderAndStopsAfterShutdown() throws {
        let inbox = StoxLinkInbox()
        var received: [StoxLink] = []
        inbox.receive([try XCTUnwrap(URL(string: "stox://show")), try XCTUnwrap(URL(string: "stox://add?code=600519"))])
        XCTAssertTrue(received.isEmpty)
        inbox.start { received.append($0) }
        inbox.receive([try XCTUnwrap(URL(string: "stox://quote?code=600519"))])
        XCTAssertEqual(received, [.show, .add(symbol), .quote(symbol)])
        inbox.stop()
        inbox.receive([try XCTUnwrap(URL(string: "stox://show"))])
        inbox.start { _ in XCTFail("退出后不能恢复执行") }
        XCTAssertEqual(received.count, 3)
    }
}

@MainActor
private final class HeldLinkQuote {
    private var result: CheckedContinuation<Quote?, Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func fetch(_ symbol: Symbol) async -> Quote? {
        await withCheckedContinuation { continuation in
            result = continuation
            ready?.resume(); ready = nil
        }
    }
    func started() async {
        if result != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func finish(_ quote: Quote) { result?.resume(returning: quote); result = nil }
}
