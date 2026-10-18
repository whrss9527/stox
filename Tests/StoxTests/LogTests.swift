import XCTest
@testable import Stox

final class LogTests: XCTestCase {
    func testBoundedRecentLinesStillSpanPreviousAndCurrentFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("stox.log")
        let old = file.appendingPathExtension("1")
        let prefix = String(repeating: "旧记录🙂", count: 5000)
        let previous = prefix + "\nprevious error\n"
        let current = prefix + "\ncurrent error\n"
        try previous.write(to: old, atomically: true, encoding: .utf8)
        try current.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Log.recentLines(limit: 2, at: file, maxBytesPerFile: 64), ["previous error", "current error"])
        XCTAssertEqual(Log.recentLines(limit: 1, at: file, maxBytesPerFile: 64), ["current error"])
        XCTAssertEqual(try String(contentsOf: old), previous)
        XCTAssertEqual(try String(contentsOf: file), current)
    }

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
