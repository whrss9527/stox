import AppKit
import Carbon.HIToolbox
import ServiceManagement
import StoxCore
import UserNotifications

/// 价格提醒和新版本的系统通知。
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let routeKey = "route"
    static let aboutRoute = "about"

    /// 点击通知时调用：价格提醒打开面板，新版本通知打开“关于与更新”。
    var onOpen: ((String?) -> Void)?

    /// 通知中心要求进程是一个 .app 包；`swift run` 直接运行可执行文件时调用会崩溃，所以先判断。
    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func setUp() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ trigger: AlertTrigger) {
        guard isAvailable else {
            NSSound.beep()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = trigger.title
        content.body = trigger.body
        content.sound = .default
        let identifier = "\(trigger.symbol.rawValue).\(trigger.condition.rawValue).\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// 收盘小结，点击后打开面板。
    func postSummary(_ note: CloseSummaryNote) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        let request = UNNotificationRequest(identifier: "summary.\(note.region.rawValue).\(note.day)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// 发现新版本时的通知，点击后打开“关于与更新”。
    func postUpdate(title: String, body: String) {
        guard isAvailable else { return }
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.routeKey: Self.aboutRoute]
        let request = UNNotificationRequest(identifier: "update.\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // 菜单栏 App 常处于“前台”，需要显式要求系统照常弹出横幅。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = response.notification.request.content.userInfo[Notifier.routeKey] as? String
        Task { @MainActor in
            Notifier.shared.onOpen?(route)
        }
        completionHandler()
    }
}

/// 开机自启动（macOS 13+ 的 SMAppService）。
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// 基于 Carbon RegisterEventHotKey 的全局快捷键，不需要“辅助功能”权限。
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return OSStatus(noErr)
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        guard installStatus == OSStatus(noErr) else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_4F58), id: 1)  // 'STOX'
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == OSStatus(noErr) else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
