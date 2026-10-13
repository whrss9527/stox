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
    private let clock: QuoteStoreClock
    private let locationOverride: SyncLocation?
    private let watchesChanges: Bool
    private let files: SyncFileAccess
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
    private var localUpdatedAt: Date {
        get { defaults.object(forKey: "sync.localUpdatedAt") as? Date ?? clock.now() }
        set { defaults.set(newValue, forKey: "sync.localUpdatedAt") }
    }

    private var localDocument: SyncDocument {
        SyncDocument(updatedAt: localUpdatedAt, device: CloudFile.deviceName, content: currentContent)
    }

    private var lastStamp: String?
    private var lastPull = Date.distantPast
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var pushTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var choiceTask: Task<Void, Never>?
    private var sessionGeneration = 0
    private var operationGeneration = 0
    private var lookupGeneration = 0
    private struct Operation {
        var session: Int
        var generation: Int
    }
    /// 正在应用云端内容：这期间本机的“改动”不是用户改的，不要再写回去。
    private var isApplyingRemote = false

    init(store: QuoteStore, settings: SettingsStore, defaults: UserDefaults = .standard,
         clock: QuoteStoreClock? = nil, location: SyncLocation? = nil, watchesChanges: Bool = true,
         files: SyncFileAccess = .live) {
        self.store = store
        self.settings = settings
        self.defaults = defaults
        self.clock = clock ?? QuoteStoreClock()
        self.locationOverride = location
        self.watchesChanges = watchesChanges
        self.files = files
        store.onLocalEdit = { [weak self] in self?.localChanged() }
        settings.onSyncedSettingChange = { [weak self] in self?.localChanged() }
    }

    /// App 自己的 iCloud 容器的根目录（只有 App Store 版有）。要在后台线程上向系统要，要到之前是 nil。
    @Published private(set) var containerRoot: URL?
    private var containerLookup: Task<Void, Never>?

    /// 同步文件放在哪里：App Store 版在 App 的 iCloud 容器里，GitHub 版在 iCloud 云盘/Stox 文件夹里。
    var location: SyncLocation? { locationOverride ?? CloudFile.location(containerRoot: containerRoot) }
    var folderURL: URL? { location?.folderURL }
    var fileURL: URL? { location?.fileURL }
    var available: Bool { location != nil }

    /// 未知证券不进入行情列表，另存一份，关掉同步或重新启动也不会丢。
    private var unknownWatchItems: [PreservedJSONItem] {
        get {
            defaults.data(forKey: "sync.unknownWatchItems").flatMap {
                try? JSONDecoder().decode([PreservedJSONItem].self, from: $0)
            } ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "sync.unknownWatchItems")
            }
        }
    }

    private var currentContent: SyncContent {
        SyncContent(watchlist: store.items, settings: settings.syncedSettings, unknownWatchItems: unknownWatchItems)
    }

    // MARK: - 备份到文件

    /// 导出的备份：和 iCloud 里的同步文件一样的格式。
    func backupData() throws -> Data {
        try SyncDocument(updatedAt: clock.now(), device: CloudFile.deviceName, content: currentContent).encoded()
    }

    /// 导入备份：替换本机的自选和设置，或者只添加本机没有的证券。和在本机改动一样，开着同步时会同步上去。
    func importBackup(_ content: SyncContent, replace: Bool) {
        let result = replace ? content : currentContent.importing(content)
        unknownWatchItems = result.unknownWatchItems
        store.replaceWatchlist(result.watchlist)
        settings.apply(result.settings)
        Log.info("导入备份：\(replace ? "替换" : "合并")，现在 \(store.items.count) 只")
    }

    // MARK: - 开关

    /// 启动时按记录的开关恢复。
    @discardableResult
    func start() -> Task<Void, Never> {
        let session = invalidateSession()
        enabled = settings.syncEnabled
        status = enabled ? .syncing : .off
        // 未开启同步时也查可用性；会话变化后旧查找不得更新新会话。
        let lookup = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.lookUpContainer(in: session)
        }
        containerLookup = lookup
        guard enabled else { return lookup }
        lastSynced = defaults.data(forKey: Self.lastSyncedKey).flatMap { try? JSONDecoder().decode(SyncContent.self, from: $0) }
        status = .syncing
        let restore = Task<Void, Never> { @MainActor [weak self] in
            await lookup.value
            guard let self, self.isCurrentSession(session) else { return }
            guard self.available else {
                self.status = .unavailable
                return
            }
            self.startWatching()
            _ = await self.pull()
        }
        pullTask = restore
        return restore
    }

    /// 向系统要 App 自己的 iCloud 容器。第一次可能要几秒，放在后台线程上；已经要到了、或者没有 entitlement 时直接返回。
    private func lookUpContainer(in session: Int) async {
        guard isCurrentSession(session, requiresEnabled: false), files.requiresContainer, containerRoot == nil else { return }
        lookupGeneration &+= 1
        let lookup = lookupGeneration
        let root = await files.containerRoot()
        guard isCurrentSession(session, requiresEnabled: false), lookup == lookupGeneration else { return }
        containerRoot = root
        if let root {
            Log.info("iCloud 同步：使用 App 的 iCloud 容器（\(root.path)）")
        } else {
            Log.info("iCloud 同步：拿不到 App 的 iCloud 容器（没有登录 iCloud，或者没有打开 iCloud 云盘）")
        }
    }

    /// 用户打开开关：iCloud 里已有不同的内容时先问用户，否则直接开始。
    func enable() async {
        guard !enabled, !Task.isCancelled else { return }
        let session = invalidateSession()
        status = .syncing
        // 启动时没要到容器（比如那时还没登录 iCloud）：再要一次。
        await lookUpContainer(in: session)
        guard isCurrentSession(session, requiresEnabled: false) else { return }
        guard available else {
            status = .unavailable
            return
        }
        let operation = beginOperation(in: session)
        do {
            let local = currentContent
            let remote = try await readCloud()
            guard isCurrent(operation, requiresEnabled: false) else { return }
            if SyncRules.needsChoice(remote: remote?.content, local: local), let remote {
                pending = remote
                status = .off
                return
            }
            // 云端没有文件、内容一样或者是空的：直接把本机的写上去。
            await finishEnable(push: true, in: session)
        } catch {
            guard isCurrent(operation, requiresEnabled: false) else { return }
            status = .error(L("读取 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：读取失败：\(error.localizedDescription)")
        }
    }

    /// 首次开启时用户的选择。
    @discardableResult
    func resolve(_ choice: Choice) -> Task<Void, Never>? {
        let session = sessionGeneration
        guard let remote = pending, isCurrentSession(session, requiresEnabled: false) else { return nil }
        pending = nil
        choiceTask?.cancel()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.apply(choice, remote: remote, in: session)
        }
        choiceTask = task
        return task
    }

    private func apply(_ choice: Choice, remote: SyncDocument, in session: Int) async {
        guard isCurrentSession(session, requiresEnabled: false) else { return }
        switch choice {
        case .useCloud:
            applyRemote(remote.content)
            lastSynced = currentContent
            Log.info("iCloud 同步：用 iCloud 里的内容替换了本机的")
            await finishEnable(push: false, in: session)
            guard isCurrentSession(session) else { return }
            status = .synced(remote.updatedAt, remote.device)
        case .useLocal:
            lastSynced = remote.content
            localUpdatedAt = clock.now()
            await finishEnable(push: true, in: session)
        case .merge:
            applyRemote(currentContent.merging(cloud: remote.content))
            lastSynced = remote.content
            localUpdatedAt = clock.now()
            Log.info("iCloud 同步：合并了本机和 iCloud 的自选")
            await finishEnable(push: true, in: session)
        }
    }

    func cancelEnable() {
        invalidateSession()
        enabled = false
        lastSynced = nil
        status = .off
        settings.syncEnabled = false
    }

    func disable() {
        cancelEnable()
        Log.info("iCloud 同步：已关闭")
    }

    /// 立即拉一次、再把本机的推上去（如果不一样）。
    func syncNow() async {
        let session = sessionGeneration
        guard isCurrentSession(session), available else { return }
        guard await pull(), isCurrentSession(session) else { return }
        if SyncRules.shouldPush(local: currentContent, lastSynced: lastSynced) {
            _ = await push()
        }
    }

    /// 退出前把还没写上去的本机改动写到 iCloud。文件很小，直接在主线程上写完再退出。
    func flushBeforeQuit() {
        guard enabled, let url = fileURL, SyncRules.shouldPush(local: currentContent, lastSynced: lastSynced) else { return }
        pushTask?.cancel()
        operationGeneration &+= 1
        let document = localDocument
        do {
            let merged = try CloudFile.merge(document, base: lastSynced, at: url)
            applyRemote(merged.content)
            lastSynced = merged.content
            Log.info("iCloud 同步：退出前写入了本机的改动（\(document.content.watchlist.count) 只）")
        } catch {
            Log.error("iCloud 同步：退出前写入失败：\(error.localizedDescription)")
        }
    }

    /// 打开面板时顺便看看云端有没有变化（距离上次检查超过 10 秒）。
    func panelWillOpen() {
        guard enabled, clock.now().timeIntervalSince(lastPull) > 10 else { return }
        pullIfChanged()
    }

    private func finishEnable(push: Bool, in session: Int) async {
        guard isCurrentSession(session, requiresEnabled: false) else { return }
        enabled = true
        settings.syncEnabled = true
        startWatching()
        if push {
            _ = await self.push()
        }
        guard isCurrentSession(session) else { return }
        Log.info("iCloud 同步：已开启（\(location?.kind ?? "")：\(folderURL?.path ?? "")）")
    }

    // MARK: - 本机改动

    /// 本机内容变了：稍等一下（连续改动合并成一次）再写到 iCloud。
    private func localChanged() {
        guard !isApplyingRemote else { return }
        localUpdatedAt = clock.now()
        guard enabled else { return }
        let session = sessionGeneration
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await self?.clock.sleep(1)
            guard let self, self.isCurrentSession(session) else { return }
            // 写之前再读一次本机内容：这期间应用过云端的改动时，就不会把旧内容写回去。
            if SyncRules.shouldPush(local: self.currentContent, lastSynced: self.lastSynced) {
                _ = await self.push()
            }
        }
    }

    @discardableResult
    func push() async -> Bool {
        let session = sessionGeneration
        guard isCurrentSession(session) else { return false }
        guard let url = fileURL else {
            status = .unavailable
            return false
        }
        let content = currentContent
        let document = localDocument
        let base = lastSynced
        let operation = beginOperation(in: session)
        do {
            let written = try await files.merge(document, base, url)
            guard isCurrent(operation) else { return false }
            // 写文件期间又编辑了：把这些新改动也保留，下一次推送再写回去。
            let result = currentContent == content ? written.content
                : SyncMerge.threeWay(base: content, local: localDocument, remote: written).content
            if result != currentContent { applyRemote(result) }
            lastSynced = written.content
            lastStamp = nil
            status = .synced(written.updatedAt, written.device)
            Log.info("iCloud 同步：已写入本机的自选和设置（\(written.content.watchlist.count) 只）")
            if currentContent != written.content { localChanged() }
            return true
        } catch {
            guard isCurrent(operation) else { return false }
            status = .error(L("写入 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：写入失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 云端改动

    private func readCloud() async throws -> SyncDocument? {
        guard let url = fileURL else { throw SyncError.unavailable }
        let base = lastSynced
        return try await files.read(url, base)
    }

    /// 文件变了才真正去读。
    private func pullIfChanged() {
        guard enabled, let url = fileURL else { return }
        let stamp = CloudFile.stamp(of: url)
        guard stamp != lastStamp || lastSynced == nil else { return }
        let session = sessionGeneration
        pullTask?.cancel()
        pullTask = Task { @MainActor [weak self] in
            // 等一下：iCloud 写文件常常是几次连续的改动。
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.isCurrentSession(session) else { return }
            _ = await self.pull()
        }
    }

    @discardableResult
    func pull() async -> Bool {
        let session = sessionGeneration
        guard isCurrentSession(session) else { return false }
        let operation = beginOperation(in: session)
        lastPull = clock.now()
        let stampBeforeRead = fileURL.flatMap(CloudFile.stamp(of:))
        do {
            let remote = try await readCloud()
            guard isCurrent(operation) else { return false }
            guard let remote else {
                // 云端还没有文件（第一次，或者被删了）：把本机的放上去。
                return await push()
            }
            lastStamp = stampBeforeRead
            if SyncRules.shouldApply(remote: remote.content, local: currentContent, lastSynced: lastSynced) {
                let merged = lastSynced.map { SyncMerge.threeWay(base: $0, local: localDocument, remote: remote) } ?? remote
                applyRemote(merged.content)
                Log.info("iCloud 同步：应用了来自 \(remote.device) 的改动（\(merged.content.watchlist.count) 只）")
            }
            lastSynced = remote.content
            status = .synced(remote.updatedAt, remote.device)
            // iCloud 没变而本机变了（上次改完没来得及写上去），或者云端文件缺了一些设置：把本机的写上去。
            if SyncRules.shouldPush(local: currentContent, lastSynced: lastSynced) {
                return await push()
            }
            return true
        } catch {
            guard isCurrent(operation) else { return false }
            status = .error(L("读取 iCloud 失败：%@", error.localizedDescription))
            Log.error("iCloud 同步：读取失败：\(error.localizedDescription)")
            return false
        }
    }

    private func applyRemote(_ content: SyncContent) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        unknownWatchItems = content.unknownWatchItems
        store.replaceWatchlist(content.watchlist)
        settings.apply(content.settings)
    }

    // 同一会话内较新的读写也会淘汰旧结果；文件副作用与主线程状态生效分开。
    @discardableResult
    private func invalidateSession() -> Int {
        sessionGeneration &+= 1
        operationGeneration &+= 1
        lookupGeneration &+= 1
        pushTask?.cancel()
        pushTask = nil
        pullTask?.cancel()
        pullTask = nil
        choiceTask?.cancel()
        choiceTask = nil
        containerLookup?.cancel()
        containerLookup = nil
        stopWatching()
        pending = nil
        lastStamp = nil
        lastPull = .distantPast
        return sessionGeneration
    }

    private func isCurrentSession(_ session: Int, requiresEnabled: Bool = true) -> Bool {
        session == sessionGeneration && (!requiresEnabled || enabled) && !Task.isCancelled
    }

    private func beginOperation(in session: Int) -> Operation {
        operationGeneration &+= 1
        return Operation(session: session, generation: operationGeneration)
    }

    private func isCurrent(_ operation: Operation, requiresEnabled: Bool = true) -> Bool {
        isCurrentSession(operation.session, requiresEnabled: requiresEnabled)
            && operation.generation == operationGeneration
    }

    // MARK: - 监听

    private func startWatching() {
        guard watchesChanges else { return }
        let session = sessionGeneration
        stopWatching()
        guard let folder = folderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentSession(session) else { return }
                    self.pullIfChanged()
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        } else {
            Log.error("iCloud 同步：无法监听文件夹，改为定时检查")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentSession(session) else { return }
                self.pullIfChanged()
            }
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        timer?.invalidate()
        timer = nil
    }
}
