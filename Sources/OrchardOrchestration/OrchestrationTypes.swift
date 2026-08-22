import Foundation

// Enumerations copied verbatim from Orca (docs/research/orca-inventory.md §1.3;
// reference: ~/dev/orca/src/main/runtime/orchestration/types.ts). The raw values are
// the wire/DB strings and must never drift — they are CHECK-constrained in the schema.

public enum MessageType: String, CaseIterable, Codable, Sendable {
    case status
    case dispatch
    case workerDone = "worker_done"
    case mergeReady = "merge_ready"
    case escalation
    case handoff
    case decisionGate = "decision_gate"
    case question
    case heartbeat
}

public enum MessagePriority: String, CaseIterable, Codable, Sendable {
    case normal
    case high
    case urgent
}

public enum TaskStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case ready
    case dispatched
    case completed
    case failed
    case blocked
}

public enum DispatchStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case dispatched
    case completed
    case failed
    case circuitBroken = "circuit_broken"
}

public enum GateStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case resolved
    case timeout
}

public enum QuestionStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case answered
    case closed
}

public enum DeliveryStatus: String, CaseIterable, Codable, Sendable {
    case outstanding
    case acknowledged
    case fenced
}

public enum WorkerDispatchState: String, CaseIterable, Codable, Sendable {
    case starting
    case ready
    case startUnknown = "start_unknown"
    case failed
    case succeeded
    case stopping
    case stopUnknown = "stop_unknown"
    case stopped
    case abandoned

    /// States in which the supervised worker no longer holds lifecycle authority.
    /// Everything else counts as "live" for the settle/fail guards.
    public var isSettled: Bool {
        switch self {
        case .failed, .succeeded, .stopped, .abandoned: return true
        case .starting, .ready, .startUnknown, .stopping, .stopUnknown: return false
        }
    }
}

public enum WorkerTerminalOwnershipState: String, CaseIterable, Codable, Sendable {
    case owned
    case transferred
    case userOwned = "user_owned"
    case external
    case released
}

public enum WorkerTerminalReleaseState: String, CaseIterable, Codable, Sendable {
    case notRequested = "not_requested"
    case retained
    case requested
    case releasing
    case released
    case unknown
}

public enum WorkerReportOutcome: String, CaseIterable, Codable, Sendable {
    case succeeded
    case failed
}

public enum WorkerTerminalArchiveKind: String, CaseIterable, Codable, Sendable {
    case transcriptPin = "transcript_pin"
    case terminalTail = "terminal_tail"
}

public enum MutationState: String, CaseIterable, Codable, Sendable {
    case pending
    case completed
}

// MARK: - Errors

/// Typed orchestration failure. `code` is the wire error code the RPC envelope carries
/// (`error: {code, message}`), matching Orca's `OrchestrationError` string codes.
public struct OrchestrationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }
}

// MARK: - Settlement results

/// `(taskId, dispatchId)`-keyed worker-report settlement outcome with the verbatim
/// rejection codes (docs/research/orca-inventory.md §8 item 2).
public enum SettlementRejectionCode: String, Equatable, Sendable {
    case unknownTask = "unknown_task"
    case unknownDispatch = "unknown_dispatch"
    case taskDispatchMismatch = "task_dispatch_mismatch"
    case inactiveDispatch = "inactive_dispatch"
    case staleDispatch = "stale_dispatch"
}

public enum WorkerReportSettlement: Equatable, Sendable {
    case settled(outcome: WorkerReportOutcome, duplicate: Bool)
    case rejected(code: SettlementRejectionCode, reason: String)
}

/// What reconciling a lifecycle message (`worker_done` / `heartbeat`) did.
/// `suppressed` means the row was consumed at reconcile time (marked read) — senders
/// must not wake waiters for it, unlike `ignored` rows that still need delivery.
public enum LifecycleReconciliation: Equatable, Sendable {
    case ignored
    case suppressed
    case rejected(code: String, reason: String)
    case completed(taskID: String, dispatchID: String)
    case failed(taskID: String, dispatchID: String)
    case heartbeatRecorded(dispatchID: String)
}

// MARK: - Row models

// Timestamps stay `String` in SQLite's UTC `datetime('now')` shape ("YYYY-MM-DD HH:MM:SS")
// end to end. Parsing them into `Date` at the store boundary would add a lossy round-trip
// for values the store only ever compares inside SQL (`julianday`).

public struct OrchestrationRun: Equatable, Sendable {
    public let id: String
    public let objective: String
    public let coordinatorHandle: String?
    public let coordinatorPaneKey: String?
    public let consumerGeneration: Int
    public let createdAt: String
    public let updatedAt: String

    init(row: SQLiteRow) throws {
        id = try row.text("id")
        objective = try row.text("objective")
        coordinatorHandle = try row.textOrNil("coordinator_handle")
        coordinatorPaneKey = try row.textOrNil("coordinator_pane_key")
        consumerGeneration = try row.int("consumer_generation")
        createdAt = try row.text("created_at")
        updatedAt = try row.text("updated_at")
    }
}

public struct OrchestrationMessage: Equatable, Sendable {
    public let id: String
    public let runID: String
    public let fromHandle: String
    public let toHandle: String
    public let subject: String
    public let body: String
    public let type: MessageType
    public let priority: MessagePriority
    public let threadID: String?
    public let payload: String?
    public let read: Bool
    /// Monotonic AUTOINCREMENT primary key — the FIFO order deliveries batch by.
    public let sequence: Int
    public let createdAt: String
    public let deliveredAt: String?
    public let senderPaneKey: String?

    init(row: SQLiteRow) throws {
        id = try row.text("id")
        runID = try row.text("run_id")
        fromHandle = try row.text("from_handle")
        toHandle = try row.text("to_handle")
        subject = try row.text("subject")
        body = try row.text("body")
        type = try Self.decodeEnum(MessageType.self, row.text("type"), column: "type")
        priority = try Self.decodeEnum(MessagePriority.self, row.text("priority"), column: "priority")
        threadID = try row.textOrNil("thread_id")
        payload = try row.textOrNil("payload")
        read = try row.int("read") != 0
        sequence = try row.int("sequence")
        createdAt = try row.text("created_at")
        deliveredAt = try row.textOrNil("delivered_at")
        senderPaneKey = try row.textOrNil("sender_pane_key")
    }

    static func decodeEnum<T: RawRepresentable>(
        _ type: T.Type, _ raw: String, column: String
    ) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: raw) else {
            throw SQLiteError(message: "Unexpected \(column) value '\(raw)'")
        }
        return value
    }
}

public struct Delivery: Equatable, Sendable {
    public let id: String
    public let runID: String
    public let consumerGeneration: Int
    /// JSON array of message IDs, in delivery order — replayed verbatim until ack.
    public let messageIDs: [String]
    public let status: DeliveryStatus
    public let createdAt: String
    public let acknowledgedAt: String?

    init(row: SQLiteRow) throws {
        id = try row.text("id")
        runID = try row.text("run_id")
        consumerGeneration = try row.int("consumer_generation")
        messageIDs = try JSONCoding.decodeStringArray(row.text("message_ids"))
        status = try OrchestrationMessage.decodeEnum(DeliveryStatus.self, row.text("status"), column: "status")
        createdAt = try row.text("created_at")
        acknowledgedAt = try row.textOrNil("acknowledged_at")
    }
}

public struct OrchestrationTask: Equatable, Sendable {
    public let id: String
    public let runID: String
    public let parentID: String?
    public let createdByTerminalHandle: String?
    public let createdByPaneKey: String?
    public let createdByProcessIncarnation: String?
    public let createdByRunGeneration: Int?
    public let taskTitle: String?
    public let displayName: String?
    public let spec: String
    public let status: TaskStatus
    /// DAG dependency task IDs (JSON array in the DB).
    public let deps: [String]
    public let result: String?
    public let createdAt: String
    public let completedAt: String?

    init(row: SQLiteRow) throws {
        id = try row.text("id")
        runID = try row.text("run_id")
        parentID = try row.textOrNil("parent_id")
        createdByTerminalHandle = try row.textOrNil("created_by_terminal_handle")
        createdByPaneKey = try row.textOrNil("created_by_pane_key")
        createdByProcessIncarnation = try row.textOrNil("created_by_process_incarnation")
        createdByRunGeneration = try row.intOrNil("created_by_run_generation")
        taskTitle = try row.textOrNil("task_title")
        displayName = try row.textOrNil("display_name")
        spec = try row.text("spec")
        status = try OrchestrationMessage.decodeEnum(TaskStatus.self, row.text("status"), column: "status")
        deps = try JSONCoding.decodeStringArray(row.text("deps"))
        result = try row.textOrNil("result")
        createdAt = try row.text("created_at")
        completedAt = try row.textOrNil("completed_at")
    }
}

public struct DispatchContext: Equatable, Sendable {
    public let id: String
    public let runID: String
    public let taskID: String
    public let launchTokenHash: String?
    public let assigneeHandle: String?
    /// Remint-stable pane identity behind the handle — what lifecycle authority keys on.
    public let assigneePaneKey: String?
    public let capabilityHash: String?
    public let processIncarnation: String?
    public let capabilityRevokedAt: String?
    public let status: DispatchStatus
    public let failureCount: Int
    public let lastFailure: String?
    public let terminationReason: String?
    public let dispatchedAt: String?
    public let completedAt: String?
    public let createdAt: String
    public let lastHeartbeatAt: String?

    init(row: SQLiteRow) throws {
        id = try row.text("id")
        runID = try row.text("run_id")
        taskID = try row.text("task_id")
        launchTokenHash = try row.textOrNil("launch_token_hash")
        assigneeHandle = try row.textOrNil("assignee_handle")
        assigneePaneKey = try row.textOrNil("assignee_pane_key")
        capabilityHash = try row.textOrNil("capability_hash")
        processIncarnation = try row.textOrNil("process_incarnation")
        capabilityRevokedAt = try row.textOrNil("capability_revoked_at")
        status = try OrchestrationMessage.decodeEnum(DispatchStatus.self, row.text("status"), column: "status")
        failureCount = try row.int("failure_count")
        lastFailure = try row.textOrNil("last_failure")
        terminationReason = try row.textOrNil("termination_reason")
        dispatchedAt = try row.textOrNil("dispatched_at")
        completedAt = try row.textOrNil("completed_at")
        createdAt = try row.text("created_at")
        lastHeartbeatAt = try row.textOrNil("last_heartbeat_at")
    }
}

public struct DecisionGate: Equatable, Sendable {
    public let id: String
    public let runID: String
    public let taskID: String
    public let question: String
    public let options: [String]
    public let status: GateStatus
    public let resolution: String?
    public let createdAt: String
    public let resolvedAt: String?

    init(row: SQLiteRow) throws {
        id = try row.text("id")
        runID = try row.text("run_id")
        taskID = try row.text("task_id")
        question = try row.text("question")
        options = try JSONCoding.decodeStringArray(row.text("options"))
        status = try OrchestrationMessage.decodeEnum(GateStatus.self, row.text("status"), column: "status")
        resolution = try row.textOrNil("resolution")
        createdAt = try row.text("created_at")
        resolvedAt = try row.textOrNil("resolved_at")
    }
}

public struct WorkerDispatch: Equatable, Sendable {
    public let dispatchID: String
    public let state: WorkerDispatchState
    public let stage: String
    public let worktreeID: String?
    public let agentTerminalHandle: String?
    public let setupState: String
    /// JSON array of effect records (`{kind, action, id}`), opaque to the store.
    public let effects: String
    public let residualResources: String
    public let startOptions: String
    public let lastError: String?
    public let createdAt: String
    public let updatedAt: String

    init(row: SQLiteRow) throws {
        dispatchID = try row.text("dispatch_id")
        state = try OrchestrationMessage.decodeEnum(WorkerDispatchState.self, row.text("state"), column: "state")
        stage = try row.text("stage")
        worktreeID = try row.textOrNil("worktree_id")
        agentTerminalHandle = try row.textOrNil("agent_terminal_handle")
        setupState = try row.text("setup_state")
        effects = try row.text("effects")
        residualResources = try row.text("residual_resources")
        startOptions = try row.text("start_options")
        lastError = try row.textOrNil("last_error")
        createdAt = try row.text("created_at")
        updatedAt = try row.text("updated_at")
    }
}

public struct WorkerTerminalResource: Equatable, Sendable {
    public let id: String
    public let originDispatchID: String
    public let ownerDispatchID: String
    public let worktreeID: String?
    public let terminalHandle: String
    public let paneKey: String?
    public let processIncarnation: String?
    public let ownershipState: WorkerTerminalOwnershipState
    public let releaseState: WorkerTerminalReleaseState
    public let retainedReason: String?
    public let releaseRequestedAt: String?
    public let releaseCompletedAt: String?
    public let releaseError: String?
    public let createdAt: String
    public let updatedAt: String

    init(row: SQLiteRow) throws {
        id = try row.text("id")
        originDispatchID = try row.text("origin_dispatch_id")
        ownerDispatchID = try row.text("owner_dispatch_id")
        worktreeID = try row.textOrNil("worktree_id")
        terminalHandle = try row.text("terminal_handle")
        paneKey = try row.textOrNil("pane_key")
        processIncarnation = try row.textOrNil("process_incarnation")
        ownershipState = try OrchestrationMessage.decodeEnum(
            WorkerTerminalOwnershipState.self, row.text("ownership_state"), column: "ownership_state")
        releaseState = try OrchestrationMessage.decodeEnum(
            WorkerTerminalReleaseState.self, row.text("release_state"), column: "release_state")
        retainedReason = try row.textOrNil("retained_reason")
        releaseRequestedAt = try row.textOrNil("release_requested_at")
        releaseCompletedAt = try row.textOrNil("release_completed_at")
        releaseError = try row.textOrNil("release_error")
        createdAt = try row.text("created_at")
        updatedAt = try row.text("updated_at")
    }
}

public struct WorkerTerminalArchive: Equatable, Sendable {
    public let dispatchID: String
    public let resourceID: String
    public let kind: WorkerTerminalArchiveKind
    public let content: String
    public let createdAt: String

    init(row: SQLiteRow) throws {
        dispatchID = try row.text("dispatch_id")
        resourceID = try row.text("resource_id")
        kind = try OrchestrationMessage.decodeEnum(WorkerTerminalArchiveKind.self, row.text("kind"), column: "kind")
        content = try row.text("content")
        createdAt = try row.text("created_at")
    }
}

public struct MutationReceipt: Equatable, Sendable {
    public let callerFingerprint: String
    public let requestID: String
    public let method: String
    public let payloadHash: String
    public let state: MutationState
    public let receipt: String?
    public let createdAt: String
    public let updatedAt: String

    init(row: SQLiteRow) throws {
        callerFingerprint = try row.text("caller_fingerprint")
        requestID = try row.text("request_id")
        method = try row.text("method")
        payloadHash = try row.text("payload_hash")
        state = try OrchestrationMessage.decodeEnum(MutationState.self, row.text("state"), column: "state")
        receipt = try row.textOrNil("receipt")
        createdAt = try row.text("created_at")
        updatedAt = try row.text("updated_at")
    }
}

public struct Question: Equatable, Sendable {
    public let messageID: String
    public let runID: String
    public let dispatchID: String
    public let askerHandle: String
    public let status: QuestionStatus
    public let answerMessageID: String?
    public let answerBody: String?
    public let answeredByGeneration: Int?
    public let createdAt: String
    public let answeredAt: String?
    public let closedAt: String?

    init(row: SQLiteRow) throws {
        messageID = try row.text("message_id")
        runID = try row.text("run_id")
        dispatchID = try row.text("dispatch_id")
        askerHandle = try row.text("asker_handle")
        status = try OrchestrationMessage.decodeEnum(QuestionStatus.self, row.text("status"), column: "status")
        answerMessageID = try row.textOrNil("answer_message_id")
        answerBody = try row.textOrNil("answer_body")
        answeredByGeneration = try row.intOrNil("answered_by_generation")
        createdAt = try row.text("created_at")
        answeredAt = try row.textOrNil("answered_at")
        closedAt = try row.textOrNil("closed_at")
    }
}

// MARK: - JSON helpers

/// Small JSON helpers for the columns that store JSON arrays/objects as TEXT.
enum JSONCoding {
    static func decodeStringArray(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let array = parsed as? [String] else {
            throw SQLiteError(message: "Expected JSON string array, got: \(json.prefix(80))")
        }
        return array
    }

    static func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Parse a payload column into a JSON object; nil when absent, empty, or not an object.
    static func decodeObject(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return nil
        }
        return object
    }

    static func encodeObject(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
