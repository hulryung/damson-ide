import Foundation

/// One `send` from an agent, before recipient resolution. `payload` is a JSON object
/// string; lifecycle sends carry `taskId`/`dispatchId`/`outcome`/… inside it (the CLI
/// flags `--task-id --dispatch-id --outcome --files-modified --report-path --phase` are
/// sugar the RPC layer folds into this payload, as in Orca).
public struct OutboundMessage: Sendable {
    public var from: String
    public var senderPaneKey: String?
    /// `handle`, `run:<id>`, `dispatch:<id>`, or a `@group` address. When nil, the
    /// message routes to `run:<runID>`.
    public var to: String?
    public var runID: String
    public var subject: String
    public var body: String
    public var type: MessageType
    public var priority: MessagePriority
    public var threadID: String?
    public var payload: String?

    public init(
        from: String,
        senderPaneKey: String? = nil,
        to: String? = nil,
        runID: String,
        subject: String,
        body: String = "",
        type: MessageType = .status,
        priority: MessagePriority = .normal,
        threadID: String? = nil,
        payload: String? = nil
    ) {
        self.from = from
        self.senderPaneKey = senderPaneKey
        self.to = to
        self.runID = runID
        self.subject = subject
        self.body = body
        self.type = type
        self.priority = priority
        self.threadID = threadID
        self.payload = payload
    }
}

/// What a `send` produced: the inserted row(s), plus the lifecycle reconciliation when
/// the message was a `worker_done`/`heartbeat`.
public struct SendReceipt: Equatable, Sendable {
    public let messages: [OrchestrationMessage]
    public let lifecycle: LifecycleReconciliation?
}

// The send path: group forbidding + expansion, single-recipient insert, lifecycle
// reconciliation, and waiter wake-up. Semantics ported from
// ~/dev/orca/src/main/runtime/rpc/methods/orchestration.ts (orchestration.send).
extension OrchestrationStore {
    /// Dispatch lifecycle messages are authority/liveness signals for one coordinator;
    /// fanning them out would create lifecycle mail in unrelated terminals, so group
    /// addressing is forbidden for all of them (the plan calls out worker_done/heartbeat;
    /// orca also forbids escalation/decision_gate and we match it).
    static let dispatchMutationMessageTypes: Set<MessageType> = [
        .workerDone, .heartbeat, .escalation, .decisionGate,
    ]

    /// Send one message. Group addresses expand at send time into one row per recipient
    /// sharing a thread_id; `worker_done`/`heartbeat` reconcile against their dispatch
    /// inside the same transaction (worker_done auto-completes task+dispatch).
    @discardableResult
    public func sendMessage(
        _ outbound: OutboundMessage,
        terminals: [TerminalDirectoryEntry] = [],
        agentStatus: (String) -> String? = { _ in nil }
    ) throws -> SendReceipt {
        let to = outbound.to ?? "run:\(outbound.runID)"

        if Self.dispatchMutationMessageTypes.contains(outbound.type), GroupAddress.isGroupAddress(to) {
            throw OrchestrationError(
                "invalid_argument",
                "\(outbound.type.rawValue) messages belong to one exact Dispatch and cannot target a group address."
            )
        }
        if to.hasPrefix("task:") {
            throw OrchestrationError(
                "invalid_argument",
                "Task recipients are intentionally unsupported; use run:<id> or dispatch:<id>."
            )
        }
        if outbound.type == .workerDone {
            let payload = JSONCoding.decodeObject(outbound.payload) ?? [:]
            let outcome = payload["outcome"] as? String
            guard let outcome, WorkerReportOutcome(rawValue: outcome) != nil else {
                throw OrchestrationError(
                    "invalid_argument",
                    "worker_done requires outcome=succeeded|failed for a current Dispatch."
                )
            }
        }

        if GroupAddress.isGroupAddress(to) {
            return try sendToGroup(outbound, to: to, terminals: terminals, agentStatus: agentStatus)
        }

        // Point-to-point: insert + reconcile atomically, notify after commit so a woken
        // waiter can always read what woke it.
        let receipt: SendReceipt = try db.inTransaction {
            let message = try insertMessage(MessageInsert(
                from: outbound.from,
                to: to,
                subject: outbound.subject,
                body: outbound.body,
                type: outbound.type,
                priority: outbound.priority,
                threadID: outbound.threadID,
                payload: outbound.payload,
                senderPaneKey: outbound.senderPaneKey,
                runID: outbound.runID
            ))
            guard message.type == .workerDone || message.type == .heartbeat else {
                return SendReceipt(messages: [message], lifecycle: nil)
            }
            let lifecycle = try reconcileLifecycleMessage(message)
            let current = try requireMessage(message.id)
            return SendReceipt(messages: [current], lifecycle: lifecycle)
        }
        // A suppressed row is already read — waking a waiter for it would deliver nothing.
        if receipt.lifecycle != .suppressed, let message = receipt.messages.first {
            notifyMessageArrived(message.toHandle, message.type)
        }
        return receipt
    }

    private func sendToGroup(
        _ outbound: OutboundMessage,
        to: String,
        terminals: [TerminalDirectoryEntry],
        agentStatus: (String) -> String?
    ) throws -> SendReceipt {
        let handles = GroupAddress.resolve(
            to, senderHandle: outbound.from, terminals: terminals, agentStatus: agentStatus)
        guard !handles.isEmpty else {
            throw OrchestrationError(
                "terminal_not_found", "No recipients resolved for group address: \(to)")
        }
        // One row per recipient (independent read-tracking), one shared thread_id
        // (correlation) — §1.4's group contract.
        let threadID = outbound.threadID ?? generateID("thread")
        let messages: [OrchestrationMessage] = try db.inTransaction {
            try handles.map { handle in
                try insertMessage(MessageInsert(
                    from: outbound.from,
                    to: handle,
                    subject: outbound.subject,
                    body: outbound.body,
                    type: outbound.type,
                    priority: outbound.priority,
                    threadID: threadID,
                    payload: outbound.payload,
                    senderPaneKey: outbound.senderPaneKey,
                    runID: outbound.runID
                ))
            }
        }
        for message in messages {
            notifyMessageArrived(message.toHandle, message.type)
        }
        return SendReceipt(messages: messages, lifecycle: nil)
    }
}
