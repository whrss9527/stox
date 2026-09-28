import Foundation

/// 把港币、美元折算成人民币用的汇率：1 港币、1 美元各合多少人民币。
public struct ExchangeRates: Equatable, Sendable {
    public var hkdCNY: Double
    public var usdCNY: Double

    public init(hkdCNY: Double, usdCNY: Double) {
        self.hkdCNY = hkdCNY
        self.usdCNY = usdCNY
    }

    /// 某个市场所用货币折合人民币的汇率。
    public func toCNY(_ region: MarketRegion) -> Double {
        switch region {
        case .cn: return 1
        case .hk: return hkdCNY
        case .us: return usdCNY
        }
    }
}

/// 解析腾讯外汇行情 `https://qt.gtimg.cn/utf8/q=whUSDCNY,whHKDCNY`。
///
/// 每个货币对一行：`v_whUSDCNY="310~美元人民币~USDCNY~6.7101~~20260929005206~6.7121~…";`，第 3 位是现价。
public enum TencentFXParser {
    public static let url = URL(string: "https://qt.gtimg.cn/utf8/q=whUSDCNY,whHKDCNY")!

    public static func parse(_ text: String) -> ExchangeRates? {
        var rates: [String: Double] = [:]
        for (key, payload) in TencentQuoteParser.records(in: text) {
            let fields = payload.split(separator: "~", omittingEmptySubsequences: false)
            guard fields.count > 3, let value = Double(fields[3].trimmingCharacters(in: .whitespaces)),
                  value > 0, value.isFinite
            else { continue }
            rates[key] = value
        }
        guard let usd = rates["whUSDCNY"], let hkd = rates["whHKDCNY"] else { return nil }
        return ExchangeRates(hkdCNY: hkd, usdCNY: usd)
    }
}

extension Portfolio {
    /// 把各币种的合计按现在的汇率折成人民币加在一起。只有一种货币、或者还没有汇率时返回 nil。
    /// 成本也按现在的汇率折算，所以折合后的持仓盈亏不含买入以来的汇率变化。
    public static func combined(_ summaries: [PortfolioSummary], rates: ExchangeRates?) -> PortfolioSummary? {
        guard summaries.count > 1, let rates else { return nil }
        var total = PortfolioSummary(region: .cn, marketValue: 0, costValue: 0, dayProfit: 0, count: 0)
        for summary in summaries {
            let rate = rates.toCNY(summary.region)
            total.marketValue += summary.marketValue * rate
            total.costValue += summary.costValue * rate
            total.dayProfit += summary.dayProfit * rate
            total.count += summary.count
        }
        return total
    }
}
