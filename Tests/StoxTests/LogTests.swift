import XCTest
@testable import Stox

final class LogTests: XCTestCase {
    func testRotationKeepsOnePreviousFileAndRecentLinesSpanBothFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("stox.log")
        let old = file.appendingPathExtension("1")
        try Log.appendLine("early critical error\n", to: file, limit: 10)
        try Log.appendLine("new\n", to: file, limit: 10)
        XCTAssertEqual(try String(contentsOf: old), "early critical error\n")
        XCTAssertEqual(Log.recentLines(at: file), ["early critical error", "new"])
        try Log.appendLine("more than ten characters\n", to: file, limit: 10)
        try Log.appendLine("latest\n", to: file, limit: 10)
        XCTAssertEqual(try String(contentsOf: old), "new\nmore than ten characters\n")
        XCTAssertEqual(try String(contentsOf: file), "latest\n")
        XCTAssertEqual(Log.recentLines(limit: 2, at: file), ["more than ten characters", "latest"])
        XCTAssertEqual(Log.recentLines(limit: 0, at: file), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["stox.log", "stox.log.1"])
    }

    func testOneMegabyteBoundaryDoesNotDeleteCurrentLog() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("stox.log")
        try Log.appendLine(String(repeating: "a", count: 1 << 20), to: file)
        try Log.appendLine("b", to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("1").path))
        try Log.appendLine("c", to: file)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("1")).count, (1 << 20) + 1)
        XCTAssertEqual(try String(contentsOf: file), "c")
    }
}
