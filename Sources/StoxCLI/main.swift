import Foundation
import StoxCore

// 命令行小工具：检查数据源、调试解析结果。
//
//   stox-cli quote sh600519 700 AAPL us.IXIC   解析并打印行情
//   stox-cli raw sh600519 hk00700              打印接口原始返回
//   stox-cli search 茅台                       搜索证券
//   stox-cli latest-release 0.1.0              查询 GitHub 上的最新发布，并和给定版本比较
//
// 有代码取不到行情、或搜索无结果时以非零状态退出，方便在 CI 里做冒烟测试。

func printUsage() {
    print("""
    用法:
      stox-cli quote <代码>...    例如 stox-cli quote sh600519 700 AAPL us.IXIC
      stox-cli raw <代码>...      打印接口原始返回
      stox-cli search <关键词>    例如 stox-cli search gzmt
      stox-cli latest-release [当前版本]   查询最新发布
    """)
}

func pad(_ text: String, _ width: Int) -> String {
    let w = text.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    return text + String(repeating: " ", count: max(0, width - w))
}

func parseSymbols(_ args: ArraySlice<String>) -> [Symbol] {
    args.map { arg in
        guard let symbol = SymbolInput.parse(arg) else {
            FileHandle.standardError.write("无法识别的代码：\(arg)\n".data(using: .utf8)!)
            exit(2)
        }
        return symbol
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    printUsage()
    exit(2)
}

let provider = TencentProvider()

do {
    switch command {
    case "quote":
        let symbols = parseSymbols(arguments.dropFirst())
        let quotes = try await provider.fetchQuotes(for: symbols)
        var missing = 0
        for symbol in symbols {
            guard let q = quotes[symbol] else {
                print("\(pad(symbol.rawValue, 10)) 无数据")
                missing += 1
                continue
            }
            let time = q.timestamp.map { QuoteFormatter.time($0, timeZone: symbol.market.region.timeZone) } ?? "--"
            let phase = MarketClock.effectivePhase(for: symbol.market.region, at: Date(), latestQuoteTime: q.timestamp)
            print([
                pad(symbol.rawValue, 10),
                pad(q.name, 18),
                pad(QuoteFormatter.price(q.price, decimals: q.priceDecimals), 11),
                pad(QuoteFormatter.change(q.change, decimals: q.priceDecimals), 10),
                pad(QuoteFormatter.percent(q.changePercent), 9),
                pad("量 " + QuoteFormatter.volume(q.volume, market: symbol.market), 16),
                pad("额 " + (q.amount > 0 ? QuoteFormatter.largeNumber(q.amount) : "--"), 13),
                pad(q.marketCap.map { "市值 " + QuoteFormatter.largeNumber($0) } ?? "", 14),
                "\(time) \(symbol.market.region.displayName)\(phase.displayName)",
            ].joined(separator: " "))
        }
        exit(missing == 0 ? 0 : 1)

    case "raw":
        print(try await provider.fetchRaw(for: parseSymbols(arguments.dropFirst())))

    case "search":
        let query = arguments.dropFirst().joined(separator: " ")
        let results = try await provider.search(query)
        for r in results {
            print("\(pad(r.symbol.rawValue, 12)) \(pad(r.name, 24)) \(r.typeLabel)")
        }
        exit(results.isEmpty ? 1 : 0)

    case "latest-release":
        let current = arguments.dropFirst().first ?? "0.0.0"
        let release = try await UpdateCheck.latest(currentVersion: current)
        let published = release.publishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "--"
        print("最新版本 \(release.tag)，发布于 \(published)")
        print("附件 \(release.archiveName ?? "无")，\(release.archiveSize ?? 0) 字节")
        let verification = release.checksumsURL != nil ? UpdateCheck.checksumsName : (release.archiveSHA256 != nil ? "附件摘要" : "无")
        print("校验方式 \(verification)")
        print(UpdateCheck.isNewer(release.version, than: current) ? "比 \(current) 新，可以更新" : "不比 \(current) 新")
        exit(release.canInstall ? 0 : 1)

    default:
        printUsage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write("请求失败：\(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
