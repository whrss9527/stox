import AppIntents
import Foundation
import StoxCore

@MainActor
enum StoxIntentSupport {
    /// AppDelegate与快捷指令共用队列，冷启动时先收下，初始化后再打开面板。
    static let links = StoxLinkInbox()

    static func price(code: String) async throws -> Double {
        try await price(code: code, fetch: liveQuote)
    }

    static func price(code: String, fetch: (Symbol) async throws -> Quote?) async throws -> Double {
        try Task.checkCancellation()
        guard !code.isEmpty, code.utf8.count <= 64,
              !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let symbol = SymbolInput.parse(code) else { throw StoxIntentError.invalidSymbol }
        let quote = try await fetch(symbol)
        try Task.checkCancellation()
        guard let quote, quote.symbol == symbol, quote.price.isFinite else { throw StoxIntentError.noQuote }
        return quote.price
    }

    private static func liveQuote(_ symbol: Symbol) async throws -> Quote? {
        let result = try await QuoteFailover.fetchQuotes([symbol], primary: TencentProvider(), backup: SinaProvider())
        return result.quotes[symbol]
    }
}

enum StoxIntentError: Error, LocalizedError, Equatable {
    case invalidSymbol
    case noQuote

    var errorDescription: String? {
        switch self {
        case .invalidSymbol: return L("无法识别证券代码")
        case .noQuote: return L("未取得有效行情，请稍后重试")
        }
    }
}

struct QueryStockPriceIntent: AppIntent {
    static let title = LocalizedStringResource("查询证券价格")
    static let description = IntentDescription(LocalizedStringResource("输入证券代码，返回当前价格数值，供下一个快捷指令操作使用。"))

    @Parameter(title: LocalizedStringResource("证券代码"))
    var code: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        .result(value: try await StoxIntentSupport.price(code: code))
    }
}

struct OpenStoxPanelIntent: AppIntent {
    static let title = LocalizedStringResource("打开行情面板")
    static let description = IntentDescription(LocalizedStringResource("打开 Stox 的自选行情面板。"))
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        StoxIntentSupport.links.receive([URL(string: "stox://show")!])
        return .result()
    }
}

struct StoxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: QueryStockPriceIntent(), phrases: ["Get a price with \(.applicationName)"],
                    shortTitle: LocalizedStringResource("查询证券价格"), systemImageName: "chart.line.uptrend.xyaxis")
        AppShortcut(intent: OpenStoxPanelIntent(), phrases: ["Open \(.applicationName) panel"],
                    shortTitle: LocalizedStringResource("打开行情面板"), systemImageName: "list.bullet.rectangle")
    }
}
