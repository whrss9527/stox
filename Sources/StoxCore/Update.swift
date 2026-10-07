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
        case .server(let code): return code == 404 ? L("还没有发布过版本") : L("服务器返回了 %@", code)
        case .badResponse: return L("读不懂服务器返回的内容")
        case .noArchive: return L("这个版本没有可以直接安装的附件，请到发布页手动下载")
        case .checksumsMissing: return L("校验文件里没有这个附件的校验和")
        case .checksumMismatch: return L("下载的文件校验和不对，可能没下载完整或被篡改")
        case .extract(let text): return L("解压失败：%@", text)
        case .appNotFound: return L("压缩包里没有 Stox.app")
        case .wrongApp(let text): return L("下载的程序不对：%@", text)
        case .notInstallable(let text): return text
        case .install(let text): return L("替换程序失败：%@", text)
        case .cancelledByUser: return L("已取消授权，程序没有改动")
        case .appManagement:
            return L("macOS 不允许 Stox 替换自己。到“系统设置 → 隐私与安全性 → App 管理”里允许 Stox，再点重试")
        case .wrongSigner(let team):
            return L("新版本不是同一个开发者签名的（应该是 %@），为了安全没有安装。可以到发布页确认后手动下载", team)
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

    /// 某个版本的发布页接口，用来在“已更新到 x.y.z”里直接显示这个版本的更新内容。
    public static func releaseURL(version: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/tags/v\(version)")
    }

    public static func release(version: String, currentVersion: String, session: URLSession = .shared) async throws -> ReleaseInfo {
        guard let url = releaseURL(version: version) else { throw UpdateError.badResponse }
        let data: Data
        do {
            data = try await HTTP.get(url, session: session, timeout: 15, headers: [
                "Accept": "application/vnd.github+json",
                "User-Agent": "Stox/\(currentVersion) (macOS)",
            ])
        } catch ProviderError.badStatus(let code) {
            throw UpdateError.server(code)
        }
        guard let release = parse(data) else { throw UpdateError.badResponse }
        return release
    }

    /// 最近的一批发布（新的在前）。隔了几个版本才更新时，用来列出中间每个版本的更新内容。
    public static func listURL(count: Int) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(min(max(count, 1), 100))")
    }

    public static func releases(count: Int = 30, currentVersion: String, session: URLSession = .shared) async throws -> [ReleaseInfo] {
        guard let url = listURL(count: count) else { throw UpdateError.badResponse }
        let data: Data
        do {
            data = try await HTTP.get(url, session: session, timeout: 15, headers: [
                "Accept": "application/vnd.github+json",
                "User-Agent": "Stox/\(currentVersion) (macOS)",
            ])
        } catch ProviderError.badStatus(let code) {
            throw UpdateError.server(code)
        }
        return parseList(data)
    }

    /// 解析 releases 列表接口返回的 JSON 数组；草稿、预发布和认不出的跳过。
    public static func parseList(_ data: Data) -> [ReleaseInfo] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap(parse(object:))
    }

    /// 比 since 新、又不比 latest 新的那些发布，从新到旧：从 since 更新到 latest 时中间的每个版本（含 latest）。
    public static func releases(_ all: [ReleaseInfo], after since: String, upTo latest: String) -> [ReleaseInfo] {
        all.filter { isNewer($0.version, than: since) && !isNewer($0.version, than: latest) }
            .sorted { isNewer($0.version, than: $1.version) }
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
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(parse(object:))
    }

    /// 解析一个发布的 JSON 对象（单个发布的接口和列表接口里的每一项都是这样）。
    static func parse(object json: [String: Any]) -> ReleaseInfo? {
        guard let tag = json["tag_name"] as? String, !tag.isEmpty else { return nil }
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
    static let highlightsHeading = "## 更新内容"  // l10n-ignore
    /// 这些标题下面的内容不显示。
    static let skippedHeadings = ["## 安装", "## Installation", "## What's Changed", "## New Contributors"]  // l10n-ignore

    public static func highlights(_ notes: String, isEnglish: Bool = AppLanguage.isEnglish) -> String {
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
        return localized(kept.joined(separator: "\n"), isEnglish: isEnglish)
    }

    /// 新版在同一节里用语言小标题分隔，旧版没有英文时仍显示中文。
    private static func localized(_ notes: String, isEnglish: Bool) -> String {
        let chineseHeading = "### 中文"  // l10n-ignore
        var chinese: [String] = [], english: [String] = []
        var inEnglish = false
        for line in notes.components(separatedBy: "\n") {
            let heading = line.trimmingCharacters(in: .whitespaces)
            if heading == chineseHeading { inEnglish = false; continue }
            if heading == "### English" { inEnglish = true; continue }
            if inEnglish { english.append(line) } else { chinese.append(line) }
        }
        let zh = chinese.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let en = english.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return isEnglish ? (en.isEmpty ? zh : en) : (zh.isEmpty ? en : zh)
    }

    /// 几个版本的更新内容合在一起（从新到旧）：每个版本一段，开头是加粗的版本号，下面是它的“更新内容”。
    /// 最多 limit 个版本，更早的只写还有几个。
    public static func combined(_ releases: [ReleaseInfo], limit: Int) -> String {
        let shown = releases.prefix(max(limit, 1))
        var parts = shown.map { release -> String in
            let text = release.highlights
            return "**\(release.version)**\n" + (text.isEmpty ? L("这个版本没有写更新内容") : text)
        }
        if releases.count > shown.count {
            parts.append(L("还有 %@ 个更早的版本，见发布页", releases.count - shown.count))
        }
        return parts.joined(separator: "\n\n")
    }

    /// 一条更新内容的开头一句：到第一个冒号为止（写在冒号前的一般是功能的名字，比如“盈亏日历：……”），
    /// 没有冒号就到第一个逗号、句号或分号；这样也超过 maxLength 个字时截断，加上省略号。
    public static func headline(_ text: String, maxLength: Int = 36) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        for stops in [["：", ":"], ["，", "。", "；"]] as [[Character]] {  // l10n-ignore
            if let index = text.firstIndex(where: { stops.contains($0) }), index > text.startIndex,
               text.distance(from: text.startIndex, to: index) <= maxLength {
                return String(text[..<index])
            }
        }
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text  // l10n-ignore
    }

    /// 每个版本只取更新内容第一条的开头一句，“已更新到 x.y.z”里一行一个版本：`0.37.0 盈亏日历`。
    /// 最多 limit 个版本（从新到旧），更早的合成一行“还有 N 个版本”。
    public static func firstLines(_ releases: [ReleaseInfo], limit: Int) -> [String] {
        let shown = releases.prefix(max(limit, 1))
        var lines = shown.map { release -> String in
            let first = release.highlights
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
                .map { line -> String in
                    var text = line
                    if text.hasPrefix("- ") || text.hasPrefix("* ") { text.removeFirst(2) }
                    return text
                } ?? ""
            return "- **\(release.version)** " + (first.isEmpty ? L("这个版本没有写更新内容") : headline(first))
        }
        if releases.count > shown.count {
            lines.append(L("- 还有 %@ 个更早的版本", releases.count - shown.count))
        }
        return lines
    }
}
