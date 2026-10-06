import Foundation
import StoxCore
import Security
import SystemConfiguration

/// 同步文件 sync.json 的读写。放在哪里由 StoxCore 的 SyncLocation 决定：
/// - App Store 版带着 iCloud 容器的 entitlement，放在 App 自己的容器 iCloud.io.github.whrss9527.stox 里（沙盒里只能用它）；
/// - GitHub 版没有开发者描述文件，拿不到 iCloud 的 entitlement，放在 iCloud 云盘/Stox/sync.json，和以前一样。
enum CloudFile {
    /// 测试用：把同步文件夹指到别处。
    static let overrideVariable = "STOX_SYNC_DIR"
    static let fileName = SyncLocation.fileName

    /// iCloud 云盘的根目录；没开 iCloud 云盘时是 nil。沙盒里的 App 看不到它（家目录是沙盒容器），也是 nil。
    static func driveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// 签名里有没有 App 自己的 iCloud 容器（App Store 版有）。没有时完全不碰 iCloud 容器的接口。
    static let hasContainerEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, SyncLocation.containerEntitlementKey as CFString, nil)
        return SyncLocation.hasContainer(entitlementValue: value)
    }()

    /// 向系统要 App 自己的 iCloud 容器的根目录；没有 entitlement、没登录 iCloud 或者关了 iCloud 云盘时是 nil。
    /// 第一次调用时系统要准备容器，可能要几秒，不能在主线程上调用。
    static func containerRoot() -> URL? {
        guard hasContainerEntitlement else { return nil }
        return FileManager.default.url(forUbiquityContainerIdentifier: SyncLocation.containerIdentifier)
    }

    /// 同步文件夹：测试用的覆盖 > App 的 iCloud 容器 > iCloud 云盘/Stox。
    /// 有容器的 entitlement 时只用容器：容器还没要到（或者没登录 iCloud）时算作不可用，
    /// 而不是先写到 iCloud 云盘文件夹里，免得两处各有一份。
    static func location(containerRoot: URL?) -> SyncLocation? {
        SyncLocation.resolve(
            override: ProcessInfo.processInfo.environment[overrideVariable],
            containerRoot: containerRoot,
            driveRoot: hasContainerEntitlement ? nil : driveURL()
        )
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

    /// 在同一个协调写操作里读、合并、写，避免拉取之后、写回之前到来的云端改动被覆盖。
    static func merge(_ document: SyncDocument, base: SyncContent?, at url: URL) throws -> SyncDocument {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<SyncDocument, Error> = .success(document)
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            result = Result {
                var merged = document
                if FileManager.default.fileExists(atPath: writeURL.path) {
                    let remote = try SyncDocument.decode(Data(contentsOf: writeURL))
                    merged = SyncMerge.threeWay(base: base, local: document, remote: remote)
                }
                try merged.encoded().write(to: writeURL, options: .atomic)
                return merged
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// 冲突版本按上次同步的基线逐项合并，成功写回后才清理冲突；读不懂的版本保留并报错。
    static func resolveConflicts(at url: URL, base: SyncContent?) throws -> SyncDocument? {
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return nil }
        var candidates: [SyncDocument] = []
        if let current = try read(at: url) { candidates.append(current) }
        for version in conflicts {
            candidates.append(try SyncDocument.decode(Data(contentsOf: version.url)))
        }
        guard let merged = SyncMerge.resolving(base: base, documents: candidates) else { return nil }
        try write(merged, to: url)
        for version in conflicts {
            version.isResolved = true
            try version.remove()
        }
        Log.info("iCloud 同步：合并了 \(conflicts.count) 个冲突版本")
        return merged
    }

    /// 文件的修改时间和大小，用来判断有没有变化。
    static func stamp(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? Int) ?? 0
        return "\(date):\(size)"
    }
}
