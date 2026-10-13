import Foundation
import StoxCore

/// 可暂停的文件访问边界；协调读写已经开始后，取消调用方不撤销文件副作用。
struct SyncFileAccess: Sendable {
    var requiresContainer: Bool
    var containerRoot: @Sendable () async -> URL?
    var read: @Sendable (URL, SyncContent?) async throws -> SyncDocument?
    var merge: @Sendable (SyncDocument, SyncContent?, URL) async throws -> SyncDocument

    static let live = SyncFileAccess(
        requiresContainer: CloudFile.hasContainerEntitlement,
        containerRoot: { await Task.detached(priority: .utility) { CloudFile.containerRoot() }.value },
        read: { url, base in
            try await Task.detached(priority: .utility) { () throws -> SyncDocument? in
                if let winner = try CloudFile.resolveConflicts(at: url, base: base) { return winner }
                return try CloudFile.read(at: url)
            }.value
        },
        merge: { document, base, url in
            try await Task.detached(priority: .utility) { try CloudFile.merge(document, base: base, at: url) }.value
        }
    )
}
