import Foundation

/// Schema-less value used for record fields. Records are stored and merged as
/// `[field: JSONValue]` maps, which is what lets the data model evolve without SQL
/// migrations and keeps exports readable by any JSON tool.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// All human-readable text inside the value (used for local search).
    var searchableText: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap(\.searchableText)
        case .object(let o): return o.values.flatMap(\.searchableText)
        default: return []
        }
    }

    static func fields<T: Encodable>(of value: T) throws -> [String: JSONValue] {
        let data = try HearthJSON.encoder.encode(value)
        guard case .object(let o) = try HearthJSON.decoder.decode(JSONValue.self, from: data) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "record must encode to an object"))
        }
        return o
    }

    static func decode<T: Decodable>(_ type: T.Type, from fields: [String: JSONValue]) throws -> T {
        let data = try HearthJSON.encoder.encode(JSONValue.object(fields.filter { $0.value != .null }))
        return try HearthJSON.decoder.decode(type, from: data)
    }
}
