import Foundation

/// Outcome of opening a mutation receipt for `(callerFingerprint, requestID)`.
public enum MutationReceiptDisposition: Equatable, Sendable {
    /// New request — run the mutation, then `completeMutationReceipt`.
    case started(MutationReceipt)
    /// A prior attempt began but never completed (crash mid-mutation); the caller
    /// decides whether to re-run after `discardPendingMutationReceipt`.
    case pending(MutationReceipt)
    /// Exact retry of a completed request — return `receipt` verbatim, run nothing.
    case completed(MutationReceipt)
}

// `--retry-request` idempotency: receipts keyed on (caller_fingerprint, request_id) with
// a payload hash make exact retries safe on every mutating command
// (docs/research/orca-inventory.md §1.5, §8 item 4). Ported from
// ~/dev/orca/.../db/mutation-receipts/mutation-receipt-store.ts.
extension OrchestrationStore {
    /// Stable identity for local callers, minted once and persisted, so retry receipts
    /// survive process restarts.
    public func localMutationCallerFingerprint() throws -> String {
        let transport = "local_authenticated_transport"
        if let existing = try db.queryOne(
            "SELECT caller_fingerprint FROM mutation_caller_identities WHERE transport = ?",
            [.text(transport)]
        ) {
            return try existing.text("caller_fingerprint")
        }
        let fingerprint = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try db.run(
            "INSERT OR IGNORE INTO mutation_caller_identities (transport, caller_fingerprint) VALUES (?, ?)",
            [.text(transport), .text(fingerprint)]
        )
        guard let created = try db.queryOne(
            "SELECT caller_fingerprint FROM mutation_caller_identities WHERE transport = ?",
            [.text(transport)]
        ) else {
            throw OrchestrationError(
                "internal", "Failed to create the local mutation caller identity.")
        }
        return try created.text("caller_fingerprint")
    }

    /// Open (or find) the receipt for a request. Reusing a request ID with a different
    /// method or payload is `request_mismatch` — a retry must be byte-identical to be safe.
    public func beginMutationReceipt(
        callerFingerprint: String,
        requestID: String,
        method: String,
        payloadHash: String
    ) throws -> MutationReceiptDisposition {
        try db.inTransaction {
            if let existing = try mutationReceipt(
                callerFingerprint: callerFingerprint, requestID: requestID) {
                guard existing.method == method, existing.payloadHash == payloadHash else {
                    throw OrchestrationError(
                        "request_mismatch",
                        "Mutation request \(requestID) was already used with different input."
                    )
                }
                return existing.state == .completed ? .completed(existing) : .pending(existing)
            }
            try db.run(
                """
                INSERT INTO mutation_receipts (
                  caller_fingerprint, request_id, method, payload_hash, state
                ) VALUES (?, ?, ?, ?, 'pending')
                """,
                [.text(callerFingerprint), .text(requestID), .text(method), .text(payloadHash)]
            )
            guard let created = try mutationReceipt(
                callerFingerprint: callerFingerprint, requestID: requestID) else {
                throw OrchestrationError("internal", "Mutation receipt insert did not persist.")
            }
            return .started(created)
        }
    }

    @discardableResult
    public func completeMutationReceipt(
        callerFingerprint: String,
        requestID: String,
        method: String,
        payloadHash: String,
        receipt: String
    ) throws -> MutationReceipt {
        let changes = try db.run(
            """
            UPDATE mutation_receipts
            SET state = 'completed', receipt = ?, updated_at = datetime('now')
            WHERE caller_fingerprint = ? AND request_id = ? AND method = ? AND payload_hash = ?
            """,
            [.text(receipt), .text(callerFingerprint), .text(requestID), .text(method), .text(payloadHash)]
        )
        guard changes == 1, let row = try mutationReceipt(
            callerFingerprint: callerFingerprint, requestID: requestID) else {
            throw OrchestrationError(
                "request_mismatch",
                "Mutation request \(requestID) no longer matches its pending operation."
            )
        }
        return row
    }

    public func discardPendingMutationReceipt(callerFingerprint: String, requestID: String) throws {
        try db.run(
            "DELETE FROM mutation_receipts WHERE caller_fingerprint = ? AND request_id = ? AND state = 'pending'",
            [.text(callerFingerprint), .text(requestID)]
        )
    }

    public func mutationReceipt(callerFingerprint: String, requestID: String) throws -> MutationReceipt? {
        guard let row = try db.queryOne(
            "SELECT * FROM mutation_receipts WHERE caller_fingerprint = ? AND request_id = ?",
            [.text(callerFingerprint), .text(requestID)]
        ) else { return nil }
        return try MutationReceipt(row: row)
    }

    /// Convenience wrapper the RPC layer uses per mutating command: exact retry returns
    /// the stored receipt without re-running `operation`; a fresh request runs it and
    /// records the result. A failed operation discards the pending receipt so the caller
    /// may retry with the same request ID.
    public func performIdempotentMutation(
        callerFingerprint: String,
        requestID: String,
        method: String,
        payload: String,
        operation: () throws -> String
    ) throws -> (receipt: String, replayed: Bool) {
        let payloadHash = Self.sha256Hex(payload)
        switch try beginMutationReceipt(
            callerFingerprint: callerFingerprint, requestID: requestID,
            method: method, payloadHash: payloadHash) {
        case .completed(let existing):
            return (existing.receipt ?? "", true)
        case .pending, .started:
            do {
                let result = try operation()
                try completeMutationReceipt(
                    callerFingerprint: callerFingerprint, requestID: requestID,
                    method: method, payloadHash: payloadHash, receipt: result)
                return (result, false)
            } catch {
                try? discardPendingMutationReceipt(
                    callerFingerprint: callerFingerprint, requestID: requestID)
                throw error
            }
        }
    }
}
