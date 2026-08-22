import Foundation
import OrchardProtocol

/// Codable ↔ `JSONValue` without adding helpers to OrchardProtocol (T2 owns that
/// module). Used by workspace RPC handlers to build result envelopes.
enum JSONBridge {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func value<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try encoder.encode(value)
        // Decode through JSONValue's Codable rather than JSONSerialization:
        // JSONSerialization yields NSNumber/NSDictionary which don't always
        // match Swift `Int`/`[String: Any]` in a switch, dropping fields like
        // `totalCount`.
        return try decoder.decode(JSONValue.self, from: data)
    }

    static func wrap(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let s as String:
            return .string(s)
        case let b as Bool:
            return .bool(b)
        case let i as Int:
            return .number(Double(i))
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let arr as [Any]:
            return .array(arr.map(wrap))
        case let obj as [String: Any]:
            return .object(obj.mapValues(wrap))
        case let dict as NSDictionary:
            var obj: [String: JSONValue] = [:]
            for (key, value) in dict {
                if let key = key as? String { obj[key] = wrap(value) }
            }
            return .object(obj)
        default:
            return .string("\(any)")
        }
    }
}

extension JSONValue {
    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var numberValue: Double? {
        if case let .number(n) = self { return n }
        return nil
    }

    var intValue: Int? {
        numberValue.map { Int($0) }
    }

    func field(_ keys: String...) -> JSONValue? {
        guard let obj = objectValue else { return nil }
        for key in keys {
            if let v = obj[key] { return v }
        }
        return nil
    }

    func string(_ keys: String...) -> String? {
        guard let v = field(keys: keys) else { return nil }
        if let s = v.stringValue { return s }
        if case let .number(n) = v {
            if n == n.rounded() { return String(Int(n)) }
            return String(n)
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? { field(keys: keys)?.boolValue }

    private func field(keys: [String]) -> JSONValue? {
        guard let obj = objectValue else { return nil }
        for key in keys {
            if let v = obj[key] { return v }
        }
        return nil
    }
}
