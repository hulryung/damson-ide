import Foundation

// Reconciling lifecycle messages (`worker_done`, `heartbeat`) as they land: worker_done
// auto-completes its task+dispatch through settlement; heartbeats refresh dispatch
// liveness. Everything is keyed on the payload's (taskId, dispatchId) and gated on
// lifecycle authority — payload knowledge alone never settles anything. Ported from
// ~/dev/orca/src/main/runtime/orchestration/lifecycle-reconciliation.ts.
extension OrchestrationStore {
    /// Reconcile a just-inserted lifecycle message. Runs inside the send transaction.
    func reconcileLifecycleMessage(_ message: OrchestrationMessage) throws -> LifecycleReconciliation {
        switch message.type {
        case .workerDone:
            return try reconcileWorkerDone(message)
        case .heartbeat:
            return try reconcileHeartbeat(message)
        case .status, .dispatch, .mergeReady, .escalation, .handoff, .decisionGate, .question:
            return .ignored
        }
    }

    private func reconcileHeartbeat(_ message: OrchestrationMessage) throws -> LifecycleReconciliation {
        guard let payload = JSONCoding.decodeObject(message.payload) else {
            return .ignored
        }
        if let persisted = Self.persistedLifecycleRejection(in: payload) {
            return .rejected(code: persisted.code, reason: persisted.reason)
        }
        guard let dispatchID = payload["dispatchId"] as? String, !dispatchID.isEmpty else {
            return .ignored
        }
        guard let dispatch = try dispatchContext(dispatchID), dispatch.status == .dispatched else {
            // An in-flight heartbeat can arrive after completion; retain it for audit
            // history without surfacing obsolete liveness to the coordinator.
            try markAsReadAndDelivered([message.id])
            return .suppressed
        }
        guard hasLifecycleAuthority(dispatch: dispatch, message: message) else {
            // A wrong-pane heartbeat must not refresh liveness — it would mask a hung
            // assignee behind another agent's timer.
            let reason = Self.lifecycleAuthorityRejectionReason(dispatchID: dispatchID, dispatch: dispatch, message: message)
            try convertLifecycleMessageToRejection(message.id, code: "sender_not_assignee", reason: reason)
            return .rejected(code: "sender_not_assignee", reason: reason)
        }
        try recordHeartbeat(dispatchID: dispatchID, at: message.createdAt)
        return .heartbeatRecorded(dispatchID: dispatchID)
    }

    private func reconcileWorkerDone(_ message: OrchestrationMessage) throws -> LifecycleReconciliation {
        guard let payload = JSONCoding.decodeObject(message.payload) else {
            return try reject(message, code: "invalid_payload",
                              reason: "worker_done requires a JSON object payload.")
        }
        if let persisted = Self.persistedLifecycleRejection(in: payload) {
            return .rejected(code: persisted.code, reason: persisted.reason)
        }
        guard let taskID = payload["taskId"] as? String, !taskID.isEmpty else {
            return try reject(message, code: "missing_task_id", reason: "worker_done requires taskId.")
        }
        guard let dispatchID = payload["dispatchId"] as? String, !dispatchID.isEmpty else {
            return try reject(message, code: "missing_dispatch_id", reason: "worker_done requires dispatchId.")
        }
        guard let outcomeRaw = payload["outcome"] as? String,
              let outcome = WorkerReportOutcome(rawValue: outcomeRaw) else {
            return try reject(message, code: "invalid_outcome",
                              reason: "worker_done requires outcome=succeeded or outcome=failed.")
        }
        guard try task(taskID) != nil else {
            return try reject(message, code: SettlementRejectionCode.unknownTask.rawValue,
                              reason: "worker_done references unknown task \(taskID).")
        }
        // taskId alone is not a completion authority; retried tasks can have stale
        // worker_done messages racing the current active dispatch.
        guard let dispatch = try dispatchContext(dispatchID) else {
            return try reject(message, code: SettlementRejectionCode.unknownDispatch.rawValue,
                              reason: "worker_done references unknown dispatch \(dispatchID).")
        }
        if dispatch.taskID != taskID {
            return try reject(
                message, code: SettlementRejectionCode.taskDispatchMismatch.rawValue,
                reason: "worker_done dispatch \(dispatchID) belongs to \(dispatch.taskID), not \(taskID).")
        }
        guard hasLifecycleAuthority(dispatch: dispatch, message: message) else {
            let reason = Self.lifecycleAuthorityRejectionReason(dispatchID: dispatchID, dispatch: dispatch, message: message)
            try convertLifecycleMessageToRejection(message.id, code: "sender_not_assignee", reason: reason)
            return .rejected(code: "sender_not_assignee", reason: reason)
        }

        let filesModified = (payload["filesModified"] as? [String]) ?? []
        let result = JSONCoding.encodeObject([
            "provenance": "worker_report",
            "outcome": outcome.rawValue,
            "messageId": message.id,
            "reportedBy": message.fromHandle,
            "subject": message.subject,
            "body": message.body,
            "filesModified": filesModified,
            "reportPath": (payload["reportPath"] as? String) as Any,
            "completedAt": OrchestrationStore.sqliteTimestamp(Date()),
        ])
        let settlement = try settleWorkerReportInTransaction(
            taskID: taskID, dispatchID: dispatchID, outcome: outcome, result: result)
        switch settlement {
        case .rejected(let code, let reason):
            return try reject(message, code: code.rawValue, reason: reason)
        case .settled(let outcome, _):
            try suppressEarlierHeartbeats(before: message, dispatchID: dispatchID)
            return outcome == .failed
                ? .failed(taskID: taskID, dispatchID: dispatchID)
                : .completed(taskID: taskID, dispatchID: dispatchID)
        }
    }

    private func reject(
        _ message: OrchestrationMessage, code: String, reason: String
    ) throws -> LifecycleReconciliation {
        try convertLifecycleMessageToRejection(message.id, code: code, reason: reason)
        return .rejected(code: code, reason: reason)
    }

    /// Lifecycle authority: the pane key recorded at dispatch time (remint-stable) when
    /// present; rows without pane identity can only use the exact handle recorded at
    /// dispatch. Payload knowledge alone is not authority.
    func hasLifecycleAuthority(dispatch: DispatchContext, message: OrchestrationMessage) -> Bool {
        if let assigneePane = dispatch.assigneePaneKey {
            return message.senderPaneKey == assigneePane
        }
        return dispatch.assigneeHandle == message.fromHandle
    }

    static func lifecycleAuthorityRejectionReason(
        dispatchID: String, dispatch: DispatchContext, message: OrchestrationMessage
    ) -> String {
        "dispatch \(dispatchID) expected handle \(dispatch.assigneeHandle ?? "<unknown>"), "
            + "pane \(dispatch.assigneePaneKey ?? "<none>"); received handle \(message.fromHandle), "
            + "pane \(message.senderPaneKey ?? "<missing>")"
    }

    /// After a worker_done settles, its dispatch's earlier unread heartbeats are noise:
    /// mark them consumed so the coordinator's next batch leads with the completion.
    private func suppressEarlierHeartbeats(before workerDone: OrchestrationMessage, dispatchID: String) throws {
        let heartbeatIDs = try unreadMessages(to: workerDone.toHandle, types: [.heartbeat])
            .filter { candidate in
                guard candidate.sequence < workerDone.sequence,
                      let payload = JSONCoding.decodeObject(candidate.payload) else {
                    return false
                }
                return payload["dispatchId"] as? String == dispatchID
            }
            .map(\.id)
        try markAsReadAndDelivered(heartbeatIDs)
    }
}
