import AppKit
import Carbon.HIToolbox
import ServiceManagement
import StoxCore
import UserNotifications

/// 价格提醒和新版本的系统通知。
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// CI 用：环境变量指定通知权限（比如 denied），不去读系统的，用来截“通知已关闭”的提示。
    nonisolated static let testPermissionVariable = "STOX_TEST_NOTIFICATIONS"
    /// 通知回调在主线程以外被调用时也要读它，所以不隔离在主线程上。
    nonisolated static let routeKey = "route"
    static let aboutRoute = "about"
    /// 价格提醒的 route 是这个前缀加代码，点了打开面板并展开这一只。
    static let symbolRoutePrefix = "symbol:"

    /// 点击通知时调用：价格提醒打开面板并展开那一只，收盘小结打开面板，新版本通知打开“关于与更新”。
    var onOpen: ((String?) -> Void)?

    /// 系统给的通知权限。启动时、打开面板时、App 回到前台时、请求授权以后和通知发不出去时都重新读一次，
    /// 用户在系统设置里关掉通知再回来，设置、编辑页和面板上的提示跟着变。
    @Published private(set) var permission: NotificationPermission = .unknown
    private let testPermission = ProcessInfo.processInfo.environment[Notifier.testPermissionVariable]
        .flatMap(NotificationPermission.init(rawValue:))
    private var activeObserver: NSObjectProtocol?

    /// 通知中心要求进程是一个 .app 包；`swift run` 直接运行可执行文件时调用会崩溃，所以先判断。
    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func setUp() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshPermission()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Notifier.shared.refreshPermission() }
        }
    }

    /// 重新读一次通知权限。
    func refreshPermission() {
        if let testPermission {
            permission = testPermission
            return
        }
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
            let permission = NotificationPermission(settings.authorizationStatus)
            Task { @MainActor in
                let notifier = Notifier.shared
                if notifier.permission != permission {
                    Log.info("通知权限：\(permission.rawValue)")
                    notifier.permission = permission
                }
            }
        }
    }

    /// 还没问过时弹出系统的询问；问过了系统不会再问，结果都会重新读进 permission。
    func requestAuthorization() {
        guard isAvailable, testPermission == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            if let error {
                Log.error("请求通知权限失败：\(error.localizedDescription)")
            } else if !granted {
                Log.info("没有得到通知权限，提醒发不出来")
            }
            Task { @MainActor in Notifier.shared.refreshPermission() }
        }
    }

    /// 打开系统设置的通知页，在那里找到 Stox 打开“允许通知”。
    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
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
        content.userInfo = [Self.routeKey: Self.symbolRoutePrefix + trigger.symbol.rawValue]
        let identifier = "\(trigger.symbol.rawValue).\(trigger.condition.rawValue).\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            // 通知被关掉时系统不弹也不告诉用户：记一笔，再读一次权限，面板上会提示。
            guard let error else { return }
            Log.error("提醒没有发出去：\(error.localizedDescription)")
            Task { @MainActor in Notifier.shared.refreshPermission() }
        }
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

extension NotificationPermission {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = .authorized  // authorized、provisional
        }
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
