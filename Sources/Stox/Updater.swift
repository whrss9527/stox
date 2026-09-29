import AppKit
import Combine
import StoxCore

/// 程序的版本和链接。
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static let repositoryURL = URL(string: "https://github.com/\(UpdateCheck.repository)")!
    static let issuesURL = URL(string: "https://github.com/\(UpdateCheck.repository)/issues")!
}

/// 更新：检查 GitHub 上的新版本，下载、校验、替换程序并重新启动。状态只在主线程上改，界面直接观察它。
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// 有新版本，但用户选择过跳过它。
        case skipped(ReleaseInfo)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double?)
        case verifying(ReleaseInfo)
        case installing(ReleaseInfo)
        case relaunching(ReleaseInfo)
        case failed(ReleaseInfo, String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?
    /// 有新版本、又隔了不止一个版本时，从现在的版本到新版本之间每个版本的更新内容（从新到旧）；否则是 nil，用新版本自己的。
    @Published private(set) var notesSinceCurrent: String?
    private var notesTask: Task<Void, Never>?
    /// 最近一次手动检查失败的原因。
    @Published private(set) var checkError: String?
    /// 最近一次安装失败的原因，界面据此给出对应的按钮。
    @Published private(set) var lastFailure: UpdateError?

    /// 自动检查发现新版本时通知（标题、正文）。
    var notify: ((String, String) -> Void)?
    /// 新程序已经换好，该退出了。
    var onRelaunch: (() -> Void)?

    static let checkInterval: TimeInterval = 6 * 3600
    private static let skippedKey = "update.skippedVersion"
    private static let notifiedKey = "update.notifiedVersion"

    private let defaults: UserDefaults
    private var timer: Timer?
    private var installTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 发现的新版本（含正在安装和安装失败的），跳过的不算。
    var release: ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .verifying(let release),
             .installing(let release), .relaunching(let release), .failed(let release, _):
            return release
        case .idle, .checking, .upToDate, .skipped:
            return nil
        }
    }

    var isInstalling: Bool {
        switch phase {
        case .downloading, .verifying, .installing, .relaunching: return true
        default: return false
        }
    }

    /// 更新装到哪里。启动后不会变，算一次就够。
    private(set) lazy var plan: InstallPlan? = AppLocation.currentPlan()

    /// 没法在程序里更新的原因：只有不是从 .app 运行（开发时 swift run）才会这样。
    var installProblem: String? {
        plan == nil ? "不是从 Stox.app 运行的，没法在程序里更新" : nil
    }

    /// 从下载文件夹这类临时位置运行时，更新会装进“应用程序”。
    var relocationNote: String? {
        guard let plan, plan.relocating else { return nil }
        let folder = AppLocation.displayName(of: plan.target.deletingLastPathComponent())
        return "现在是从下载文件夹这类临时位置运行的，这次会装进\(folder)" + (plan.trashAfter == nil ? "" : "，旧的那份移到废纸篓")
    }

    private var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedKey) }
        set { defaults.set(newValue, forKey: Self.skippedKey) }
    }

    // MARK: - 检查

    /// 启动几秒后检查一次，之后每 6 小时一次；enabled 返回 false 时不检查。
    func startAutomaticChecks(enabled: @escaping @MainActor () -> Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if enabled() { await self?.check(manual: false) }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if enabled() { await self?.check(manual: false) }
        }
    }

    /// 取中间各个版本的更新内容。取不到时只显示新版本自己的，不影响更新。
    private func loadNotes(since current: String, upTo latest: String) async {
        do {
            let all = try await UpdateCheck.releases(count: 30, currentVersion: current)
            let range = UpdateCheck.releases(all, after: current, upTo: latest)
            guard !Task.isCancelled else { return }
            notesSinceCurrent = range.count > 1 ? ReleaseNotesText.combined(range, limit: 6) : nil
        } catch {
            Log.info("取各个版本的更新内容失败：\(error.localizedDescription)")
            notesSinceCurrent = nil
        }
    }

    /// 检查一次。manual 表示用户点的：失败要显示，跳过的版本也显示。返回发现的新版本。
    @discardableResult
    func check(manual: Bool) async -> ReleaseInfo? {
        if isInstalling { return release }
        if case .checking = phase { return nil }
        let previous = phase
        phase = .checking
        checkError = nil
        let current = AppInfo.version
        do {
            let latest = try await UpdateCheck.latest(currentVersion: current)
            lastChecked = Date()
            guard UpdateCheck.isNewer(latest.version, than: current) else {
                Log.info("检查更新：当前 \(current) 已是最新（最新发布 \(latest.version)）")
                phase = .upToDate
                return nil
            }
            if !manual, latest.version == skippedVersion {
                Log.info("检查更新：有新版本 \(latest.version)，之前选择过跳过")
                phase = .skipped(latest)
                return nil
            }
            Log.info("检查更新：有新版本 \(latest.version)（当前 \(current)）")
            phase = .available(latest)
            // 各个版本的更新内容在后面慢慢取，不耽误检查和一键更新。
            notesTask?.cancel()
            notesTask = Task { [weak self] in
                await self?.loadNotes(since: current, upTo: latest.version)
            }
            if !manual, defaults.string(forKey: Self.notifiedKey) != latest.version {
                defaults.set(latest.version, forKey: Self.notifiedKey)
                notify?("Stox 有新版本 \(latest.version)", "打开行情面板点“更新”，自动下载安装并重新启动")
            }
            return latest
        } catch {
            Log.error("检查更新失败：\(error.localizedDescription)")
            phase = previous
            if manual {
                checkError = "检查更新失败：\(error.localizedDescription)"
            }
            return nil
        }
    }

    func skipAvailableVersion() {
        guard case .available(let release) = phase else { return }
        skippedVersion = release.version
        phase = .skipped(release)
    }

    /// 把跳过的版本重新拿出来看。
    func showSkippedVersion() {
        guard case .skipped(let release) = phase else { return }
        phase = .available(release)
    }

    // MARK: - 安装

    /// 下载并安装发现的新版本，完成后重新启动。
    func install() {
        guard let release, !isInstalling, installTask == nil else { return }
        lastFailure = nil
        if let problem = installProblem {
            phase = .failed(release, problem)
            return
        }
        guard release.canInstall else {
            lastFailure = .noArchive
            phase = .failed(release, UpdateError.noArchive.localizedDescription)
            return
        }
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.perform(release)
            } catch is CancellationError {
                Log.info("更新已取消")
                self.phase = .available(release)
            } catch {
                Log.error("更新到 \(release.version) 失败：\(error.localizedDescription)")
                self.lastFailure = error as? UpdateError
                self.phase = .failed(release, error.localizedDescription)
            }
            self.installTask = nil
        }
    }

    func cancel() {
        installTask?.cancel()
    }

    /// 检查并直接安装。已经知道有新版本时不再重复检查。
    func checkAndInstall() async {
        if case .skipped = phase {
            showSkippedVersion()
        }
        if release == nil {
            await check(manual: true)
        }
        install()
    }

    private func perform(_ release: ReleaseInfo) async throws {
        guard let plan else { throw UpdateError.notInstallable(installProblem ?? "") }
        guard let archiveURL = release.archiveURL else { throw UpdateError.noArchive }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("Stox-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let archive = workDir.appendingPathComponent(release.archiveName ?? UpdateCheck.archiveName)
        phase = .downloading(release, nil)
        Log.info("开始更新到 \(release.version)：下载 \(archiveURL.absoluteString)")
        try await UpdateInstaller.download(archiveURL, expectedSize: release.archiveSize, to: archive) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(release, fraction)
            }
        }
        try Task.checkCancellation()
        phase = .verifying(release)
        try await UpdateInstaller.verify(archive: archive, release: release)
        let app = try await UpdateInstaller.extract(archive: archive, to: workDir.appendingPathComponent("extracted", isDirectory: true))
        try await UpdateInstaller.validate(app: app, expectedVersion: release.version)
        try Task.checkCancellation()
        phase = .installing(release)
        try await UpdateInstaller.install(newApp: app, replacing: plan.target)
        if let old = plan.trashAfter {
            do {
                try fm.trashItem(at: old, resultingItemURL: nil)
                Log.info("已把旧版本 \(old.path) 移到废纸篓")
            } catch {
                Log.error("旧版本 \(old.path) 没能移到废纸篓：\(error.localizedDescription)")
            }
        }
        Log.info("已更新到 \(release.version)（\(plan.target.path)），重新启动")
        phase = .relaunching(release)
        UpdateInstaller.relaunch(plan.target)
        try? await Task.sleep(nanoseconds: 600_000_000)
        onRelaunch?()
    }
}
