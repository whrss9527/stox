import Foundation

/// 行情数字的显示格式。不做千分位分组，保持和券商软件一致的紧凑写法。
public enum QuoteFormatter {
    public static func price(_ value: Double, decimals: Int) -> String {
        guard value > 0 else { return "--" }
        return fixed(value, decimals: decimals)
    }

    /// 带正负号的涨跌额：`+2.58`、`-0.01`、`0.00`。
    public static func change(_ value: Double, decimals: Int) -> String {
        signed(value, decimals: decimals)
    }

    /// 带正负号的涨跌幅：`+0.21%`、`-1.61%`、`0.00%`。
    public static func percent(_ value: Double) -> String {
        signed(value, decimals: 2) + "%"
    }

    /// 用万、亿、万亿表示的大数：`27.83亿`、`992.57万`。
    /// 英文界面用 K、M、B、T：`2.78B`、`9.93M`。
    public static func largeNumber(_ value: Double, decimals: Int = 2) -> String {
        let magnitude = abs(value)
        if AppLanguage.isEnglish {
            if magnitude >= 1e12 { return fixed(value / 1e12, decimals: decimals) + "T" }
            if magnitude >= 1e9 { return fixed(value / 1e9, decimals: decimals) + "B" }
            if magnitude >= 1e6 { return fixed(value / 1e6, decimals: decimals) + "M" }
            if magnitude >= 1e4 { return fixed(value / 1e3, decimals: decimals) + "K" }
            return fixed(value, decimals: 0)
        }
        if magnitude >= 1e12 { return fixed(value / 1e12, decimals: decimals) + "万亿" }  // l10n-ignore
        if magnitude >= 1e8 { return fixed(value / 1e8, decimals: decimals) + "亿" }  // l10n-ignore
        if magnitude >= 1e4 { return fixed(value / 1e4, decimals: decimals) + "万" }  // l10n-ignore
        return fixed(value, decimals: 0)
    }

    /// 金额（市值、盈亏）：10 万以内保留两位小数，更大的用万、亿表示：`3958.00`、`12.40万`。
    public static func money(_ value: Double) -> String {
        let magnitude = abs(value)
        if AppLanguage.isEnglish {
            if magnitude >= 1e9 { return fixed(value / 1e9, decimals: 2) + "B" }
            if magnitude >= 1e6 { return fixed(value / 1e6, decimals: 2) + "M" }
            if magnitude >= 1e5 { return fixed(value / 1e3, decimals: 2) + "K" }
            return fixed(value, decimals: 2)
        }
        if magnitude >= 1e8 { return fixed(value / 1e8, decimals: 2) + "亿" }  // l10n-ignore
        if magnitude >= 1e5 { return fixed(value / 1e4, decimals: 2) + "万" }  // l10n-ignore
        return fixed(value, decimals: 2)
    }

    /// 带正负号的金额，用于盈亏：`+3958.00`、`-12.40万`、`0.00`。
    public static func signedMoney(_ value: Double) -> String {
        if abs(value) < 0.005 { return fixed(0, decimals: 2) }
        return (value > 0 ? "+" : "") + money(value)
    }

    /// 带正负号的大数，用于资金流向：`+2.48亿`、`-2675.37万`、`0`。
    public static func signedLargeNumber(_ value: Double) -> String {
        guard abs(value) >= 0.5 else { return "0" }
        return (value > 0 ? "+" : "-") + largeNumber(abs(value))
    }

    /// 打开“隐藏金额”时，市值、盈亏金额和持有数量都换成它；比例照常显示。
    public static let hiddenAmount = "****"

    /// 菜单栏里的金额，越短越好：100 以内两位小数，1 万以内取整，更大的用万、亿：`12.90`、`688`、`1.20万`。
    public static func compactMoney(_ value: Double) -> String {
        let magnitude = abs(value)
        if AppLanguage.isEnglish {
            if magnitude >= 1e9 { return fixed(value / 1e9, decimals: 2) + "B" }
            if magnitude >= 1e6 { return fixed(value / 1e6, decimals: 2) + "M" }
            if magnitude >= 1e4 { return fixed(value / 1e3, decimals: 2) + "K" }
            if magnitude >= 100 { return fixed(value, decimals: 0) }
            return fixed(value, decimals: 2)
        }
        if magnitude >= 1e8 { return fixed(value / 1e8, decimals: 2) + "亿" }  // l10n-ignore
        if magnitude >= 1e4 { return fixed(value / 1e4, decimals: 2) + "万" }  // l10n-ignore
        if magnitude >= 100 { return fixed(value, decimals: 0) }
        return fixed(value, decimals: 2)
    }

    /// 不带多余零的数字，用于股数和输入框里的价格：`100`、`2.5`、`1234.5678`，最多 4 位小数。
    public static func plain(_ value: Double) -> String {
        if value == value.rounded() { return String(format: "%.0f", value) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// 成交量：A 股按“手”显示，港美股按“股”显示。
    public static func volume(_ shares: Double, market: Market) -> String {
        guard shares > 0 else { return "--" }
        if market.region == .cn { return L("%@手", largeNumber(shares / 100)) }
        return L("%@股", largeNumber(shares))
    }

    public static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func signed(_ value: Double, decimals: Int) -> String {
        let threshold = 0.5 * pow(10, -Double(decimals))
        if abs(value) < threshold { return fixed(0, decimals: decimals) }
        return (value > 0 ? "+" : "") + fixed(value, decimals: decimals)
    }

    /// 固定小数位，不带正负号。
    public static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(max(0, min(decimals, 6)))f", value)
    }
}

/// 菜单栏上显示的简称：中文按 2 个宽度、ASCII 按 1 个宽度计，超出截断。
public enum NameAbbreviator {
    public static func abbreviate(_ name: String, maxWidth: Int = 8) -> String {
        var width = 0
        var output = ""
        for character in name.trimmingCharacters(in: .whitespaces) {
            let w = character.isASCII ? 1 : 2
            if width + w > maxWidth { break }
            width += w
            output.append(character)
        }
        return output
    }
}
