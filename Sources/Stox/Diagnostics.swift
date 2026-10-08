import Foundation

/// 诊断只读取运行状态和日志，不读取自选、持仓、交易或金额。
enum Diagnostics {
    struct Snapshot: Sendable {
        let version: String
        let channel: String
        let osVersion: String
        let syncEnabled: Bool
        let syncState: String
        let source: String
    }

    @MainActor
    static func snapshot(store: QuoteStore, sync: SyncManager) -> Snapshot {
        let state: String
        switch sync.status {
        case .off: state = "off"
        case .unavailable: state = "unavailable"
        case .syncing: state = "syncing"
        case .synced: state = "synced"
        case .error: state = "error"
        }
        return Snapshot(version: AppInfo.version, channel: AppInfo.flavor == "appstore" ? "App Store" : "GitHub",
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        syncEnabled: sync.enabled, syncState: state,
                        source: store.usingBackup ? "Sina" : "Tencent")
    }

    static func report(_ snapshot: Snapshot, logs: [String]) -> String {
        let lines = [
            "Stox \(snapshot.version) · \(snapshot.channel)",
            "macOS: \(snapshot.osVersion)",
            "Sync: \(snapshot.syncEnabled ? "enabled" : "disabled") · \(snapshot.syncState)",
            "Quote source: \(snapshot.source)",
            "Recent logs (message numbers, paths, links and financial data redacted):",
        ] + logs.suffix(200).map(redactLog)
        return lines.joined(separator: "\n")
    }

    /// 时间戳留作排查顺序；正文不保留任何数字，避免未知错误或旧日志泄露数量、金额。
    /// 明确的持仓内容整行去掉，包含中文数字的描述也不例外。
    static func redactLog(_ line: String) -> String {
        let prefix = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} (?:INFO|ERROR) "#
        let range = line.range(of: prefix, options: .regularExpression)
        let header = range.map { String(line[$0]) } ?? ""
        var message = range.map { String(line[$0.upperBound...]) } ?? line
        if message.range(of: #"(?i)持仓|金额|成本|盈亏|交易|数量|shares?|quantity|holdings?|amount|cost|profit|balance|positions?"#, // l10n-ignore
                         options: .regularExpression) != nil {
            return header + "[financial data redacted]"
        }
        // 路径、链接和数值只处理正文；多行错误也按每行单独脱敏。
        for pattern in [#"(?i)https?://\S+"#, #"(?:/Users/|/Volumes/|file://|/var/|/private/)[^\s）)]+"#, #"[+-]?\p{N}+(?:[.,]\p{N}+)*"#] { // l10n-ignore
            message = message.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return header + message
    }

    static func feedbackURL(version: String, osVersion: String) -> URL {
        var url = URLComponents(string: "https://github.com/whrss9527/stox/issues/new")!
        url.queryItems = [URLQueryItem(name: "template", value: "bug.yml"),
                          URLQueryItem(name: "version", value: "Stox \(version); macOS \(osVersion)")]
        // 表单查询把 + 当作空格，版本的构建标记需要保留字面加号。
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!
    }
}
