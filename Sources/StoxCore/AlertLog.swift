import Foundation

/// 发过的一条提醒：价格提醒、涨跌停、异动，或者收盘小结。
public struct AlertLogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 哪一只；收盘小结不是某一只的，为 nil。
    public var symbol: Symbol?
    public var title: String
    public var body: String
    public var time: Date

    public init(id: UUID = UUID(), symbol: Symbol?, title: String, body: String, time: Date) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.body = body
        self.time = time
    }
}

/// 最近发过的提醒，最新的在前面。通知一闪就过去了，面板里可以再翻看。
public struct AlertLog: Codable, Equatable, Sendable {
    /// 最多留这么多条。
    public static let limit = 50

    public private(set) var entries: [AlertLogEntry]

    public init(entries: [AlertLogEntry] = []) {
        self.entries = entries
    }

    public mutating func append(_ entry: AlertLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }

    public mutating func append(_ trigger: AlertTrigger, at time: Date) {
        append(AlertLogEntry(symbol: trigger.symbol, title: trigger.title, body: trigger.body, time: time))
    }

    public mutating func append(_ note: CloseSummaryNote, at time: Date) {
        append(AlertLogEntry(symbol: nil, title: note.title, body: note.body, time: time))
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// 删掉的证券不用留着它的提醒。
    public mutating func forget(_ symbol: Symbol) {
        entries.removeAll { $0.symbol == symbol }
    }
}
