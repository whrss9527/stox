import Foundation
import StoxCore
import SystemConfiguration

/// iCloud 云盘里的同步文件：~/Library/Mobile Documents/com~apple~CloudDocs/Stox/sync.json。
/// 用 iCloud 云盘里的普通文件夹而不是 App 自己的 iCloud 容器，是因为没有开发者签名就拿不到 iCloud 的 entitlement。
enum CloudFile {
    /// 测试用：把同步文件夹指到别处。
    static let overrideVariable = "STOX_SYNC_DIR"
    static let folderName = "Stox"
    static let fileName = "sync.json"

    /// iCloud 云盘的根目录；没开 iCloud 云盘时是 nil。
    static func driveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// 同步文件夹：iCloud 云盘/Stox。
    static var folderURL: URL? {
        if let override = ProcessInfo.processInfo.environment[overrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return driveURL()?.appendingPathComponent(folderName, isDirectory: true)
    }

    /// 这台 Mac 的名字（“系统设置 → 通用 → 关于本机”里的名称）。
    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    /// 读同步文件；不存在返回 nil。还没从 iCloud 下载下来的文件会先下载。
    static func read(at url: URL) throws -> SyncDocument? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordinationError: NSError?
        var result: Result<SyncDocument?, Error> = .success(nil)
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result {
                guard FileManager.default.fileExists(atPath: readURL.path) else { return nil }
                return try SyncDocument.decode(try Data(contentsOf: readURL))
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try result.get()
    }

    static func write(_ document: SyncDocument, to url: URL) throws {
        let data = try document.encoded()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
    }

    /// 两台 Mac 同时改过时 iCloud 会留下冲突版本：所有版本里改动时间最晚的胜出，写回去并清掉其他版本。
    /// 返回胜出的内容；没有冲突返回 nil。
    static func resolveConflicts(at url: URL) -> SyncDocument? {
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return nil }
        var candidates: [SyncDocument] = []
        if let current = try? read(at: url) {
            candidates.append(current)
        }
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url), let document = try? SyncDocument.decode(data) {
                candidates.append(document)
            }
        }
        let winner = SyncDocument.newest(candidates)
        for version in conflicts {
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        if let winner {
            try? write(winner, to: url)
        }
        Log.info("iCloud 同步：解决了 \(conflicts.count) 个冲突版本，采用来自 \(winner?.device ?? "?") 的改动")
        return winner
    }

    /// 文件的修改时间和大小，用来判断有没有变化。
    static func stamp(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? Int) ?? 0
        return "\(date):\(size)"
    }
}
