import Foundation
import StoxCore

// 命令行小工具：检查数据源、调试解析结果。
//
//   stox-cli quote sh600519 700 AAPL us.IXIC   解析并打印行情
//   stox-cli sina sh600519 700 AAPL            用备用的新浪行情
//   stox-cli raw sh600519 hk00700              打印接口原始返回
//   stox-cli search 茅台                       搜索证券
//   stox-cli kline sh600519 week               打印最近几根 K 线（day、week、month）
//   stox-cli book sh600519                     打印 A 股的买卖五档和内外盘
//   stox-cli rank gainers 10                   打印 A 股涨跌榜（gainers、losers、turnover、industries）
//   stox-cli flow sh600519                     打印 A 股个股、ETF 当天的资金流向
//   stox-cli latest-release 0.1.0              查询 GitHub 上的最新发布，并和给定版本比较
//
// 有代码取不到行情、或搜索无结果时以非零状态退出，方便在 CI 里做冒烟测试。

func printUsage() {
    print("""
    用法:
      stox-cli quote <代码>...    例如 stox-cli quote sh600519 700 AAPL us.IXIC
      stox-cli sina <代码>...     用备用的新浪行情，格式同上
      stox-cli raw <代码>...      打印接口原始返回
      stox-cli search <关键词>    例如 stox-cli search gzmt
      stox-cli kline <代码> [day|week|month]   打印最近几根 K 线
      stox-cli book <代码>        打印 A 股的买卖五档和内外盘
      stox-cli rank [gainers|losers|turnover|industries] [数量]   打印 A 股涨跌榜
      stox-cli flow <代码>        打印 A 股个股、ETF 当天的资金流向
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
    case "quote", "sina":
        let symbols = parseSymbols(arguments.dropFirst())
        let source: QuoteProvider = command == "sina" ? SinaProvider() : provider
        let quotes = try await source.fetchQuotes(for: symbols)
        var missing = 0
        for symbol in symbols {
            guard let q = quotes[symbol] else {
                print("\(pad(symbol.rawValue, 10)) 无数据")
                missing += 1
                continue
            }
            let time = q.timestamp.map { QuoteFormatter.time($0, timeZone: symbol.market.region.timeZone) } ?? "--"
            let phase = MarketClock.effectivePhase(for: symbol.market.region, at: Date(), latestQuoteTime: q.timestamp)
            // 英文界面里的名称和菜单栏上的简称。
            let item = WatchItem(symbol: symbol, name: q.name)
            let english = EnglishName.name(symbol, quote: q).map { "  英文 \($0) [\(item.automaticTickerName(with: q, english: true))]" } ?? ""
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
            ].joined(separator: " ") + english)
        }
        exit(missing == 0 ? 0 : 1)

    case "raw":
        print(try await provider.fetchRaw(for: parseSymbols(arguments.dropFirst())))

    case "search":
        let query = arguments.dropFirst().joined(separator: " ")
        let results = try await provider.search(query)
        for r in results {
            let english = r.displayName(quote: nil, english: true)
            print("\(pad(r.symbol.rawValue, 12)) \(pad(r.name, 24)) \(r.typeLabel)" + (english == r.name ? "" : "  英文 \(english)"))
        }
        exit(results.isEmpty ? 1 : 0)

    case "kline":
        guard let symbol = parseSymbols(arguments.dropFirst().prefix(1)).first else {
            printUsage()
            exit(2)
        }
        let period = arguments.dropFirst(2).first.flatMap(KlinePeriod.init(rawValue:)) ?? .day
        guard let series = try await provider.fetchKline(for: symbol, period: period, count: 60, exchangeCode: nil),
              !series.candles.isEmpty
        else {
            print("\(symbol.rawValue) 没有 K 线数据")
            exit(1)
        }
        print("\(symbol.rawValue) \(period.rawValue) 共 \(series.candles.count) 根，\(series.candles[0].date) 到 \(series.candles[series.candles.count - 1].date)")
        for index in series.candles.indices.suffix(5) {
            let c = series.candles[index]
            let change = series.changePercent(at: index).map(QuoteFormatter.percent) ?? "--"
            print("  \(c.date)  开 \(c.open)  收 \(c.close)  高 \(c.high)  低 \(c.low)  \(change)")
        }

    case "book":
        guard let symbol = parseSymbols(arguments.dropFirst().prefix(1)).first else {
            printUsage()
            exit(2)
        }
        guard let quote = try await provider.fetchQuotes(for: [symbol])[symbol], let book = quote.orderBook else {
            print("\(symbol.rawValue) 没有五档（只有 A 股个股有）")
            exit(1)
        }
        let decimals = quote.priceDecimals
        func line(_ name: String, _ levels: [OrderBook.Level]) {
            for (index, level) in levels.enumerated() {
                print("  \(name)\(index + 1)  \(pad(QuoteFormatter.price(level.price, decimals: decimals), 10)) \(QuoteFormatter.plain(level.volume / 100)) 手")
            }
        }
        print("\(symbol.rawValue) \(quote.name) 现价 \(QuoteFormatter.price(quote.price, decimals: decimals))")
        line("卖", book.asks.reversed())
        line("买", book.bids)
        let imbalance = book.imbalance.map(QuoteFormatter.percent) ?? "--"
        let outer = book.outerVolume.map { QuoteFormatter.volume($0, market: symbol.market) } ?? "--"
        let inner = book.innerVolume.map { QuoteFormatter.volume($0, market: symbol.market) } ?? "--"
        print("  委比 \(imbalance)  外盘 \(outer)  内盘 \(inner)")
        exit(book.isEmpty ? 1 : 0)

    case "rank":
        let kind = arguments.dropFirst().first.flatMap(RankKind.init(rawValue:)) ?? .gainers
        let count = arguments.dropFirst(2).first.flatMap(Int.init) ?? 10
        if kind == .industries {
            let industries = try await provider.fetchIndustries(count: count) ?? []
            for (index, industry) in industries.enumerated() {
                let leader = industry.leader.map { "领涨 \($0.name) \(QuoteFormatter.percent($0.changePercent))" } ?? ""
                print("\(pad(String(index + 1), 3)) \(pad(industry.name, 12)) \(pad(QuoteFormatter.percent(industry.changePercent), 9)) \(leader)")
            }
            exit(industries.isEmpty ? 1 : 0)
        }
        let entries = try await provider.fetchRank(kind, count: count) ?? []
        for (index, entry) in entries.enumerated() {
            print([
                pad(String(index + 1), 3),
                pad(entry.symbol.rawValue, 10),
                pad(entry.name, 14),
                pad(QuoteFormatter.price(entry.price, decimals: 2), 10),
                pad(QuoteFormatter.percent(entry.changePercent), 9),
                "额 " + QuoteFormatter.largeNumber(entry.amount),
            ].joined(separator: " "))
        }
        exit(entries.isEmpty ? 1 : 0)

    case "flow":
        guard let symbol = parseSymbols(arguments.dropFirst().prefix(1)).first else {
            printUsage()
            exit(2)
        }
        guard let flow = try await provider.fetchFundFlow(for: symbol) else {
            print("\(symbol.rawValue) 没有资金流向（只有 A 股个股和 ETF 有）")
            exit(1)
        }
        let money = QuoteFormatter.signedLargeNumber
        let rank = flow.rank.map { "  排名 \($0.position)/\($0.total)" } ?? ""
        print("\(symbol.rawValue) 主力净流入 \(money(flow.mainNetInflow))\(rank)")
        print("  主力流入 \(QuoteFormatter.largeNumber(flow.mainInflow))  流出 \(QuoteFormatter.largeNumber(flow.mainOutflow))")
        print("  超大单 \(money(flow.superNet))  大单 \(money(flow.bigNet))  中单 \(money(flow.mediumNet))  小单 \(money(flow.smallNet))")
        if let first = flow.trend.first, let last = flow.trend.last {
            func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
            print("  分时 \(flow.trend.count) 分钟，\(time(first.minute)) 到 \(time(last.minute))")
        }
        for day in flow.days {
            print("  \(day.date)  \(money(day.mainNetInflow))")
        }
        if let note = flow.note {
            print("  \(note)")
        }

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
