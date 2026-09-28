import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import StoxCore

@main
struct StoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 纯菜单栏 App 不需要窗口。Settings 场景只是为了满足 App 协议，设置入口在面板里。
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var store = QuoteStore(settings: settings)
    private var statusController: StatusItemController?
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist 里已设置 LSUIElement；这里再设一次，保证 `swift run` 直接运行时也不出现 Dock 图标。
        NSApp.setActivationPolicy(.accessory)

        let controller = StatusItemController(store: store, settings: settings)
        statusController = controller

        Notifier.shared.setUp()
        Notifier.shared.onOpen = { [weak self] in self?.statusController?.showPopover() }
        store.onAlert = { [weak self] trigger in
            guard let self, self.settings.alertsEnabled else { return }
            Notifier.shared.post(trigger)
        }
        store.start()

        settings.$hotKeyEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.setHotKey(enabled: enabled) }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    /// 全局快捷键 ⌃⌥S：在任何 App 里一键打开 / 关闭面板。
    private func setHotKey(enabled: Bool) {
        hotKey = nil
        guard enabled else { return }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.statusController?.togglePopover()
        }
    }

    // 睡眠时停止轮询，唤醒后立即刷新一次。
    @objc private func systemWillSleep(_ notification: Notification) {
        store.stop()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        store.restart()
    }
}
