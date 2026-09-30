import Foundation

/// 界面文字的翻译。
///
/// 代码里写的是中文原文，它同时是 `Resources/<语言>.lproj/Localizable.strings` 里的键；
/// App 运行时按系统语言查 Stox.app 里的翻译表，命令行工具和单元测试里没有翻译表，原样返回中文。
/// 带参数的文字用 `%@` 占位（按顺序），译文里可以用 `%1$@`、`%2$@` 调换顺序：
/// `L("%@ 涨停", name)`。参数一律按字符串插值的写法转成文字，所以数字的格式和原来一样。
///
/// 所有显示给用户的中文都要经过它（`scripts/check-localization.py` 会检查）；
/// SwiftUI 的 `Text("…")` 也写成 `Text(L("…"))`，不依赖 SwiftUI 自己的查表。
public func L(_ key: String, _ arguments: Any...) -> String {
    let template = AppLanguage.bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return template }
    return AppLanguage.format(template, arguments.map { "\($0)" })
}

public enum AppLanguage {
    /// 查翻译表的 bundle，App 里就是 Stox.app。
    public static let bundle = Bundle.main

    /// 界面用的是不是英文（大数用 K、M、B 而不是万、亿）。启动后不变，只算一次。
    public static let isEnglish: Bool =
        bundle.preferredLocalizations.first?.hasPrefix("en") == true
            && bundle.path(forResource: "Localizable", ofType: "strings") != nil

    /// 日期、相对时间和界面用同一种语言（中文界面下是中文的“9月30日”“3分钟前”）。
    public static var locale: Locale {
        Locale(identifier: isEnglish ? "en" : "zh_CN")
    }

    /// 月份的名字：中文界面是 `9月`，英文界面是 `Sep`（full 时是 `September`）。
    public static func monthName(_ month: Int, full: Bool = false) -> String {
        guard isEnglish else { return "\(month)月" }  // l10n-ignore
        let formatter = DateFormatter()
        formatter.locale = locale
        let names = (full ? formatter.standaloneMonthSymbols : formatter.shortStandaloneMonthSymbols) ?? []
        return names.indices.contains(month - 1) ? names[month - 1] : "\(month)"
    }

    /// 年和月：中文界面是 `2026年9月`，英文界面是 `September 2026`。
    public static func monthTitle(year: Int, month: Int) -> String {
        isEnglish ? "\(monthName(month, full: true)) \(year)" : "\(year)年\(month)月"  // l10n-ignore
    }

    /// 把 `%@` 和 `%1$@` 这样的占位换成参数；别的 `%` 原样保留（比如 `涨幅达到 %@%`）。
    public static func format(_ template: String, _ arguments: [String]) -> String {
        var output = ""
        var next = 0
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            output += rest[..<percent]
            let after = rest[rest.index(after: percent)...]
            if after.hasPrefix("@") {
                output += next < arguments.count ? arguments[next] : ""
                next += 1
                rest = after.dropFirst()
                continue
            }
            let digits = after.prefix(while: \.isNumber)
            let tail = after.dropFirst(digits.count)
            if !digits.isEmpty, tail.hasPrefix("$@"), let position = Int(digits) {
                output += arguments.indices.contains(position - 1) ? arguments[position - 1] : ""
                rest = tail.dropFirst(2)
                continue
            }
            output += "%"
            rest = after
        }
        return output + rest
    }
}
