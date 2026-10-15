import Foundation
import StoxCore

/// 程序的版本和链接；App Store 版不依赖自主更新模块。
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static let repositoryURL = URL(string: "https://github.com/\(StoxReleaseFeed.repository)")!
    static let issuesURL = URL(string: "https://github.com/\(StoxReleaseFeed.repository)/issues")!
    #if APP_STORE
    static let flavor = "appstore"
    #else
    static let flavor = "github"
    #endif
}
