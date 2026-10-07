import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StoxCore

/// 命令行巡检可读真实接口，也可复放保存的原始数据，测试不调用真实网络。
func checkQuoteData(_ arguments: ArraySlice<String>) async throws -> Int32 {
    let args = Array(arguments)
    var source = QuoteDataSource.tencent
    var rawPath: String?, savePath: String?
    var now = Date(), maxAgeDays: Double?
    var symbols: [Symbol] = []
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg.hasPrefix("--") {
            guard index + 1 < args.count else { print("Missing value for \(arg)"); return 2 }
            index += 1
            let value = args[index]
            switch arg {
            case "--source":
                guard let selected = QuoteDataSource(rawValue: value) else { print("Source must be tencent or sina"); return 2 }
                source = selected
            case "--raw": rawPath = value
            case "--save-raw": savePath = value
            case "--at":
                guard let date = ISO8601DateFormatter().date(from: value) else { print("Invalid ISO-8601 date: \(value)"); return 2 }
                now = date
            case "--max-age-days":
                guard let days = Double(value), days.isFinite, days > 0 else { print("Age limit must be a positive number"); return 2 }
                maxAgeDays = days
            default: print("Unknown check option: \(arg)"); return 2
            }
        } else {
            guard let symbol = SymbolInput.parse(arg) else { print("Invalid symbol: \(arg)"); return 2 }
            symbols.append(symbol)
        }
        index += 1
    }
    if symbols.isEmpty { symbols = QuoteDataCheck.defaultSymbols }
    let data: Data
    if let rawPath { data = try Data(contentsOf: URL(fileURLWithPath: rawPath)) }
    else {
        let env = ProcessInfo.processInfo.environment
        let url = source == .tencent
            ? TencentProvider.quoteURL(for: symbols, endpoint: env[TencentProvider.endpointOverrideVariable] ?? TencentProvider.quoteEndpoint)
            : SinaProvider.quoteURL(for: symbols, endpoint: env[SinaProvider.endpointOverrideVariable] ?? SinaProvider.endpoint)
        guard let url else { print("Cannot construct quote URL"); return 2 }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if source == .sina { request.setValue(SinaProvider.referer, forHTTPHeaderField: "Referer") }
        let (body, response) = try await URLSession.shared.data(for: request)
        data = body
        if let savePath { try data.write(to: URL(fileURLWithPath: savePath), options: .atomic) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            print("\(source.rawValue): HTTP status \((response as? HTTPURLResponse)?.statusCode ?? 0)"); return 1
        }
    }
    if let savePath { try data.write(to: URL(fileURLWithPath: savePath), options: .atomic) }
    let differences = QuoteDataCheck.differences(source.decode(data), source: source, symbols: symbols, now: now, maxAgeDays: maxAgeDays)
    for difference in differences { print("\(source.rawValue): \(difference)") }
    if differences.isEmpty { print("\(source.rawValue): \(symbols.count) reviewed quote records passed") }
    return differences.isEmpty ? 0 : 1
}
