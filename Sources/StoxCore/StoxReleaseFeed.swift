import Foundation
import FritCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App 的已更新说明和 Linux CLI 共用的只读接口。解析、排序、摘要与
/// 正式附件归属由 FritCore 负责；下载/替换仅在普通版的 FritUpdate 中。
public enum StoxReleaseFeed {
    public static let repository = "whrss9527/stox"
    public static let archiveName = "Stox.zip"
    public static let checksumsName = "SHA256SUMS.txt"
    public static var notesStyle: ReleaseNotes.Style { .stox(language: AppLanguage.isEnglish ? .english : .chinese) }
    private static var override: URL? { ProcessInfo.processInfo.environment["STOX_UPDATE_URL"].flatMap(URL.init(string:)) }

    public static func latest(currentVersion: String, session: URLSession = .shared) async throws -> UpdateCandidate {
        let url = override ?? URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let records = try await fetch(url, currentVersion: currentVersion, session: session)
        guard let release = ReleaseFeed.newest(records) else { throw ProviderError.emptyResponse }
        return candidate(release, testSource: override)
    }

    public static func releases(count: Int, currentVersion: String, session: URLSession = .shared) async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(max(1, min(count, 100)))")!
        return try await fetch(url, currentVersion: currentVersion, session: session)
    }

    public static func release(version: String, currentVersion: String, session: URLSession = .shared) async throws -> GitHubRelease {
        guard AppVersion(version) != nil, let url = URL(string: "https://api.github.com/repos/\(repository)/releases/tags/v\(version)") else {
            throw ProviderError.emptyResponse
        }
        guard let release = try await fetch(url, currentVersion: currentVersion, session: session).first else { throw ProviderError.emptyResponse }
        return release
    }

    private static func fetch(_ url: URL, currentVersion: String, session: URLSession) async throws -> [GitHubRelease] {
        let data = try await HTTP.get(url, session: session, timeout: 15,
                                      headers: ["Accept": "application/vnd.github+json", "User-Agent": "Stox/\(currentVersion) (macOS)"])
        guard let records = ReleaseFeed.parse(data) else { throw ProviderError.emptyResponse }
        return records
    }

    public static func candidate(_ release: GitHubRelease, testSource: URL? = nil) -> UpdateCandidate {
        if let source = testSource {
            let directory = source.deletingLastPathComponent().path
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            let owned = release.assets.filter {
                $0.downloadURL.scheme == source.scheme && $0.downloadURL.host == source.host && $0.downloadURL.port == source.port
                    && $0.downloadURL.path.hasPrefix(prefix)
            }
            return UpdateCandidate(release: release, archive: owned.first { $0.name == archiveName }, checksums: owned.first { $0.name == checksumsName })
        }
        return UpdateCandidate(release: release, naming: .fixed(archiveName), architecture: .arm64, publishedBy: repository)
    }
}
