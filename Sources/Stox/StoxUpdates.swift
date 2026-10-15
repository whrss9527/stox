#if !APP_STORE
import FritCore
import FritUpdate
import Foundation
import StoxCore
import SwiftUI

typealias Updater = FritUpdate.Updater
typealias UpdateSection = FritUpdate.UpdateSection

@MainActor
enum StoxUpdates {
    static func configuration(defaults: UserDefaults = .standard) -> UpdateConfiguration {
        FritLocalization.languageOverride = AppLanguage.isTraditionalChinese ? "zh-Hant" : (AppLanguage.isEnglish ? "en" : "zh-Hans")
        var configuration = UpdateConfiguration(repository: StoxReleaseFeed.repository, appName: "Stox", archive: .fixed("Stox.zip"))
        configuration.environmentPrefix = "STOX"
        configuration.defaults = defaults
        configuration.defaultsKeyPrefix = "update."
        configuration.checkInterval = 6 * 3600
        configuration.signer = .sameTeamAsCurrent
        configuration.log = UpdateLogger(info: { Log.info($0) }, error: { Log.error($0) })
        configuration.notes = .stox(language: AppLanguage.isEnglish ? .english : .chinese)
        return configuration
    }
}

extension FritUpdate.Updater {
    static let shared = FritUpdate.Updater(configuration: StoxUpdates.configuration())
}

/// 外层仍由面板注入同一个更新器，内部状态和操作采用共用视图。
@MainActor
struct UpdateBanner: View {
    @EnvironmentObject private var updater: Updater
    var openDetails: () -> Void
    var body: some View { FritUpdate.UpdateBanner(updater: updater, openDetails: openDetails) }
}
#endif
