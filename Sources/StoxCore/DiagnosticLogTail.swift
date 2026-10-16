import Foundation

/// 只读取日志尾部；不轮转、不重写文件，也不读取任何配置或持仓。
public enum DiagnosticLogTail {
    public static func lines(at url: URL, limit: Int = 200, maxBytes: Int = 1 << 20) -> [String] {
        let budget = min(max(maxBytes, 0), Int.max - 1)
        guard budget > 0, limit > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let clipped = end > UInt64(budget)
        // 多读一个边界字节，区分完整行开头与被截断的第一条记录。
        let count = Int(min(end, UInt64(budget) + (clipped ? 1 : 0)))
        guard (try? handle.seek(toOffset: end - UInt64(count))) != nil else { return [] }
        var data = Data()
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: min(count - data.count, 64 * 1024)) else { return [] }
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        var start = 0
        if clipped {
            guard let newline = data.firstIndex(of: 10) else { return [] }
            start = newline + 1
        }
        guard let text = String(data: data[start...], encoding: .utf8) else { return [] }
        // 从后向前只收集所需行，避免为一个大文件先分配所有行的数组。
        var remaining = text[...]
        var result: [String] = []
        while !remaining.isEmpty, result.count < limit {
            if let boundary = remaining.lastIndex(where: { $0.isNewline }) {
                let line = remaining[remaining.index(after: boundary)...]
                if !line.isEmpty { result.append(String(line)) }
                remaining = remaining[..<boundary]
            } else {
                result.append(String(remaining))
                break
            }
        }
        return result.reversed()
    }
}
