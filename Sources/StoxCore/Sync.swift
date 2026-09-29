import Foundation

/// 在多台 Mac 之间同步的设置。字段都是可选的：缺少的字段保留本机的值，以后增减设置项也不影响旧文件。
/// “隐藏菜单栏行情”“全局快捷键”“开机启动”这类只和这台 Mac 有关的设置不同步。
public struct SyncedSettings: Codable, Equatable, Sendable {
    public var refreshInterval: Double?
    public var slowWhenIdle: Bool?
    public var colorScheme: String?
    public var showName: Bool?
    public var showPrice: Bool?
    public var showPercent: Bool?
    public var rotateTicker: Bool?
    public var alertsEnabled: Bool?
    /// 菜单栏行情的排法（TickerLayout 的 rawValue）。旧版本没有这一项，读到时忽略。
    public var tickerLayout: String?

    public init(
        refreshInterval: Double? = nil,
        slowWhenIdle: Bool? = nil,
        colorScheme: String? = nil,
        showName: Bool? = nil,
        showPrice: Bool? = nil,
        showPercent: Bool? = nil,
        rotateTicker: Bool? = nil,
        alertsEnabled: Bool? = nil,
        tickerLayout: String? = nil
    ) {
        self.refreshInterval = refreshInterval
        self.slowWhenIdle = slowWhenIdle
        self.colorScheme = colorScheme
        self.showName = showName
        self.showPrice = showPrice
        self.showPercent = showPercent
        self.rotateTicker = rotateTicker
        self.alertsEnabled = alertsEnabled
        self.tickerLayout = tickerLayout
    }

    /// 用 other 里有值的字段覆盖自己。
    public func overlaid(with other: SyncedSettings) -> SyncedSettings {
        SyncedSettings(
            refreshInterval: other.refreshInterval ?? refreshInterval,
            slowWhenIdle: other.slowWhenIdle ?? slowWhenIdle,
            colorScheme: other.colorScheme ?? colorScheme,
            showName: other.showName ?? showName,
            showPrice: other.showPrice ?? showPrice,
            showPercent: other.showPercent ?? showPercent,
            rotateTicker: other.rotateTicker ?? rotateTicker,
            alertsEnabled: other.alertsEnabled ?? alertsEnabled,
            tickerLayout: other.tickerLayout ?? tickerLayout
        )
    }
}

/// 同步的内容：自选（连同价格提醒、菜单栏简称、是否显示在菜单栏）和设置。
public struct SyncContent: Equatable, Sendable {
    public var watchlist: [WatchItem]
    public var settings: SyncedSettings

    public init(watchlist: [WatchItem], settings: SyncedSettings) {
        self.watchlist = watchlist
        self.settings = settings
    }

    /// 从备份文件导入时的“合并”：本机的自选和设置都不动，只把备份里本机没有的证券追加在后面。
    public func importing(_ backup: SyncContent) -> SyncContent {
        backup.merging(cloud: self)
    }

    /// 备份文件默认的文件名，例如“Stox 自选 2026-09-28.json”。
    public static func backupFileName(on date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "Stox 自选 %04d-%02d-%02d.json", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 首次开启同步时的“合并”：自选以 iCloud 的为准（顺序和每一项的设置），本机独有的追加在后面；设置用 iCloud 的。
    public func merging(cloud: SyncContent) -> SyncContent {
        var seen = Set(cloud.watchlist.map(\.symbol))
        let extra = watchlist.filter { seen.insert($0.symbol).inserted }
        return SyncContent(watchlist: cloud.watchlist + extra, settings: settings.overlaid(with: cloud.settings))
    }
}

extension SyncContent: Codable {
    enum CodingKeys: String, CodingKey {
        case watchlist, settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decodeIfPresent([LossyWatchItem].self, forKey: .watchlist) ?? []
        watchlist = Watchlist.deduplicated(items.compactMap(\.item))
        settings = try container.decodeIfPresent(SyncedSettings.self, forKey: .settings) ?? SyncedSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(watchlist, forKey: .watchlist)
        try container.encode(settings, forKey: .settings)
    }
}

/// iCloud 云盘里的同步文件：内容，加上是哪台 Mac、什么时候写的。
public struct SyncDocument: Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var updatedAt: Date
    public var device: String
    public var content: SyncContent

    public init(format: Int = SyncDocument.currentFormat, updatedAt: Date, device: String, content: SyncContent) {
        self.format = format
        self.updatedAt = updatedAt
        self.device = device
        self.content = content
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// 解码同步文件。更新版本的 Stox 写的新格式读不懂时报错，而不是用本机数据覆盖它。
    public static func decode(_ data: Data) throws -> SyncDocument {
        let document = try decoder.decode(SyncDocument.self, from: data)
        guard document.format <= currentFormat else { throw SyncError.newerFormat(document.format) }
        return document
    }

    /// 冲突版本里改动时间最晚的那一份。
    public static func newest(_ candidates: [SyncDocument]) -> SyncDocument? {
        candidates.max { $0.updatedAt < $1.updatedAt }
    }
}

extension SyncDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case format, updatedAt, device, content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? SyncDocument.currentFormat
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? "未知设备"
        content = try container.decode(SyncContent.self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(device, forKey: .device)
        try container.encode(content, forKey: .content)
    }
}

public enum SyncError: LocalizedError, Equatable {
    /// 没有开启 iCloud 云盘。
    case unavailable
    /// 云端文件由更新版本的 Stox 写入。
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "iCloud 云盘没有开启"
        case .newerFormat: return "iCloud 里的数据来自更新版本的 Stox，请先把这台 Mac 上的 Stox 更新到最新版"
        }
    }
}

/// 同步时怎么处理两边的内容。只看内容，不看时间：
/// 本机上次同步后没改过、云端却变了，就是别的 Mac 改的；本机和上次同步的不一样，就是本机改的。
public enum SyncRules {
    /// 读到云端内容后是否应用到本机：和本机不同，并且也不是本机上次同步的那份。
    public static func shouldApply(remote: SyncContent, local: SyncContent, lastSynced: SyncContent?) -> Bool {
        remote != local && remote != lastSynced
    }

    /// 是否要把本机的写到云端：本机内容和上次同步的不同。
    public static func shouldPush(local: SyncContent, lastSynced: SyncContent?) -> Bool {
        local != lastSynced
    }

    /// 第一次开启同步时，云端已经有不同的内容，需要让用户选择用哪边的。
    public static func needsChoice(remote: SyncContent?, local: SyncContent) -> Bool {
        guard let remote else { return false }
        return remote != local && !remote.watchlist.isEmpty
    }
}
