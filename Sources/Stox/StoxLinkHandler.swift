import AppKit
import StoxCore

/// 旧查询在新命令、退出或用户改动剪贴板后不能提交；测试使用独立粘贴板和假行情。
@MainActor
final class StoxLinkHandler {
    private let show: () -> Void
    private let add: (Symbol) -> Void
    private let fetch: @MainActor (Symbol) async throws -> Quote?
    private let pasteboard: NSPasteboard
    private var generation: UInt64 = 0
    private var pending: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general, show: @escaping () -> Void,
         add: @escaping (Symbol) -> Void, fetch: @escaping @MainActor (Symbol) async throws -> Quote?) {
        self.pasteboard = pasteboard
        self.show = show
        self.add = add
        self.fetch = fetch
    }

    func cancel() {
        generation &+= 1
        pending?.cancel()
        pending = nil
    }

    @discardableResult
    func handle(_ link: StoxLink) -> Task<Void, Never>? {
        cancel()
        switch link {
        case .show: show()
        case .add(let symbol): add(symbol)
        case .quote(let symbol):
            let owner = generation
            let change = pasteboard.changeCount
            pending = Task { [weak self, fetch] in
                do {
                    guard let quote = try await fetch(symbol), let self,
                          !Task.isCancelled, self.generation == owner,
                          self.pasteboard.changeCount == change,
                          quote.symbol == symbol, quote.price.isFinite else { return }
                    let price = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"),
                                       min(max(quote.priceDecimals, 0), 8), quote.price)
                    self.pasteboard.clearContents()
                    self.pasteboard.setString("\(quote.name) \(symbol.rawValue) \(price)", forType: .string)
                } catch {
                    guard let self, !Task.isCancelled, self.generation == owner else { return }
                    Log.error("链接报价失败：\(error.localizedDescription)")
                }
            }
            return pending
        }
        return nil
    }
}

/// Launch Services可能在启动回调前交付链接；仅在初始化完成后执行。
@MainActor
final class StoxLinkInbox {
    private var pending: [StoxLink] = []
    private var consume: ((StoxLink) -> Void)?
    private var stopped = false

    func receive(_ urls: [URL]) {
        guard !stopped else { return }
        for link in urls.compactMap(StoxLink.init) {
            if let consume { consume(link) } else { pending.append(link) }
        }
    }

    func start(_ consume: @escaping (StoxLink) -> Void) {
        guard !stopped else { return }
        self.consume = consume
        let links = pending
        pending.removeAll()
        links.forEach(consume)
    }

    func stop() {
        stopped = true
        pending.removeAll()
        consume = nil
    }
}
