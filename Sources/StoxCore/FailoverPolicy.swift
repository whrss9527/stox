import Foundation

/// 主源失败后两分钟只用备用，冷却结束再试主源；网络恢复可以提前清掉冷却。
public struct FailoverPolicy: Sendable {
    private var retryAfter = Date.distantPast
    public init() {}
    public func skipsPrimary(at date: Date) -> Bool { date < retryAfter }
    public mutating func record(source: QuoteSource, skippedPrimary: Bool, at date: Date) {
        if source == .backup, !skippedPrimary { retryAfter = date.addingTimeInterval(120) }
        if source == .primary { reset() }
    }
    public mutating func reset() { retryAfter = .distantPast }
}
