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
    public static func largeNumber(_ value: Double, decimals: Int = 2) -> String {
        let magnitude = abs(value)
        if magnitude >= 1e12 { return fixed(value / 1e12, decimals: decimals) + "万亿" }
        if magnitude >= 1e8 { return fixed(value / 1e8, decimals: decimals) + "亿" }
        if magnitude >= 1e4 { return fixed(value / 1e4, decimals: decimals) + "万" }
        return fixed(value, decimals: 0)
    }

    /// 成交量：A 股按“手”显示，港美股按“股”显示。
    public static func volume(_ shares: Double, market: Market) -> String {
        guard shares > 0 else { return "--" }
        if market.region == .cn { return largeNumber(shares / 100) + "手" }
        return largeNumber(shares) + "股"
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
