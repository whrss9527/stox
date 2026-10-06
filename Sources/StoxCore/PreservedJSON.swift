import Foundation

/// 不认识的同步条目只保存 JSON，不拿来请求行情或计算交易。
public enum PreservedJSON: Codable, Hashable, Sendable {
    case null, bool(Bool), string(String), integer(Int64), unsigned(UInt64), number(Decimal)
    case array([PreservedJSON]), object([String: PreservedJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([PreservedJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: PreservedJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// 原数组的位置和原始内容；单独保存时也可编码到本机偏好里。
public struct PreservedJSONItem: Codable, Hashable, Sendable {
    public var index: Int
    public var value: PreservedJSON

    var identity: String {
        if case .object(let fields) = value, case .string(let symbol) = fields["symbol"] {
            return "symbol:" + symbol
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return "json:" + ((try? encoder.encode(value)) ?? Data()).base64EncodedString()
    }
}

/// 已知条目正常解码，不认识的留在原来的位置。编码时把两部分重新穿插。
struct PreservingArray<Value: Codable>: Codable {
    var values: [Value]
    var unknown: [PreservedJSONItem]

    init(values: [Value], unknown: [PreservedJSONItem]) {
        self.values = values
        self.unknown = unknown
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        values = []; unknown = []
        while !c.isAtEnd {
            let index = c.currentIndex
            let child = try c.superDecoder()
            if let value = try? Value(from: child) { values.append(value) }
            else { unknown.append(PreservedJSONItem(index: index, value: try PreservedJSON(from: child))) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        let opaque = unknown.enumerated().sorted {
            $0.element.index == $1.element.index ? $0.offset < $1.offset : $0.element.index < $1.element.index
        }.map(\.element)
        var knownIndex = 0, unknownIndex = 0
        while knownIndex < values.count || unknownIndex < opaque.count {
            if unknownIndex < opaque.count, (opaque[unknownIndex].index <= c.count || knownIndex == values.count) {
                try c.encode(opaque[unknownIndex].value)
                unknownIndex += 1
            } else {
                try c.encode(values[knownIndex])
                knownIndex += 1
            }
        }
    }
}
