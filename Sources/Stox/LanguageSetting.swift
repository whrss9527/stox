import AppKit
import StoxCore

/// 设置里的“界面语言”：读写 Stox 自己的偏好设置里的 `AppleLanguages`，并能重新启动 Stox。
/// GitHub 版和 App Store 版（沙盒）一样可用，不用 Shell。
@MainActor
enum LanguageSetting {
    /// 偏好设置里现在存的选择（只看 Stox 自己的偏好设置，不看启动参数里的 -AppleLanguages 和系统语言）。
    static var current: InterfaceLanguage {
        guard let domain = Bundle.main.bundleIdentifier else {
            return InterfaceLanguage(appleLanguages: UserDefaults.standard.object(forKey: InterfaceLanguage.defaultsKey))
        }
        return InterfaceLanguage(appleLanguages: UserDefaults.standard.persistentDomain(forName: domain)?[InterfaceLanguage.defaultsKey])
    }

    /// 这次启动时存的选择，界面语言是按它定的；和 current 不同时要重新启动才生效。
    static let atLaunch = current

    static func set(_ language: InterfaceLanguage) {
        if let languages = language.appleLanguages {
            UserDefaults.standard.set(languages, forKey: InterfaceLanguage.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: InterfaceLanguage.defaultsKey)
        }
        Log.info("界面语言改为 \(language.rawValue)，重新启动后生效")
    }

    /// 打开一个新的 Stox，等它启动了再退出自己；新的会先等这个退出（见 waitForPreviousInstance）。
    static func relaunch(onError: @escaping @MainActor (String) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = Relaunch.arguments(waitingFor: ProcessInfo.processInfo.processIdentifier)
        Log.info("重新启动 Stox 以切换界面语言")
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    Log.error("重新启动失败：\(error.localizedDescription)")
                    onError(error.localizedDescription)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// 由“立即重新启动”打开的新实例：先等旧的退出（最多 15 秒），再开始建菜单栏图标、注册快捷键。
    /// kill(pid, 0) 在沙盒里对别的进程可能返回 EPERM，只把 ESRCH（没有这个进程）当作已经退出。
    nonisolated static func waitForPreviousInstance(arguments: [String]) {
        guard let pid = Relaunch.pidToWait(in: arguments), pid != getpid() else { return }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if kill(pid, 0) == -1, errno == ESRCH { return }
            usleep(100_000)
        }
        Log.error("等了 15 秒，旧的 Stox（\(pid)）还没有退出")
    }
}
