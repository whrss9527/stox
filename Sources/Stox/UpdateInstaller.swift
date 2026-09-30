import CryptoKit
import Foundation
import Security
import StoxCore

extension Checksums {
    /// 分块读文件算 SHA-256，返回小写十六进制。
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 系统的 App Translocation：带隔离标记、又没在访达里挪过位置的程序（比如在下载文件夹里直接打开的）
/// 会从一个只读的临时位置运行。用 Security 框架的函数判断，并找回它原来的位置。
enum Translocation {
    private typealias IsTranslocatedURL = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
    private typealias CreateOriginalPathForURL = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    static func isTranslocated(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") {
            return true
        }
        guard let pointer = symbol("SecTranslocateIsTranslocatedURL") else { return false }
        let function = unsafeBitCast(pointer, to: IsTranslocatedURL.self)
        var translocated = false
        _ = function(url as CFURL, &translocated, nil)
        return translocated
    }

    /// 被搬走之前的位置，例如 ~/Downloads/Stox.app。
    static func originalURL(of url: URL) -> URL? {
        guard let pointer = symbol("SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(pointer, to: CreateOriginalPathForURL.self)
        guard let original = function(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (original as URL).standardizedFileURL
    }
}

/// 这台 Mac 上更新装到哪里：平时原地替换，从临时位置运行时装进“应用程序”。
enum AppLocation {
    /// 测试用：当作从临时位置运行，原来的位置就是现在这个。
    static let testTranslocatedVariable = "STOX_TEST_TRANSLOCATED"

    static var applicationsFolders: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    static func currentPlan(bundle: URL = Bundle.main.bundleURL) -> InstallPlan? {
        let testing = ProcessInfo.processInfo.environment[testTranslocatedVariable] == "1"
        let translocated = testing || Translocation.isTranslocated(bundle)
        let original = testing ? bundle.standardizedFileURL : (translocated ? Translocation.originalURL(of: bundle) : nil)
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return InstallLocation.plan(
            bundle: bundle, translocated: translocated, original: original, readOnly: readOnly,
            folders: applicationsFolders, canWrite: canWrite
        )
    }

    /// 不用管理员密码能不能写：文件夹存在时看它本身，不存在时看能不能建出来。
    static func canWrite(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue && fm.isWritableFile(atPath: folder.path)
        }
        return fm.isWritableFile(atPath: folder.deletingLastPathComponent().path)
    }

    /// 界面上怎么称呼这个文件夹。
    static func displayName(of folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        if path == "/Applications" { return L("“应用程序”") }
        if path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path {
            return L("个人的“应用程序”（~/Applications）")
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

/// 程序的代码签名。用开发者证书签名的版本只接受同一个开发者（Team ID）签名的更新；
/// ad-hoc 签名的版本没有 Team ID，不做这项检查。
enum CodeSignature {
    /// 正在运行的这个程序的 Team ID。
    static let currentTeam: String? = teamIdentifier(of: Bundle.main.bundleURL)

    static func teamIdentifier(of url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
    }

    /// url 处的程序签名完整，并且是 teamIdentifier 这个开发者签的。
    static func isSigned(_ url: URL, byTeam teamIdentifier: String) -> Bool {
        guard let code = staticCode(url) else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
}

/// 下载、校验、解压、替换、重新启动。除了 relaunch 都是异步的，不阻塞界面。
enum UpdateInstaller {
    static let dittoPath = "/usr/bin/ditto"
    static let xattrPath = "/usr/bin/xattr"
    static let codesignPath = "/usr/bin/codesign"
    static let osascriptPath = "/usr/bin/osascript"

    /// 下载到 destination，progress 收到 0…1 的进度（总大小未知时是 nil）。
    static func download(_ url: URL, expectedSize: Int?, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, expectedSize: expectedSize, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        // 30 秒没有任何数据才算超时，整个下载最长一小时。
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Stox/\(AppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.completion = { result in continuation.resume(with: result) }
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// 比对压缩包的 SHA-256：优先用 GitHub 给附件算的摘要，没有时下载发布附带的 SHA256SUMS.txt。
    static func verify(archive: URL, release: ReleaseInfo) async throws {
        let expected: String
        if let digest = release.archiveSHA256 {
            expected = digest
        } else if let checksumsURL = release.checksumsURL {
            let sums = try await UpdateCheck.checksums(at: checksumsURL, currentVersion: AppInfo.version)
            guard let hash = sums[archive.lastPathComponent] else { throw UpdateError.checksumsMissing }
            expected = hash
        } else {
            throw UpdateError.noArchive
        }
        let actual = try await Task.detached(priority: .userInitiated) {
            try Checksums.sha256(of: archive)
        }.value
        guard actual == expected else { throw UpdateError.checksumMismatch }
        Log.info("更新包校验通过（SHA-256 \(actual.prefix(12))…）")
    }

    /// 解压到 directory，返回里面的 .app。
    static func extract(archive: URL, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await Shell.run(dittoPath, ["-x", "-k", archive.path, directory.path], timeout: 120)
        guard result.succeeded else { throw UpdateError.extract(result.trimmedOutput) }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.appNotFound }
        // 自己下载并校验过的更新，去掉隔离标记，否则换上去之后系统会再拦一次，还会被搬到临时位置运行。
        _ = try? await Shell.run(xattrPath, ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// 确认解压出来的确实是对应版本的 Stox，签名完整；当前版本是开发者签名的时候，新版本也必须是同一个开发者签的。
    static func validate(app: URL, expectedVersion: String, requiredTeam: String? = CodeSignature.currentTeam) async throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.wrongApp(L("读不到 Info.plist")) }
        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        if let ours = Bundle.main.bundleIdentifier, identifier != ours {
            throw UpdateError.wrongApp(L("bundle identifier 是 %@", identifier))
        }
        let version = plist["CFBundleShortVersionString"] as? String ?? ""
        guard version == expectedVersion else {
            throw UpdateError.wrongApp(L("版本是 %@，不是 %@", version, expectedVersion))
        }
        let result = try await Shell.run(codesignPath, ["--verify", "--deep", "--strict", app.path], timeout: 120)
        guard result.succeeded else { throw UpdateError.wrongApp(L("签名校验失败：%@", result.trimmedOutput)) }
        if let requiredTeam, !CodeSignature.isSigned(app, byTeam: requiredTeam) {
            let found = CodeSignature.teamIdentifier(of: app) ?? L("没有开发者签名")
            Log.error("新版本的签名不是 \(requiredTeam)（是 \(found)），不安装")
            throw UpdateError.wrongSigner(requiredTeam)
        }
    }

    /// 把 newApp 放到 target：先挪到同一个文件夹里的隐藏名字，旧的挪开，再改名，失败就换回去。
    /// target 所在文件夹没有写权限时（标准账户装在“应用程序”里），用系统的授权对话框以管理员身份做同样的事。
    static func install(newApp: URL, replacing target: URL) async throws {
        let parent = target.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".\(target.lastPathComponent).update")
        let backup = parent.appendingPathComponent(".\(target.lastPathComponent).previous")
        do {
            try swap(newApp: newApp, target: target, staged: staged, backup: backup)
        } catch let error as NSError where isBlockedBySystem(error) {
            Log.error("替换程序被系统拒绝：\(error.localizedDescription)")
            throw UpdateError.appManagement
        } catch let error as NSError where needsAdmin(error) {
            Log.info("替换程序需要管理员权限，改用授权对话框（\(error.localizedDescription)）")
            let source = FileManager.default.fileExists(atPath: staged.path) ? staged : newApp
            try await swapPrivileged(source: source, target: target, staged: staged, backup: backup)
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
    }

    private static func swap(newApp: URL, target: URL, staged: URL, backup: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: newApp, to: staged)
        let hadTarget = fm.fileExists(atPath: target.path)
        if hadTarget {
            try fm.moveItem(at: target, to: backup)
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            if hadTarget {
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }
        if hadTarget {
            try? fm.removeItem(at: backup)
        }
    }

    private static func swapPrivileged(source: URL, target: URL, staged: URL, backup: URL) async throws {
        let q = Shell.shellQuote
        let (s, t, b) = (q(staged.path), q(target.path), q(backup.path))
        let script = "rm -rf \(s) \(b) && mkdir -p \(q(target.deletingLastPathComponent().path)) && mv \(q(source.path)) \(s)"
            + " && { [ ! -e \(t) ] || mv \(t) \(b); }"
            + " && { mv \(s) \(t) || { [ ! -e \(b) ] || mv \(b) \(t); exit 1; }; }"
            + " && rm -rf \(b)"
        let appleScript = "do shell script " + Shell.appleScriptString(script) + " with administrator privileges"
        let result = try await Shell.run(osascriptPath, ["-e", appleScript], timeout: 300)
        guard result.succeeded else {
            let text = result.trimmedOutput
            if text.contains("-128") {
                throw UpdateError.cancelledByUser
            }
            if text.localizedCaseInsensitiveContains("Operation not permitted") {
                throw UpdateError.appManagement
            }
            throw UpdateError.install(text)
        }
    }

    /// 错误里的 POSIX 错误码（FileManager 的错误通常包着一层）。
    static func posixCode(_ error: NSError) -> Int? {
        if error.domain == NSPOSIXErrorDomain {
            return error.code
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return posixCode(underlying)
        }
        return nil
    }

    /// 没有写权限（EACCES）：管理员身份可以做。
    static func needsAdmin(_ error: NSError) -> Bool {
        if let code = posixCode(error) {
            return code == Int(EACCES)
        }
        return error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code)
    }

    /// 系统保护（EPERM，比如“App 管理”权限）：管理员身份也做不了。
    static func isBlockedBySystem(_ error: NSError) -> Bool {
        posixCode(error) == Int(EPERM)
    }

    /// 等当前进程退出后再打开新程序：起一个独立的 sh 等着，自己退出时它不受影响。
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "n=0; while /bin/kill -0 \(pid) 2>/dev/null && [ $n -lt 300 ]; do /bin/sleep 0.2; n=$((n+1)); done; /usr/bin/open \(Shell.shellQuote(app.path))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error("启动重新打开程序的辅助进程失败：\(error.localizedDescription)")
        }
    }
}

/// 把 URLSession 的下载回调接到 async 调用上，顺便报告进度。回调都在 URLSession 的串行队列上。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let expectedSize: Int?
    let progress: @Sendable (Double?) -> Void
    var completion: ((Result<Void, Error>) -> Void)?

    init(destination: URL, expectedSize: Int?, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    private func finish(_ result: Result<Void, Error>) {
        completion?(result)
        completion = nil
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        var total = totalBytesExpectedToWrite
        if total <= 0, let expectedSize, expectedSize > 0 {
            total = Int64(expectedSize)
        }
        progress(total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateError.server(http.statusCode)))
            return
        }
        // location 在这个回调返回后就会被删掉，必须在这里挪走。
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // 成功时 didFinishDownloadingTo 已经先调用过 finish，这里什么也不做。
            finish(.failure(UpdateError.badResponse))
            return
        }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }
}
