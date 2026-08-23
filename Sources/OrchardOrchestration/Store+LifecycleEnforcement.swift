import Foundation

// T11: capability-hash enforcement for lifecycle sends. A `worker_done`/`heartbeat`/
// `ask` addressing a LIVE dispatch must present the dispatch capability whose SHA-256
// matches `dispatch_contexts.capability_hash` AND originate from the assignee pane
// (docs/REBUILD-PLAN.md Wave 3, docs/research/orca-inventory.md §1.6). The checks are
// additive on top of T1: settled/unknown dispatches keep T1's reconciliation outcomes
// (suppression, `inactive_dispatch`, `unknown_dispatch`) untouched.

/// What a lifecycle send is allowed to do against its named dispatch.
public enum LifecycleSendAuthority: Equatable, Sendable {
    /// Capability and pane both proved; reconciliation may settle.
    case authorized
    /// No live dispatch is named — enforcement does not apply and T1's
    /// reconciliation owns the outcome (missing/unknown ids, settled dispatches).
    case notApplicable
    /// A typed enforcement violation. The message must never settle the dispatch.
    case rejected(code: String, reason: String)
}

extension OrchestrationStore {
    /// Orca's typed code for a lifecycle send failing capability verification
    /// (~/dev/orca/src/main/runtime/rpc/methods/orchestration.ts, dispatch-mutation
    /// authority). One code, differentiated by reason — missing secret, wrong secret,
    /// revoked capability, and wrong pane all read the same to a triaging coordinator.
    public static let dispatchCapabilityInvalidCode = "dispatch_capability_invalid"

    /// Verify a lifecycle sender's authority over a live dispatch: the capability
    /// secret must hash to the stored `capability_hash`, must not be revoked, and the
    /// sender's (remint-stable) pane key must be the recorded assignee pane. Payload
    /// knowledge alone — task/dispatch ids — is never authority.
    public func checkLifecycleSendAuthority(
        dispatchID: String?, capability: String?, senderPaneKey: String?
    ) throws -> LifecycleSendAuthority {
        guard let dispatchID, !dispatchID.isEmpty,
              let dispatch = try dispatchContext(dispatchID),
              dispatch.status == .pending || dispatch.status == .dispatched else {
            return .notApplicable
        }
        guard dispatch.capabilityHash != nil else {
            // Not capability-backed (no mint ever happened): T1's pane/handle
            // reconciliation authority owns the outcome, as in Orca's send path.
            return .notApplicable
        }
        guard let capability, !capability.isEmpty else {
            return .rejected(
                code: Self.dispatchCapabilityInvalidCode,
                reason: "Lifecycle sends for Dispatch \(dispatchID) must present --dispatch-capability.")
        }
        // Revocation, hash comparison, and the (remint-stable) pane check — a
        // reissued handle on the SAME pane still proves out; a different pane, or
        // the right secret from the wrong pane, never does.
        let verdict = try verifyDispatchCapability(
            dispatchID: dispatchID, capability: capability, paneKey: senderPaneKey)
        guard verdict.valid else {
            return .rejected(code: Self.dispatchCapabilityInvalidCode, reason: verdict.reason)
        }
        return .authorized
    }

    /// Persist a lifecycle message that failed capability enforcement, converted to
    /// its typed rejection in the same transaction — auditable in history, never
    /// actionable as a completion/liveness event, and it never settles the dispatch.
    public func recordRejectedLifecycleSend(
        _ outbound: OutboundMessage, code: String, reason: String
    ) throws -> SendReceipt {
        let to = outbound.to ?? "run:\(outbound.runID)"
        let message: OrchestrationMessage = try db.inTransaction {
            let inserted = try insertMessage(MessageInsert(
                from: outbound.from,
                to: to,
                subject: outbound.subject,
                body: outbound.body,
                type: outbound.type,
                priority: outbound.priority,
                threadID: outbound.threadID,
                payload: outbound.payload,
                senderPaneKey: outbound.senderPaneKey,
                runID: outbound.runID))
            _ = try convertLifecycleMessageToRejection(inserted.id, code: code, reason: reason)
            return try requireMessage(inserted.id)
        }
        // The coordinator should see the rejected report (same wake behavior as a
        // reconciliation-time rejection).
        notifyMessageArrived(message.toHandle, message.type)
        return SendReceipt(messages: [message],
                           lifecycle: .rejected(code: code, reason: reason))
    }
}
