import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub 上的一个发布版本，以及一键更新需要的附件。
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var tag: String
    public var pageURL: URL
    public var notes: String
    public var publishedAt: Date?
    /// 一键更新下载的压缩包 Stox.zip。
    public var archiveURL: URL?
    public var archiveName: String?
    public var archiveSize: Int?
    /// GitHub 为附件计算的 SHA-256（`sha256:` 开头），没有时为 nil。
    public var archiveDigest: String?
    /// 发布时一起上传的校验文件 SHA256SUMS.txt。
    public var checksumsURL: URL?

    public init(
        version: String, tag: String, pageURL: URL, notes: String = "", publishedAt: Date? = nil,
        archiveURL: URL? = nil, archiveName: String? = nil, archiveSize: Int? = nil,
        archiveDigest: String? = nil, checksumsURL: URL? = nil
    ) {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
        self.notes = notes
        self.publishedAt = publishedAt
        self.archiveURL = archiveURL
        self.archiveName = archiveName
        self.archiveSize = archiveSize
        self.archiveDigest = archiveDigest
        self.checksumsURL = checksumsURL
    }

    /// 发布说明里“更新内容”那一节；旧版本的发布说明没有这一节时，去掉安装步骤和自动生成的改动列表后剩下的部分。
    public var highlights: String {
        ReleaseNotesText.highlights(notes)
    }

    /// 附件摘要里的十六进制 SHA-256。
    public var archiveSHA256: String? {
        guard let digest = archiveDigest?.lowercased(), digest.hasPrefix("sha256:") else { return nil }
        let hex = String(digest.dropFirst("sha256:".count))
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// 有压缩包、并且能校验它时才能在程序里直接安装。
    public var canInstall: Bool {
        archiveURL != nil && (checksumsURL != nil || archiveSHA256 != nil)
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case server(Int)
    case badResponse
    case noArchive
    case checksumsMissing
    case checksumMismatch
    case extract(String)
    case appNotFound
    case wrongApp(String)
    case notInstallable(String)
    case install(String)
    case cancelledByUser
    /// macOS 不让替换（“App 管理”权限或者别的系统保护）。
    case appManagement
    /// 新版本不是当前版本的开发者签的。
    case wrongSigner(String)

    public var errorDescription: String? {
        switch self {
        case .server(let code): return code == 404 ? "还没有发布过版本" : "服务器返回了 \(code)"
        case .badResponse: return "读不懂服务器返回的内容"
        case .noArchive: return "这个版本没有可以直接安装的附件，请到发布页手动下载"
        case .checksumsMissing: return "校验文件里没有这个附件的校验和"
        case .checksumMismatch: return "下载的文件校验和不对，可能没下载完整或被篡改"
        case .extract(let text): return "解压失败：\(text)"
        case .appNotFound: return "压缩包里没有 Stox.app"
        case .wrongApp(let text): return "下载的程序不对：\(text)"
        case .notInstallable(let text): return text
        case .install(let text): return "替换程序失败：\(text)"
        case .cancelledByUser: return "已取消授权，程序没有改动"
        case .appManagement:
            return "macOS 不允许 Stox 替换自己。到“系统设置 → 隐私与安全性 → App 管理”里允许 Stox，再点重试"
        case .wrongSigner(let team):
            return "新版本不是同一个开发者签名的（应该是 \(team)），为了安全没有安装。可以到发布页确认后手动下载"
        }
    }
}

/// 检查 GitHub 上的最新发布。
public enum UpdateCheck {
    public static let repository = "whrss9527/stox"
    public static let archiveName = "Stox.zip"
    public static let checksumsName = "SHA256SUMS.txt"
    /// 测试用：指向本地的假发布，走一遍下载、校验、替换、重新启动。
    public static let overrideVariable = "STOX_UPDATE_URL"

    public static var releasesURL: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    public static var apiURL: URL {
        if let text = ProcessInfo.processInfo.environment[overrideVariable], let url = URL(string: text) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public static func latest(currentVersion: String, session: URLSession = .shared) async throws -> ReleaseInfo {
        let data: Data
        do {
            data = try await HTTP.get(apiURL, session: session, timeout: 15, headers: [
                "Accept": "application/vnd.github+json",
                "User-Agent": "Stox/\(currentVersion) (macOS)",
            ])
        } catch ProviderError.badStatus(let code) {
            throw UpdateError.server(code)
        }
        guard let release = parse(data) else { throw UpdateError.badResponse }
        return release
    }

    /// 下载发布附带的校验文件 SHA256SUMS.txt 并解析。
    public static func checksums(at url: URL, currentVersion: String, session: URLSession = .shared) async throws -> [String: String] {
        let data: Data
        do {
            data = try await HTTP.get(url, session: session, timeout: 30, headers: [
                "User-Agent": "Stox/\(currentVersion) (macOS)",
            ])
        } catch ProviderError.badStatus(let code) {
            throw UpdateError.server(code)
        }
        return Checksums.parse(String(decoding: data, as: UTF8.self))
    }

    /// 解析 GitHub releases 接口返回的 JSON。
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty
        else { return nil }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(named name: String) -> [String: Any]? {
            assets.first { ($0["name"] as? String) == name }
        }
        let archive = asset(named: archiveName)
        let publishedAt = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(
            version: tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag,
            tag: tag,
            pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL,
            notes: (json["body"] as? String) ?? "",
            publishedAt: publishedAt,
            archiveURL: (archive?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            archiveName: archive?["name"] as? String,
            archiveSize: archive?["size"] as? Int,
            archiveDigest: archive?["digest"] as? String,
            checksumsURL: (asset(named: checksumsName)?["browser_download_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// 比较版本号：first 比 second 新返回 true。数字逐段比较；带 -beta 之类后缀的预发布版本比同号的正式版本旧。
    public static func isNewer(_ first: String, than second: String) -> Bool {
        let a = components(first)
        let b = components(second)
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        return !a.prerelease && b.prerelease
    }

    private static func components(_ version: String) -> (numbers: [Int], prerelease: Bool) {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        let parts = text.split(separator: "-", maxSplits: 1)
        let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, parts.count > 1)
    }
}

/// shasum -a 256 输出的校验文件：每行“哈希  文件名”。
public enum Checksums {
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            var name = parts[1...].joined(separator: " ")
            if name.hasPrefix("*") {
                name.removeFirst()
            }
            result[name] = hash
        }
        return result
    }
}

/// 更新装到哪里。
public struct InstallPlan: Equatable, Sendable {
    /// 新版本放在这里，也从这里重新打开。
    public var target: URL
    /// 装好后移到废纸篓的旧程序（从下载文件夹这类地方搬进“应用程序”时）。
    public var trashAfter: URL?
    /// 从临时位置搬进“应用程序”，而不是原地替换。
    public var relocating: Bool

    public init(target: URL, trashAfter: URL?, relocating: Bool) {
        self.target = target
        self.trashAfter = trashAfter
        self.relocating = relocating
    }

    /// 按路径比较：同一个 .app 的 URL 可能带或不带结尾的 /。
    public static func == (a: InstallPlan, b: InstallPlan) -> Bool {
        a.target.standardizedFileURL.path == b.target.standardizedFileURL.path
            && a.trashAfter?.standardizedFileURL.path == b.trashAfter?.standardizedFileURL.path
            && a.relocating == b.relocating
    }
}

/// 平时原地替换；从只读的临时位置运行时（系统出于安全把它搬走了，或者在只读磁盘上），装进“应用程序”。
public enum InstallLocation {
    public static let appName = "Stox.app"

    /// 纯逻辑，便于测试。folders 按优先顺序，canWrite 判断能不能不用管理员密码写进去。
    public static func plan(
        bundle: URL, translocated: Bool, original: URL?, readOnly: Bool,
        folders: [URL], canWrite: (URL) -> Bool
    ) -> InstallPlan? {
        guard bundle.pathExtension == "app" else { return nil }
        guard translocated || readOnly else {
            return InstallPlan(target: bundle, trashAfter: nil, relocating: false)
        }
        if let original {
            let parent = original.deletingLastPathComponent().standardizedFileURL.path
            if folders.contains(where: { $0.standardizedFileURL.path == parent }) {
                // 本来就在“应用程序”里，只是带着隔离标记被系统搬到临时位置运行：原地替换。
                return InstallPlan(target: original, trashAfter: nil, relocating: false)
            }
        }
        guard let first = folders.first else { return nil }
        let folder = folders.first(where: canWrite) ?? first
        let target = folder.appendingPathComponent(appName, isDirectory: true).standardizedFileURL
        let trash = original.flatMap { $0.standardizedFileURL.path == target.path ? nil : $0 }
        return InstallPlan(target: target, trashAfter: trash, relocating: true)
    }
}

/// 发布说明的整理：App 里只显示这个版本更新了什么，安装步骤和 GitHub 自动生成的列表不显示。
public enum ReleaseNotesText {
    static let highlightsHeading = "## 更新内容"
    /// 这些标题下面的内容不显示。
    static let skippedHeadings = ["## 安装", "## What's Changed", "## New Contributors"]

    public static func highlights(_ notes: String) -> String {
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var kept: [String] = []
        var skipping = false
        var sawHighlights = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if trimmed == highlightsHeading {
                    sawHighlights = true
                    skipping = false
                    continue
                }
                // 有“更新内容”时只要那一节；没有时跳过已知的几节，其他的照常显示。
                skipping = sawHighlights || skippedHeadings.contains { trimmed.hasPrefix($0) }
                continue
            }
            if trimmed.hasPrefix("**Full Changelog**") { continue }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
