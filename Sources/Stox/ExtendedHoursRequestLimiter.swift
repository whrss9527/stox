import Foundation
import StoxCore

/// Shared by all overlapping panel sessions, including providers that finish after cancellation.
actor ExtendedHoursRequestLimiter {
    private struct Waiter {
        let id: UUID
        let symbol: Symbol
        let continuation: CheckedContinuation<Bool, Never>
    }
    private let capacity: Int
    private var active = Set<Symbol>()
    private var waiters: [Waiter] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func acquire(_ symbol: Symbol) async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                waiters.append(Waiter(id: id, symbol: symbol, continuation: continuation))
                grantAvailable()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ symbol: Symbol) {
        active.remove(symbol)
        grantAvailable()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func grantAvailable() {
        while active.count < capacity,
              let index = waiters.firstIndex(where: { !active.contains($0.symbol) }) {
            let waiter = waiters.remove(at: index)
            active.insert(waiter.symbol)
            waiter.continuation.resume(returning: true)
        }
    }
}
