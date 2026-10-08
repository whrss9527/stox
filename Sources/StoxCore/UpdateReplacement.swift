import Foundation

/// 同目录暂存、失败回滚，以及管理员路径复用的脚本；不执行授权对话框。
public enum UpdateReplacement {
    /// 原包仍在时优先选它：暂存目录可能只是上次失败留下的旧包。
    public static func source(newApp: URL, staged: URL, fileManager: FileManager = .default) -> URL {
        fileManager.fileExists(atPath: newApp.path) ? newApp : staged
    }

    public static func swap(newApp: URL, target: URL, staged: URL, backup: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: staged)
        let hadTarget = fileManager.fileExists(atPath: target.path)
        // 上一步回滚失败、旧包只剩备份时，不能先把唯一的旧包删掉。
        if hadTarget { try? fileManager.removeItem(at: backup) }
        try fileManager.moveItem(at: newApp, to: staged)
        if hadTarget { try fileManager.moveItem(at: target, to: backup) }
        do {
            try fileManager.moveItem(at: staged, to: target)
        } catch {
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }

    public static func privilegedScript(source: URL, target: URL, staged: URL, backup: URL) -> String {
        let (s, t, b) = (quote(staged.path), quote(target.path), quote(backup.path))
        var script = "mkdir -p \(quote(target.deletingLastPathComponent().path))"
        // /var 与 /private/var 等路径写法不同也可能指向同一份暂存包。
        if source.standardizedFileURL.resolvingSymlinksInPath() != staged.standardizedFileURL.resolvingSymlinksInPath() {
            script += " && rm -rf \(s) && mv \(quote(source.path)) \(s)"
        }
        script += " && { [ ! -e \(t) ] || { rm -rf \(b) && mv \(t) \(b); }; }"
            + " && { mv \(s) \(t) || { [ ! -e \(b) ] || mv \(b) \(t); exit 1; }; }"
            + " && rm -rf \(b)"
        return script
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
