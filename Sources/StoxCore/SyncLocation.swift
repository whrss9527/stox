import Foundation

/// 同步文件 sync.json 放在哪里。
///
/// - App 带着 iCloud 容器的 entitlement（App Store 版）时，放在 App 自己的 iCloud 容器 `iCloud.io.github.whrss9527.stox` 的 Documents 里。
///   沙盒里的 App 只能用自己的容器，读不到 iCloud 云盘里的其他文件夹。
/// - 没有这个 entitlement（GitHub 版，Developer ID 签名、没有描述文件）时，放在 iCloud 云盘/Stox 文件夹里，和以前一样。
///
/// 两处的文件格式完全一样（SyncDocument），只是位置不同：用容器的 Mac 之间互相同步，用 iCloud 云盘文件夹的 Mac 之间互相同步。
/// 这里只放不依赖系统的纯逻辑，Linux 上也能测试；真正向系统要容器地址的代码在 App 的 CloudFile 里。
public enum SyncLocation: Equatable, Sendable {
    /// 测试用：环境变量 STOX_SYNC_DIR 指定的文件夹。
    case override(URL)
    /// App 自己的 iCloud 容器里的文件夹（容器/Documents）。
    case container(URL)
    /// iCloud 云盘里的 Stox 文件夹。
    case drive(URL)

    /// App Store 版的 iCloud 容器。在开发者网站注册 App ID 时要勾选 iCloud 并添加这个容器。
    public static let containerIdentifier = "iCloud.io.github.whrss9527.stox"
    /// entitlement 里列出 App 能用的 iCloud 容器的键。
    public static let containerEntitlementKey = "com.apple.developer.icloud-container-identifiers"
    /// iCloud 云盘里的文件夹名（GitHub 版）。
    public static let driveFolderName = "Stox"
    /// 容器里的子文件夹。放在 Documents 里：以后要在“iCloud 云盘”里显示成 Stox 文件夹，只要在 Info.plist 里声明 NSUbiquitousContainers。
    public static let containerSubfolder = "Documents"
    public static let fileName = "sync.json"

    /// 同步文件所在的文件夹。
    public var folderURL: URL {
        switch self {
        case .override(let url), .container(let url), .drive(let url): return url
        }
    }

    public var fileURL: URL {
        folderURL.appendingPathComponent(Self.fileName)
    }

    /// 日志里的简短说明。
    public var kind: String {
        switch self {
        case .override: return "override"
        case .container: return "container"
        case .drive: return "drive"
        }
    }

    /// 按优先级选同步文件夹：测试用的覆盖 > App 自己的 iCloud 容器 > iCloud 云盘/Stox。
    /// - Parameters:
    ///   - override: 环境变量 STOX_SYNC_DIR 的值，空字符串当作没有。
    ///   - containerRoot: 系统给的容器根目录（`FileManager.url(forUbiquityContainerIdentifier:)`），没有 entitlement 或没登录 iCloud 时是 nil。
    ///   - driveRoot: iCloud 云盘的根目录，没开 iCloud 云盘时是 nil。
    public static func resolve(override: String?, containerRoot: URL?, driveRoot: URL?) -> SyncLocation? {
        if let override, !override.isEmpty {
            return .override(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let containerRoot {
            return .container(containerRoot.appendingPathComponent(containerSubfolder, isDirectory: true))
        }
        if let driveRoot {
            return .drive(driveRoot.appendingPathComponent(driveFolderName, isDirectory: true))
        }
        return nil
    }

    /// 从 entitlement 的值（字符串数组）判断 App 能不能用这个容器。没有这个 entitlement 时不去向系统要容器，
    /// GitHub 版因此完全不碰 iCloud 容器的接口，行为和以前一样。
    public static func hasContainer(entitlementValue: Any?, identifier: String = containerIdentifier) -> Bool {
        if let list = entitlementValue as? [String] {
            return list.contains(identifier)
        }
        if let list = entitlementValue as? [Any] {
            return list.contains { ($0 as? String) == identifier }
        }
        return false
    }

    /// 容器在本机的文件夹名：~/Library/Mobile Documents/ 下面的 iCloud~io~github~whrss9527~stox。
    /// 只用于说明和排查问题；App 里一律通过系统接口拿容器地址。
    public static func mobileDocumentsFolderName(for identifier: String = containerIdentifier) -> String {
        identifier.replacingOccurrences(of: ".", with: "~")
    }
}
