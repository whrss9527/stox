import Foundation

/// 应用轮询的时间和等待；测试传入可控时间，不等真实市场时段或冷却时间。
@MainActor
struct QuoteStoreClock {
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) async throws -> Void = { interval in
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}
