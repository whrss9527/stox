import Foundation

/// 设置里选的界面语言。
///
/// 选了英文或简体中文时，把 `AppleLanguages` 写进 Stox 自己的偏好设置（和“系统设置 → 通用 → 语言与地区 → App”
/// 里给单个 App 选语言是同一个键）；跟随系统时删掉这个键。系统在启动时按它选翻译表，所以要重新启动才生效。
/// 只存在这台 Mac 上，不跟 iCloud 同步，也不写进备份。
public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese

    public var id: String { rawValue }

    /// 偏好设置里的键。
    public static let defaultsKey = "AppleLanguages"

    /// 从偏好设置里 `AppleLanguages` 的值还原。没有这个键是跟随系统；
    /// 在系统设置里给 Stox 选了别的语言（Stox 没有这种翻译，实际显示英文）也当作跟随系统，不去改它。
    public init(appleLanguages value: Any?) {
        let first = (value as? [String])?.first ?? (value as? String)
        guard let first else {
            self = .system
            return
        }
        let code = first.lowercased()
        if code == "en" || code.hasPrefix("en-") || code.hasPrefix("en_") {
            self = .english
        } else if code == "zh-hans" || code.hasPrefix("zh-hans-") || code == "zh-cn" || code == "zh_cn" || code == "zh" {
            self = .simplifiedChinese
        } else {
            self = .system
        }
    }

    /// 要写进偏好设置的 `AppleLanguages`，跟随系统时是 nil（删掉这个键）。
    public var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .english: return ["en"]
        case .simplifiedChinese: return ["zh-Hans"]
        }
    }

    /// 选项里显示的名字：语言用它自己的写法（英文界面里也写“简体中文”），方便看不懂当前界面的人找到。
    public var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"  // l10n-ignore
        }
    }
}

/// 重新启动：旧的 Stox 打开一个新的实例，参数里带上自己的进程号，然后退出；
/// 新的实例一开始先等旧的退出，免得两个同时在菜单栏里、抢同一个全局快捷键。
public enum Relaunch {
    public static let waitFlag = "--relaunch-after"

    /// 新实例的启动参数。
    public static func arguments(waitingFor pid: Int32) -> [String] {
        [waitFlag, String(pid)]
    }

    /// 从启动参数里取要等的进程号，没有就是 nil。
    public static func pidToWait(in arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: waitFlag), index + 1 < arguments.count,
              let pid = Int32(arguments[index + 1]), pid > 0 else { return nil }
        return pid
    }
}
