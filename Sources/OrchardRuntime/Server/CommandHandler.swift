import Foundation
import OrchardProtocol

/// One unit of RPC surface: a handler owns a set of verbs and services requests for them.
/// Wave-1 tasks (terminals, workspaces, orchestration) each ship handlers conforming to
/// this and register them at runtime assembly; the socket server (T2) routes through the
/// registry without knowing any verb by name.
public protocol CommandHandler: Sendable {
    /// The verbs this handler services (e.g. `["worktree-list", "worktree-create"]`).
    /// Must be disjoint across registered handlers.
    var verbs: [String] { get }

    func handle(_ request: RPCRequest) async -> RPCResponse
}

/// Routes requests to the handler that owns each verb.
///
/// Built once at assembly, then read-only — a value type on purpose, so the server can
/// hold an immutable copy and registration races can't exist at runtime.
public struct CommandRegistry: Sendable {
    private var handlersByVerb: [String: any CommandHandler] = [:]

    public init() {}

    /// Register a handler for all its verbs. A duplicate verb is a programmer error in
    /// assembly (two subsystems claiming one verb), not a runtime condition — so it traps.
    public mutating func register(_ handler: any CommandHandler) {
        for verb in handler.verbs {
            precondition(handlersByVerb[verb] == nil,
                         "duplicate CommandHandler registration for verb '\(verb)'")
            handlersByVerb[verb] = handler
        }
    }

    public var registeredVerbs: [String] { handlersByVerb.keys.sorted() }

    public func handler(for verb: String) -> (any CommandHandler)? {
        handlersByVerb[verb]
    }

    /// Dispatch one request, mapping an unclaimed verb to the standard error envelope.
    public func route(_ request: RPCRequest) async -> RPCResponse {
        guard let handler = handlersByVerb[request.method] else {
            return .failure(id: request.id, error: RPCError(
                code: "unknown_command",
                message: "no handler for '\(request.method)'"))
        }
        return await handler.handle(request)
    }
}
