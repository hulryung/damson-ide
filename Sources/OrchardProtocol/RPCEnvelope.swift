import Foundation

/// The wire envelope shared by the runtime server and the `orchard` CLI.
///
/// Frames are newline-delimited JSON over a unix socket, one connection per request.
/// Response shape (per docs/REBUILD-PLAN.md):
/// `{ id, ok, result | error: {code, message, data}, _meta: {runtimeId} }`, with
/// `{"_keepalive": true}` frames interleaved during long-polls. T2 implements the
/// transport; these Codables are the contract both sides compile against.
public struct RPCRequest: Codable, Equatable, Sendable {
    /// Caller-minted request id, echoed on the response.
    public let id: String
    /// The command verb (e.g. "status", "worktree-list").
    public let method: String
    /// Verb-specific arguments. Kept schemaless at the envelope layer; each handler
    /// decodes what it needs.
    public let params: JSONValue?
    /// Runtime metadata auth token. Local filesystem permissions are the first boundary;
    /// this token prevents unrelated local clients that merely discover the socket path.
    public let authToken: String?

    public init(id: String = UUID().uuidString, method: String, params: JSONValue? = nil,
                authToken: String? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.authToken = authToken
    }
}

public struct RPCResponse: Codable, Equatable, Sendable {
    public let id: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: RPCError?
    public let meta: RPCMeta?

    enum CodingKeys: String, CodingKey {
        case id, ok, result, error
        case meta = "_meta"
    }

    public init(id: String, ok: Bool, result: JSONValue? = nil, error: RPCError? = nil,
                meta: RPCMeta? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
        self.meta = meta
    }

    public static func success(id: String, result: JSONValue? = nil, meta: RPCMeta? = nil) -> RPCResponse {
        RPCResponse(id: id, ok: true, result: result, meta: meta)
    }

    public static func failure(id: String, error: RPCError, meta: RPCMeta? = nil) -> RPCResponse {
        RPCResponse(id: id, ok: false, error: error, meta: meta)
    }
}

/// Typed failure carried in the envelope. `code` is machine-readable (snake_case,
/// e.g. "unknown_command", "runtime_unavailable"); `message` is for humans; `data`
/// carries structured recovery context when a code alone isn't actionable.
public struct RPCError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let data: JSONValue?

    public init(code: String, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Server-stamped response metadata. `runtimeId` lets a client detect that it reconnected
/// to a different runtime instance than the one it was talking to.
public struct RPCMeta: Codable, Equatable, Sendable {
    public let runtimeId: String

    public init(runtimeId: String) {
        self.runtimeId = runtimeId
    }
}

/// A schemaless-but-typed JSON value, so envelope params/results stay `Codable` without
/// pulling in a dependency or resorting to `Any`.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    /// Convenience accessors so handlers can pull simple fields without full decoding.
    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    public var boolValue: Bool? { if case let .bool(value) = self { return value }; return nil }
    public var numberValue: Double? { if case let .number(value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(value) = self { return value }; return nil }
}
