import AppKit
import Carbon.HIToolbox
import Combine
import StoxCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 只有菜单栏图标，不在 Dock 里显示。Info.plist 里也设了 LSUIElement，这里再设一次，`swift run` 直接运行时同样生效。
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let settings = SettingsStore()
    private lazy var store = QuoteStore(settings: settings)
    private let updater = Updater()
    private lazy var sync = SyncManager(store: store, settings: settings)
    private var statusController: StatusItemController?
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        MainMenu.install(updater: updater)
        let controller = StatusItemController(store: store, settings: settings, updater: updater, sync: sync)
        statusController = controller
        SettingsWindowController.shared.configure(settings: settings, store: store, updater: updater, sync: sync)

        Notifier.shared.setUp()
        Notifier.shared.onOpen = { [weak self] route in
            if route == Notifier.aboutRoute {
                SettingsWindowController.shared.show(page: .about)
            } else {
                self?.statusController?.openPanel()
            }
        }
        store.onAlert = { [weak self] trigger in
            guard let self, self.settings.alertsEnabled else { return }
            Notifier.shared.post(trigger)
        }
        updater.notify = { title, body in
            Notifier.shared.postUpdate(title: title, body: body)
        }
        updater.onRelaunch = {
            NSApp.terminate(nil)
        }

        store.start()
        sync.start()
        updater.startAutomaticChecks { [weak self] in
            self?.settings.autoCheckUpdates ?? false
        }

        settings.$hotKeyEnabled.combineLatest(settings.$toggleHotkey)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, binding in self?.setHotKey(enabled: enabled, binding: binding) }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        Log.info("Stox 已启动，版本 \(AppInfo.version)（\(Bundle.main.bundleURL.path)）")
        handleLaunchArguments()
    }

    /// 再次打开程序（在访达里双击）时打开设置。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(page: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        sync.flushBeforeQuit()
        Log.info("Stox 已退出")
        Log.flush()
    }

    /// kill、终端里 Ctrl+C 这类信号也走正常退出，没写上去的 iCloud 改动会先写完。
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// 全局快捷键（默认 ⌃⌥S）：在任何 App 里一键打开或关闭面板。被其他程序占用时在设置里提示。
    private func setHotKey(enabled: Bool, binding: HotkeyBinding) {
        hotKey = nil
        guard enabled else {
            settings.hotkeyUnavailable = false
            return
        }
        hotKey = HotKey(keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak self] in
            self?.statusController?.togglePanel()
        }
        settings.hotkeyUnavailable = hotKey == nil
        if hotKey == nil {
            Log.error("快捷键 \(binding.display) 注册失败，可能已被其他程序占用")
        }
    }

    // 睡眠时停止轮询，唤醒后立即刷新一次，顺便看看 iCloud 里有没有别的 Mac 的改动。
    @objc private func systemWillSleep(_ notification: Notification) {
        store.stop()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        store.restart()
        sync.panelWillOpen()
    }

    /// 调试和 CI 用的启动参数：
    ///   Stox --show-panel [--expand sh600519] [--search 腾讯]   打开面板并打印诊断信息
    ///   Stox --show-settings [general|display|sync|about]      打开设置窗口并打印窗口位置
    ///   Stox --check-update                                    先检查一次更新再打开上面两者
    ///   Stox --install-update                                  检查并直接安装新版本
    private func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("--") ? nil : next
        }
        let showPanel = arguments.contains("--show-panel")
        let showSettings = arguments.contains("--show-settings")
        let checkUpdate = arguments.contains("--check-update")
        let installUpdate = arguments.contains("--install-update")
        guard showPanel || showSettings || checkUpdate || installUpdate else { return }
        let page = value(after: "--show-settings").flatMap(SettingsPage.init(rawValue:))
        let expand = value(after: "--expand").flatMap { Symbol($0) }
        let search = value(after: "--search")

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            if installUpdate {
                await self.updater.checkAndInstall()
                return
            }
            if checkUpdate {
                await self.updater.check(manual: true)
            }
            if showSettings {
                SettingsWindowController.shared.show(page: page ?? .general)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                SettingsWindowController.shared.printDiagnostics()
            } else if showPanel {
                self.statusController?.openPanel(expand: expand, search: search, printDiagnostics: true)
            }
        }
    }
}
