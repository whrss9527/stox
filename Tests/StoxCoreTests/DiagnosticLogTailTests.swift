import Foundation
import XCTest
@testable import StoxCore

final class DiagnosticLogTailTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRecentNonemptyLinesPreserveNewlinesAndUnicode() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log.txt")
        try "first\r\n\r\n中文🙂\u{2028}last".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiagnosticLogTail.lines(at: url), ["first", "中文🙂", "last"])
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, limit: 2), ["中文🙂", "last"])
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, limit: 0), [])
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, maxBytes: 0), [])
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, maxBytes: -1), [])
        XCTAssertEqual(DiagnosticLogTail.lines(at: root.appendingPathComponent("missing")), [])
    }

    func testBoundaryByteKeepsCompleteLineAndOmitsClippedRecord() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log.txt")
        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, maxBytes: 2), ["b"])
        try "old\nlast".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, maxBytes: 4), ["last"])
        try "prefix-中文🙂\nlast\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, maxBytes: 9), ["last"])
        try String(repeating: "中🙂", count: 100).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, maxBytes: 16), [])
    }

    func testOversizedExistingFileIsNotRewrittenAndInvalidTailIsRejected() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("log.txt")
        let text = String(repeating: "超大的旧记录", count: 100_000) + "\n最新🙂\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, maxBytes: 64), ["最新🙂"])
        XCTAssertEqual(try Data(contentsOf: url).count, text.utf8.count)
        try Data([0xff, 10, 65, 10]).write(to: url)
        XCTAssertEqual(DiagnosticLogTail.lines(at: url), [])
        XCTAssertEqual(DiagnosticLogTail.lines(at: url, maxBytes: 2), ["A"])
    }
}
