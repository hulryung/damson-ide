import Foundation
import OrchardProtocol

public enum OrchardMessageType: String, Codable, Sendable { case status, dispatch, worker_done, merge_ready, escalation, handoff, decision_gate, question, heartbeat }
public enum OrchardMessagePriority: String, Codable, Sendable { case normal, high, urgent }
public enum OrchardTaskStatus: String, Codable, Sendable { case pending, ready, dispatched, completed, failed, blocked }
public enum OrchardGateStatus: String, Codable, Sendable { case pending, resolved, timeout }

/// Stable semantic boundary implemented by a thin T1 adapter after integration.
public protocol OrchestrationStoreAPI: Sendable {
    func runCreate(_ p: [String: JSONValue]) async throws -> JSONValue; func runUse(_ p: [String: JSONValue]) async throws -> JSONValue
    func runCurrent(_ p: [String: JSONValue]) async throws -> JSONValue; func runList(_ p: [String: JSONValue]) async throws -> JSONValue; func runShow(_ p: [String: JSONValue]) async throws -> JSONValue
    /// Expands groups at send time and rejects group lifecycle reports.
    func send(_ p: [String: JSONValue]) async throws -> JSONValue
    /// Oldest outstanding FIFO delivery (max 50), replayed verbatim until ack; types only wake the waiter; consumer generations fence stale callers.
    func check(_ p: [String: JSONValue]) async throws -> JSONValue
    func reply(_ p: [String: JSONValue]) async throws -> JSONValue; func ask(_ p: [String: JSONValue]) async throws -> JSONValue; func inbox(_ p: [String: JSONValue]) async throws -> JSONValue
    func taskCreate(_ p: [String: JSONValue]) async throws -> JSONValue; func taskList(_ p: [String: JSONValue]) async throws -> JSONValue; func taskUpdate(_ p: [String: JSONValue]) async throws -> JSONValue
    func dispatchTask(_ p: [String: JSONValue]) async throws -> JSONValue; func dispatchShow(_ p: [String: JSONValue]) async throws -> JSONValue
    func gateCreate(_ p: [String: JSONValue]) async throws -> JSONValue; func gateResolve(_ p: [String: JSONValue]) async throws -> JSONValue; func gateList(_ p: [String: JSONValue]) async throws -> JSONValue
    func reset(_ p: [String: JSONValue]) async throws -> JSONValue
}

public struct OrchestrationCommandHandler: CommandHandler {
    public static let commandVerbs = ["run-create", "run-use", "run-current", "run-list", "run-show", "send", "check", "reply", "ask", "inbox", "task-create", "task-list", "task-update", "dispatch", "dispatch-show", "gate-create", "gate-resolve", "gate-list", "reset"]
    public let verbs = commandVerbs; private let store: any OrchestrationStoreAPI
    public init(store: any OrchestrationStoreAPI) { self.store = store }
    public func handle(_ request: RPCRequest) async -> RPCResponse {
        let p = request.params?.objectValue ?? [:]
        do {
            let value: JSONValue
            switch request.method {
            case "run-create": value = try await store.runCreate(p); case "run-use": value = try await store.runUse(p); case "run-current": value = try await store.runCurrent(p); case "run-list": value = try await store.runList(p); case "run-show": value = try await store.runShow(p)
            case "send": value = try await store.send(p); case "check": value = try await store.check(p); case "reply": value = try await store.reply(p); case "ask": value = try await store.ask(p); case "inbox": value = try await store.inbox(p)
            case "task-create": value = try await store.taskCreate(p); case "task-list": value = try await store.taskList(p); case "task-update": value = try await store.taskUpdate(p); case "dispatch": value = try await store.dispatchTask(p); case "dispatch-show": value = try await store.dispatchShow(p)
            case "gate-create": value = try await store.gateCreate(p); case "gate-resolve": value = try await store.gateResolve(p); case "gate-list": value = try await store.gateList(p); case "reset": value = try await store.reset(p)
            default: throw RPCServiceError(code: "unknown_command", message: request.method)
            }
            return .success(id: request.id, result: value)
        } catch let error as RPCServiceError { return .failure(id: request.id, error: error.rpcError) }
        catch { return .failure(id: request.id, error: RPCError(code: "orchestration_error", message: String(describing: error))) }
    }
}

public struct RPCServiceError: Error, Sendable { public let rpcError: RPCError; public init(code: String, message: String, data: JSONValue? = nil) { rpcError = RPCError(code: code, message: message, data: data) } }

public actor InMemoryOrchestrationStore: OrchestrationStoreAPI {
    public private(set) var calls: [String] = []; public var result: JSONValue
    public init(result: JSONValue = .object([:])) { self.result = result }
    private func call(_ name: String) -> JSONValue { calls.append(name); return result }
    public func runCreate(_ p: [String: JSONValue]) -> JSONValue { call("run-create") }; public func runUse(_ p: [String: JSONValue]) -> JSONValue { call("run-use") }; public func runCurrent(_ p: [String: JSONValue]) -> JSONValue { call("run-current") }; public func runList(_ p: [String: JSONValue]) -> JSONValue { call("run-list") }; public func runShow(_ p: [String: JSONValue]) -> JSONValue { call("run-show") }
    public func send(_ p: [String: JSONValue]) -> JSONValue { call("send") }; public func check(_ p: [String: JSONValue]) -> JSONValue { call("check") }; public func reply(_ p: [String: JSONValue]) -> JSONValue { call("reply") }; public func ask(_ p: [String: JSONValue]) -> JSONValue { call("ask") }; public func inbox(_ p: [String: JSONValue]) -> JSONValue { call("inbox") }
    public func taskCreate(_ p: [String: JSONValue]) -> JSONValue { call("task-create") }; public func taskList(_ p: [String: JSONValue]) -> JSONValue { call("task-list") }; public func taskUpdate(_ p: [String: JSONValue]) -> JSONValue { call("task-update") }; public func dispatchTask(_ p: [String: JSONValue]) -> JSONValue { call("dispatch") }; public func dispatchShow(_ p: [String: JSONValue]) -> JSONValue { call("dispatch-show") }
    public func gateCreate(_ p: [String: JSONValue]) -> JSONValue { call("gate-create") }; public func gateResolve(_ p: [String: JSONValue]) -> JSONValue { call("gate-resolve") }; public func gateList(_ p: [String: JSONValue]) -> JSONValue { call("gate-list") }; public func reset(_ p: [String: JSONValue]) -> JSONValue { call("reset") }
}
