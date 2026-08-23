import CryptoKit
import Foundation
import OrchardOrchestration
import OrchardProtocol

/// The slice of live terminal state the orchestration verbs need: the directory for
/// group-address expansion, and handle → paneKey resolution for lifecycle authority.
/// Wired to T3's terminal service at runtime assembly; defaults keep the adapter fully
/// testable without any terminal layer.
public struct OrchestrationRuntimeContext: Sendable {
    /// How workers should invoke the agent-facing CLI (baked into dispatch preambles).
    public var cliCommand: String
    /// Live terminal directory with each terminal's runtime agent status
    /// (`working|permission|idle`, nil = no live agent) for `@idle`-style groups.
    public var terminals: @Sendable () async -> [(entry: TerminalDirectoryEntry, agentStatus: String?)]
    /// Durable pane identity behind a (possibly reminted) handle; nil when the handle
    /// is unknown to the terminal layer.
    public var paneKey: @Sendable (String) async -> String?

    public init(
        cliCommand: String = "orchard",
        terminals: @escaping @Sendable () async -> [(entry: TerminalDirectoryEntry, agentStatus: String?)] = { [] },
        paneKey: @escaping @Sendable (String) async -> String? = { _ in nil }
    ) {
        self.cliCommand = cliCommand
        self.terminals = terminals
        self.paneKey = paneKey
    }
}

/// T1's SQLite store conformed to T2's `OrchestrationStoreAPI`: parses the CLI-contract
/// params (flag names exactly as `orchard <verb>` sends them), calls the store, and
/// shapes results the way the orchard CLI prints them today (row objects carry their
/// snake_case DB fields, matching Orca's check/inbox output contract).
///
/// An actor because `OrchestrationStore` confines its SQLite connection to one caller
/// at a time. Long-polls (`check --wait`, `ask`) suspend at `await` points, so actor
/// reentrancy lets a worker's `send` land while a coordinator's wait is parked.
public actor LiveOrchestrationStore: OrchestrationStoreAPI {
    let store: OrchestrationStore
    let waitCenter: MessageWaitCenter
    let context: OrchestrationRuntimeContext

    /// `check --wait` default, per Orca's ORCHESTRATION_MESSAGE_WAIT_DEFAULT_TIMEOUT_MS.
    static let defaultCheckWaitSeconds: TimeInterval = 120
    /// `ask` default/ceiling, per Orca's ORCHESTRATION_ASK_* constants.
    static let defaultAskSeconds: TimeInterval = 600
    static let maxAskSeconds: TimeInterval = 1800

    public init(store: OrchestrationStore,
                waitCenter: MessageWaitCenter = MessageWaitCenter(),
                context: OrchestrationRuntimeContext = OrchestrationRuntimeContext()) {
        self.store = store
        self.waitCenter = waitCenter
        self.context = context
        // Wake long-polls when a message commits. The store already suppresses
        // notifications for rows consumed at reconcile time.
        store.onMessageArrived = { [waitCenter] recipient, type in
            waitCenter.notifyMessageArrived(recipient: recipient, type: type)
        }
    }

    /// Store at `<directory>/orchestration.db` — the production boot path.
    public init(databasePath: String,
                waitCenter: MessageWaitCenter = MessageWaitCenter(),
                context: OrchestrationRuntimeContext = OrchestrationRuntimeContext()) throws {
        self.init(store: try OrchestrationStore(path: databasePath),
                  waitCenter: waitCenter, context: context)
    }

    // MARK: - Caller identity

    struct CallerIdentity {
        let handle: String?
        let paneKey: String?
    }

    /// Resolve `--from`/`--terminal` to (handle, paneKey). The pane comes from the live
    /// terminal registry; a handle the registry doesn't know falls back to itself as its
    /// own pane key, so bare-CLI callers keep a stable (if synthetic) authority identity.
    func identity(_ p: [String: JSONValue]) async -> CallerIdentity {
        guard let handle = p.str("from") ?? p.str("terminal"), !handle.isEmpty else {
            return CallerIdentity(handle: nil, paneKey: nil)
        }
        let pane = await context.paneKey(handle)
        return CallerIdentity(handle: handle, paneKey: pane ?? handle)
    }

    // MARK: - Run inference

    /// Infer the Run a command addresses, in Orca's precedence: explicit `--run`, a
    /// `run:<id>` recipient, the dispatch/task the payload names, the caller's
    /// coordinator binding, the caller's live worker dispatch, and finally the sole
    /// existing run (the common single-run CLI session).
    func resolveRunID(_ p: [String: JSONValue], caller: CallerIdentity,
                      to: String? = nil) throws -> String {
        if let explicit = p.str("run"), !explicit.isEmpty { return explicit }
        if let to, to.hasPrefix("run:") { return String(to.dropFirst(4)) }
        if let dispatchID = p.str("dispatch-id"), let dispatch = try store.dispatchContext(dispatchID) {
            return dispatch.runID
        }
        if let taskID = p.str("task-id"), let task = try store.task(taskID) {
            return task.runID
        }
        if let pane = caller.paneKey, let bound = try store.runForCoordinatorPane(pane) {
            return bound.id
        }
        if let handle = caller.handle,
           let dispatch = try store.activeDispatchForAssignee(handle: handle, paneKey: caller.paneKey) {
            return dispatch.runID
        }
        let runs = try store.listRuns()
        if runs.count == 1 { return runs[0].id }
        throw RPCServiceError(
            code: "run_not_found",
            message: "No run in scope; pass --run <id> or bind one with run-use.")
    }

    func requireRun(_ id: String) throws -> OrchestrationRun {
        guard let run = try store.run(id) else {
            throw RPCServiceError(code: "run_not_found", message: "Run \(id) was not found.")
        }
        return run
    }

    /// Fence callers who present an identity that is not the Run's bound coordinator.
    /// Anonymous local callers (no `--from`/`--terminal`) pass — the socket auth token
    /// already gates them, and fencing exists to catch *replaced* consumers, not tools.
    func requireCoordinatorAuthority(_ run: OrchestrationRun, caller: CallerIdentity) throws {
        guard let handle = caller.handle else { return }
        if run.coordinatorPaneKey == nil && run.coordinatorHandle == nil { return }
        if let pane = run.coordinatorPaneKey, pane == caller.paneKey { return }
        if let bound = run.coordinatorHandle, bound == handle { return }
        throw RPCServiceError(
            code: "consumer_fenced",
            message: "Terminal \(handle) is not the coordinator of run \(run.id); rebind with run-use.")
    }

    // MARK: - Error mapping / idempotency

    /// Run a verb body, translating T1's typed errors into wire errors so the envelope
    /// carries the store's own codes (`consumer_fenced`, `task_not_startable`, …).
    func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as OrchestrationError {
            throw RPCServiceError(code: error.code, message: error.message)
        }
    }

    /// `--retry-request` handling for every mutating verb: exact retries replay the
    /// stored receipt without re-running the mutation (mutation_receipts semantics).
    /// Built on the store's begin/complete/discard primitives because verb bodies are
    /// async (identity resolution awaits the terminal layer).
    func idempotent(_ p: [String: JSONValue], method: String,
                    _ body: () async throws -> JSONValue) async throws -> JSONValue {
        guard let requestID = p.str("retry-request"), !requestID.isEmpty else {
            return try await mapped(body)
        }
        return try await mapped {
            let fingerprint = try store.localMutationCallerFingerprint()
            var canonical = p
            canonical.removeValue(forKey: "retry-request")
            let payloadHash = Self.canonicalHash(canonical)
            switch try store.beginMutationReceipt(
                callerFingerprint: fingerprint, requestID: requestID,
                method: method, payloadHash: payloadHash) {
            case .completed(let receipt):
                return Self.decodeReceipt(receipt.receipt)
            case .pending, .started:
                do {
                    let value = try await body()
                    try store.completeMutationReceipt(
                        callerFingerprint: fingerprint, requestID: requestID,
                        method: method, payloadHash: payloadHash,
                        receipt: Self.encodeReceipt(value))
                    return value
                } catch {
                    try? store.discardPendingMutationReceipt(
                        callerFingerprint: fingerprint, requestID: requestID)
                    throw error
                }
            }
        }
    }

    static func canonicalHash(_ params: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(params))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encodeReceipt(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeReceipt(_ receipt: String?) -> JSONValue {
        guard let receipt, let data = receipt.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return value
    }
}

// MARK: - Row encoding (snake_case DB fields, matching Orca's CLI output contract)

extension LiveOrchestrationStore {
    static func json(_ run: OrchestrationRun) -> JSONValue {
        .object([
            "id": .string(run.id),
            "objective": .string(run.objective),
            "coordinator_handle": optional(run.coordinatorHandle),
            "coordinator_pane_key": optional(run.coordinatorPaneKey),
            "consumer_generation": .number(Double(run.consumerGeneration)),
            "created_at": .string(run.createdAt),
            "updated_at": .string(run.updatedAt),
        ])
    }

    static func json(_ message: OrchestrationMessage) -> JSONValue {
        .object([
            "id": .string(message.id),
            "run_id": .string(message.runID),
            "from_handle": .string(message.fromHandle),
            "to_handle": .string(message.toHandle),
            "subject": .string(message.subject),
            "body": .string(message.body),
            "type": .string(message.type.rawValue),
            "priority": .string(message.priority.rawValue),
            "thread_id": optional(message.threadID),
            "payload": optional(message.payload),
            "read": .number(message.read ? 1 : 0),
            "sequence": .number(Double(message.sequence)),
            "created_at": .string(message.createdAt),
        ])
    }

    static func json(_ task: OrchestrationTask) -> JSONValue {
        .object([
            "id": .string(task.id),
            "run_id": .string(task.runID),
            "parent_id": optional(task.parentID),
            "task_title": optional(task.taskTitle),
            "display_name": optional(task.displayName),
            "spec": .string(task.spec),
            "status": .string(task.status.rawValue),
            "deps": .array(task.deps.map(JSONValue.string)),
            "result": optional(task.result),
            "created_at": .string(task.createdAt),
            "completed_at": optional(task.completedAt),
        ])
    }

    static func json(_ dispatch: DispatchContext) -> JSONValue {
        .object([
            "id": .string(dispatch.id),
            "run_id": .string(dispatch.runID),
            "task_id": .string(dispatch.taskID),
            "assignee_handle": optional(dispatch.assigneeHandle),
            "assignee_pane_key": optional(dispatch.assigneePaneKey),
            "status": .string(dispatch.status.rawValue),
            "failure_count": .number(Double(dispatch.failureCount)),
            "last_failure": optional(dispatch.lastFailure),
            "termination_reason": optional(dispatch.terminationReason),
            "dispatched_at": optional(dispatch.dispatchedAt),
            "completed_at": optional(dispatch.completedAt),
            "created_at": .string(dispatch.createdAt),
            "last_heartbeat_at": optional(dispatch.lastHeartbeatAt),
        ])
    }

    static func json(_ gate: DecisionGate) -> JSONValue {
        .object([
            "id": .string(gate.id),
            "run_id": .string(gate.runID),
            "task_id": .string(gate.taskID),
            "question": .string(gate.question),
            "options": .array(gate.options.map(JSONValue.string)),
            "status": .string(gate.status.rawValue),
            "resolution": optional(gate.resolution),
            "created_at": .string(gate.createdAt),
            "resolved_at": optional(gate.resolvedAt),
        ])
    }

    static func json(_ worker: WorkerDispatch) -> JSONValue {
        .object([
            "dispatch_id": .string(worker.dispatchID),
            "state": .string(worker.state.rawValue),
            "stage": .string(worker.stage),
            "worktree_id": optional(worker.worktreeID),
            "agent_terminal_handle": optional(worker.agentTerminalHandle),
            "setup_state": .string(worker.setupState),
            "last_error": optional(worker.lastError),
            "created_at": .string(worker.createdAt),
            "updated_at": .string(worker.updatedAt),
        ])
    }

    static func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }
}

// MARK: - Param accessors for the CLI flag vocabulary

extension Dictionary where Key == String, Value == JSONValue {
    /// String-typed flag; numbers stringify so `--id 42` still reads.
    func str(_ key: String) -> String? {
        switch self[key] {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return nil
        }
    }

    /// Boolean flag: present-without-value (`--wait`) parses as `.bool(true)`.
    func flag(_ key: String) -> Bool {
        switch self[key] {
        case .bool(let b): return b
        case .string(let s): return (s as NSString).boolValue
        case .number(let n): return n != 0
        default: return false
        }
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// CSV flag (`--types a,b`); a JSON array of strings is accepted too.
    func csv(_ key: String) -> [String]? {
        switch self[key] {
        case .string(let s):
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        case .array(let values):
            let parts = values.compactMap(\.stringValue)
            return parts.isEmpty ? nil : parts
        default:
            return nil
        }
    }

    /// A `json`-hinted flag rendered back to its compact JSON string (payload columns
    /// store TEXT). A plain string passes through as-is.
    func jsonText(_ key: String) -> String? {
        switch self[key] {
        case .none, .some(.null): return nil
        case .some(.string(let s)): return s
        case .some(let value):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
