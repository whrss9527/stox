import AppKit
import Combine
import StoxCore

/// iCloud 同步：开关、首次开启时的取舍、监听云端文件、把本机改动写上去。只在主线程上用。
@MainActor
final class SyncManager: ObservableObject {
    enum Status: Equatable {
        case off
        /// iCloud 云盘没开。
        case unavailable
        case syncing
        /// 上次同步的时间和来源设备（可能是本机）。
        case synced(Date, String)
        case error(String)
    }

    enum Choice {
        case useCloud
        case useLocal
        case merge
    }

    @Published private(set) var enabled = false
    @Published private(set) var status: Status = .off
    /// 首次开启时 iCloud 里已经有不一样的内容，等用户选择怎么办。
    @Published var pending: SyncDocument?

    private let store: QuoteStore
    private let settings: SettingsStore
    private let defaults: UserDefaults
    private static let lastSyncedKey = "sync.lastSynced"
    /// 上次和 iCloud 一致时的内容。保存下来，重新启动后才能分清是本机改了还是 iCloud 改了：
    /// 改完马上退出、没来得及写上去的本机改动，下次启动时写上去，而不是被 iCloud 里的旧内容覆盖。
    private var lastSynced: SyncContent? {
        didSet {
            if let lastSynced, let data = try? JSONEncoder().encode(lastSynced) {
                defaults.set(data, forKey: Self.lastSyncedKey)
            } else {
                defaults.removeObject(forKey: Self.lastSyncedKey)
            }
        }
    }
    private var lastStamp: String?
    private var lastPull = Date.distantPast
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var pushTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    /// 正在应用云端内容：这期间本机的“改动”不是用户改的，不要再写回去。
    private var isApplyingRemote = false

    init(store: QuoteStore, settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.settings = settings
        self.defaults = defaults
        store.onLocalEdit = { [weak self] in self?.localChanged() }
        settings.onSyncedSettingChange = { [weak self] in self?.localChanged() }
    }

    var folderURL: URL? { CloudFile.folderURL }
    var fileURL: URL? { folderURL?.appendingPathComponent(CloudFile.fileName) }
    var available: Bool { folderURL != nil }

    private var currentContent: SyncContent {
        SyncContent(watchlist: store.items, settings: settings.syncedSettings)
    }

    // MARK: - 备份到文件

    /// 导出的备份：和 iCloud 里的同步文件一样的格式。
    func backupData() throws -> Data {
        try SyncDocument(updatedAt: Date(), device: CloudFile.deviceName, content: currentContent).encoded()
    }

    /// 导入备份：替换本机的自选和设置，或者只添加本机没有的证券。和在本机改动一样，开着同步时会同步上去。
    func importBackup(_ content: SyncContent, replace: Bool) {
        let result = replace ? content : currentContent.importing(content)
        store.replaceWatchlist(result.watchlist)
        settings.apply(result.settings)
        Log.info("导入备份：\(replace ? "替换" : "合并")，现在 \(store.items.count) 只")
    }

    // MARK: - 开关

    /// 启动时按记录的开关恢复。
    func start() {
        guard settings.syncEnabled else { return }
        enabled = true
        lastSynced = defaults.data(forKey: Self.lastSyncedKey).flatMap { try? JSONDecoder().decode(SyncContent.self, from: $0) }
        guard available else {
            status = .unavailable
            return
        }
        status = .syncing
        startWatching()
        pullTask = Task { @MainActor [weak self] in await self?.pull() }
    }

    /// 用户打开开关：iCloud 里已有不同的内容时先问用户，否则直接开始。
    func enable() async {
        guard !enabled else { return }
        guard available else {
            status = .unavailable
            return
        }
        status = .syncing
        do {
            let local = currentContent
            let remote = try await readCloud()
            if SyncRules.needsChoice(remote: remote?.content, local: local), let remote {
                pending = remote
                status = .off
                return
            }
            // 云端没有文件、内容一样或者是空的：直接把本机的写上去。
            await finishEnable(push: true)
        } catch {
            status = .error("读取 iCloud 失败：\(error.localizedDescription)")
            Log.error("iCloud 同步：读取失败：\(error.localizedDescription)")
        }
    }

    /// 首次开启时用户的选择。
    func resolve(_ choice: Choice) {
        guard let remote = pending else { return }
        pending = nil
        Task { @MainActor [weak self] in
            await self?.apply(choice, remote: remote)
        }
    }

    private func apply(_ choice: Choice, remote: SyncDocument) async {
        switch choice {
        case .useCloud:
            applyRemote(remote.content)
            lastSynced = currentContent
            Log.info("iCloud 同步：用 iCloud 里的内容替换了本机的")
            await finishEnable(push: false)
            status = .synced(remote.updatedAt, remote.device)
        case .useLocal:
            await finishEnable(push: true)
        case .merge:
            applyRemote(currentContent.merging(cloud: remote.content))
            Log.info("iCloud 同步：合并了本机和 iCloud 的自选")
            await finishEnable(push: true)
        }
    }

    func cancelEnable() {
        pending = nil
        status = .off
    }

    func disable() {
        pushTask?.cancel()
        pullTask?.cancel()
        stopWatching()
        enabled = false
        lastSynced = nil
        lastStamp = nil
        status = .off
        settings.syncEnabled = false
        Log.info("iCloud 同步：已关闭")
    }

    /// 立即拉一次、再把本机的推上去（如果不一样）。
    func syncNow() async {
        guard enabled, available else { return }
        await pull()
        if SyncRules.shouldPush(local: currentContent, lastSynced: lastSynced) {
            await push()
        }
    }

    /// 退出前把还没写上去的本机改动写到 iCloud。文件很小，直接在主线程上写完再退出。
    func flushBeforeQuit() {
        guard enabled, let url = fileURL, SyncRules.shouldPush(local: currentContent, lastSynced: lastSynced) else { return }
        pushTask?.cancel()
        let document = SyncDocument(updatedAt: Date(), device: CloudFile.deviceName, content: currentContent)
        do {
            try CloudFile.write(document, to: url)
            lastSynced = document.content
            Log.info("iCloud 同步：退出前写入了本机的改动（\(document.content.watchlist.count) 只）")
        } catch {
            Log.error("iCloud 同步：退出前写入失败：\(error.localizedDescription)")
        }
    }

    /// 打开面板时顺便看看云端有没有变化（距离上次检查超过 10 秒）。
    func panelWillOpen() {
        guard enabled, Date().timeIntervalSince(lastPull) > 10 else { return }
        pullIfChanged()
    }

    private func finishEnable(push: Bool) async {
        enabled = true
        settings.syncEnabled = true
        startWatching()
        if push {
            await self.push()
        }
        Log.info("iCloud 同步：已开启（\(folderURL?.path ?? "")）")
    }

    // MARK: - 本机改动

    /// 本机内容变了：稍等一下（连续改动合并成一次）再写到 iCloud。
    private func localChanged() {
        guard enabled, !isApplyingRemote else { return }
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // 写之前再读一次本机内容：这期间应用过云端的改动时，就不会把旧内容写回去。
            if SyncRules.shouldPush(local: self.currentContent, lastSynced: self.lastSynced) {
                await self.push()
            }
        }
    }

    private func push() async {
        guard let url = fileURL else {
            status = .unavailable
            return
        }
        let content = currentContent
        let document = SyncDocument(updatedAt: Date(), device: CloudFile.deviceName, content: content)
        do {
            try await Task.detached(priority: .utility) {
                try CloudFile.write(document, to: url)
            }.value
            lastSynced = content
            lastStamp = CloudFile.stamp(of: url)
            status = .synced(document.updatedAt, document.device)
            Log.info("iCloud 同步：已写入本机的自选和设置（\(content.watchlist.count) 只）")
        } catch {
            status = .error("写入 iCloud 失败：\(error.localizedDescription)")
            Log.error("iCloud 同步：写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 云端改动

    private func readCloud() async throws -> SyncDocument? {
        guard let url = fileURL else { throw SyncError.unavailable }
        return try await Task.detached(priority: .utility) { () throws -> SyncDocument? in
            if let winner = CloudFile.resolveConflicts(at: url) {
                return winner
            }
            return try CloudFile.read(at: url)
        }.value
    }

    /// 文件变了才真正去读。
    private func pullIfChanged() {
        guard enabled, let url = fileURL else { return }
        let stamp = CloudFile.stamp(of: url)
        guard stamp != lastStamp || lastSynced == nil else { return }
        pullTask?.cancel()
        pullTask = Task { @MainActor [weak self] in
            // 等一下：iCloud 写文件常常是几次连续的改动。
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pull()
        }
    }

    private func pull() async {
        guard enabled else { return }
        lastPull = Date()
        do {
            guard let remote = try await readCloud() else {
                // 云端还没有文件（第一次，或者被删了）：把本机的放上去。
                await push()
                return
            }
            lastStamp = fileURL.flatMap(CloudFile.stamp(of:))
            if SyncRules.shouldApply(remote: remote.content, local: currentContent, lastSynced: lastSynced) {
                applyRemote(remote.content)
                Log.info("iCloud 同步：应用了来自 \(remote.device) 的改动（\(remote.content.watchlist.count) 只）")
            }
            lastSynced = remote.content
            status = .synced(remote.updatedAt, remote.device)
            // iCloud 没变而本机变了（上次改完没来得及写上去），或者云端文件缺了一些设置：把本机的写上去。
            if SyncRules.shouldPush(local: currentContent, lastSynced: lastSynced) {
                await push()
            }
        } catch {
            status = .error("读取 iCloud 失败：\(error.localizedDescription)")
            Log.error("iCloud 同步：读取失败：\(error.localizedDescription)")
        }
    }

    private func applyRemote(_ content: SyncContent) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        store.replaceWatchlist(content.watchlist)
        settings.apply(content.settings)
    }

    // MARK: - 监听

    private func startWatching() {
        stopWatching()
        guard let folder = folderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.pullIfChanged() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        } else {
            Log.error("iCloud 同步：无法监听文件夹，改为定时检查")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pullIfChanged() }
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        timer?.invalidate()
        timer = nil
    }
}
