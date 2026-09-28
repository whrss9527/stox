import Foundation
import os

/// 日志写到系统的统一日志（“控制台”App 里按 subsystem 过滤），同时追加到 ~/Library/Application Support/Stox/stox.log，
/// 方便排查同步和更新的问题。
enum Log {
    private static let logger = Logger(subsystem: "io.github.whrss9527.stox", category: "app")
    private static let queue = DispatchQueue(label: "io.github.whrss9527.stox.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Stox", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("stox.log") }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR", message)
    }

    /// 等排队中的日志写完。退出前调用，最后几行不会丢。
    static func flush() {
        queue.sync {}
    }

    private static func append(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int, size > 1 << 20 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
