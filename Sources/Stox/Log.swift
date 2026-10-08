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

    /// 最近的日志可跨越一次轮转；读取前先写完队列，不取配置或持仓文件。
    static func recentLines(limit: Int = 200, at url: URL = fileURL) -> [String] {
        queue.sync {
            let previous = url.appendingPathExtension("1")
            let lines = [previous, url].flatMap { file -> [String] in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
                return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }
            return Array(lines.suffix(max(0, limit)))
        }
    }

    /// 只保留当前和上一份日志；挪动失败时保留当前文件，不清空它。
    static func appendLine(_ line: String, to url: URL, limit: Int = 1 << 20) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attributes = try? fm.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > limit {
            let previous = url.appendingPathExtension("1")
            if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
            try fm.moveItem(at: url, to: previous)
        }
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func append(_ level: String, _ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
            try? appendLine(line, to: fileURL)
        }
    }
}
