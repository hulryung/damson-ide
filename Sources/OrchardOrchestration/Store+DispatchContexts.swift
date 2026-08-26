import Foundation
import CryptoKit

// Dispatch contexts: one *attempt* assigning one Task to one terminal — lifecycle
// authority lives here (docs/research/orca-inventory.md §1.1). Ported from
// ~/dev/orca/src/main/runtime/orchestration/db/dispatch-context/
// {dispatch-context-store,dispatch-completion,dispatch-capability}.ts.
extension OrchestrationStore {
    /// Claim a ready task for a terminal. Fails if the task isn't `ready` or the
    /// assignee (by handle or pane key) already holds an active dispatch — the pane
    /// check keeps a reminted handle from opening a second concurrent dispatch on the
    /// same pane. `failure_count` carries forward the task's prior maximum so the
    /// circuit breaker accumulates across retries.
    @discardableResult
    public func createDispatchContext(
        taskID: String,
        assigneeHandle: String,
        assigneePaneKey: String? = nil,
        launchTokenHash: String? = nil,
        processIncarnation: String? = nil
    ) throws -> DispatchContext {
        let task = try requireTask(taskID)
        guard task.status == .ready else {
            throw OrchestrationError(
                "task_not_startable",
                "Task \(taskID) is \(task.status.rawValue); only ready tasks can be dispatched."
            )
        }
        if let existing = try activeDispatchForAssignee(handle: assigneeHandle, paneKey: assigneePaneKey) {
            throw OrchestrationError(
                "task_not_startable",
                "Terminal \(assigneeHandle) already has an active dispatch (\(existing.id) for task \(existing.taskID))."
            )
        }
        let priorFailures = try (db.queryOne(
            "SELECT COALESCE(MAX(failure_count), 0) AS max_failures FROM dispatch_contexts WHERE task_id = ?",
            [.text(taskID)]
        )?.int("max_failures")) ?? 0

        let id = generateID("ctx")
        return try db.inSavepoint("create_dispatch_context") {
            // The claim re-checks readiness and assignee occupancy inside one INSERT…SELECT
            // so two concurrent dispatch attempts can't both claim the task or the terminal.
            let inserted = try db.run(
                """
                INSERT INTO dispatch_contexts (
                  id, run_id, task_id, launch_token_hash,
                  assignee_handle, assignee_pane_key, process_incarnation,
                  status, failure_count, dispatched_at
                )
                SELECT ?, run_id, id, ?, ?, ?, ?, 'dispatched', ?, datetime('now')
                FROM tasks
                WHERE id = ? AND status = 'ready'
                  AND NOT EXISTS (
                    SELECT 1 FROM dispatch_contexts active
                    WHERE active.assignee_handle = ?
                      AND active.status IN ('pending', 'dispatched')
                  )
                  AND (
                    ? IS NULL OR NOT EXISTS (
                      SELECT 1 FROM dispatch_contexts active
                      WHERE active.assignee_pane_key = ?
                        AND active.status IN ('pending', 'dispatched')
                    )
                  )
                """,
                [
                    .text(id), .maybeText(launchTokenHash), .text(assigneeHandle),
                    .maybeText(assigneePaneKey), .maybeText(processIncarnation),
                    .int(Int64(priorFailures)), .text(taskID), .text(assigneeHandle),
                    .maybeText(assigneePaneKey), .maybeText(assigneePaneKey),
                ]
            )
            guard inserted == 1 else {
                throw OrchestrationError(
                    "task_not_startable",
                    "Task \(taskID) could not be claimed (raced by another dispatch or no longer ready)."
                )
            }
            try db.run("UPDATE tasks SET status = 'dispatched' WHERE id = ?", [.text(taskID)])
            return try requireDispatchContext(id)
        }
    }

    public func dispatchContext(_ id: String) throws -> DispatchContext? {
        guard let row = try db.queryOne("SELECT * FROM dispatch_contexts WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try DispatchContext(row: row)
    }

    func requireDispatchContext(_ id: String) throws -> DispatchContext {
        guard let context = try dispatchContext(id) else {
            throw OrchestrationError("dispatch_not_found", "Dispatch \(id) was not found.")
        }
        return context
    }

    /// Most recent dispatch row for a task (any status) — `dispatch-show`'s backing.
    public func latestDispatchContext(taskID: String) throws -> DispatchContext? {
        guard let row = try db.queryOne(
            "SELECT * FROM dispatch_contexts WHERE task_id = ? ORDER BY rowid DESC LIMIT 1",
            [.text(taskID)]
        ) else { return nil }
        return try DispatchContext(row: row)
    }

    public func activeDispatchForTask(_ taskID: String) throws -> DispatchContext? {
        guard let row = try db.queryOne(
            """
            SELECT * FROM dispatch_contexts
            WHERE task_id = ? AND status IN ('pending', 'dispatched')
            ORDER BY rowid DESC LIMIT 1
            """,
            [.text(taskID)]
        ) else { return nil }
        return try DispatchContext(row: row)
    }

    /// Public so the RPC adapter can resolve a worker's live dispatch from its
    /// terminal identity (`ask` with no explicit ids, worker-mode `check`).
    public func activeDispatchForAssignee(handle: String, paneKey: String?) throws -> DispatchContext? {
        if let row = try db.queryOne(
            """
            SELECT * FROM dispatch_contexts
            WHERE assignee_handle = ? AND status IN ('pending', 'dispatched')
            ORDER BY rowid DESC LIMIT 1
            """,
            [.text(handle)]
        ) {
            return try DispatchContext(row: row)
        }
        guard let paneKey else { return nil }
        guard let row = try db.queryOne(
            """
            SELECT * FROM dispatch_contexts
            WHERE assignee_pane_key = ? AND status IN ('pending', 'dispatched')
            ORDER BY rowid DESC LIMIT 1
            """,
            [.text(paneKey)]
        ) else { return nil }
        return try DispatchContext(row: row)
    }

    /// Record one dispatch failure. On the 3rd accumulated failure the dispatch becomes
    /// `circuit_broken` and the task `failed`; below that the task returns to `ready`
    /// (not `pending` — `pending` would strand it, since promotion only runs when a dep
    /// completes). Refuses while a live supervised worker still owns the dispatch unless
    /// `workerProcessExited` says the process is already gone.
    @discardableResult
    public func failDispatch(
        _ dispatchID: String,
        error: String,
        workerProcessExited: Bool = false,
        terminationReason: String? = nil,
        /// The stage the worker row records. `process_exited` is a claim that the
        /// process is gone, so a remote pane whose *connection* dropped passes
        /// `connection_lost` instead — loss of contact is not evidence of death
        /// (docs/design/remote-hosts.md §1, rule 2).
        workerStage: String = "process_exited"
    ) throws -> DispatchContext? {
        try db.inSavepoint("fail_dispatch") {
            let changes = try db.run(
                """
                UPDATE dispatch_contexts
                SET status = CASE WHEN failure_count + 1 >= ? THEN 'circuit_broken' ELSE 'failed' END,
                    failure_count = failure_count + 1, last_failure = ?,
                    termination_reason = COALESCE(?, termination_reason),
                    completed_at = COALESCE(completed_at, datetime('now')),
                    capability_revoked_at = COALESCE(capability_revoked_at, datetime('now'))
                WHERE id = ? AND status IN ('pending', 'dispatched')
                  AND (? = 1 OR NOT EXISTS (
                    SELECT 1 FROM worker_dispatches worker
                    WHERE worker.dispatch_id = dispatch_contexts.id
                      AND worker.state NOT IN ('failed', 'succeeded', 'stopped', 'abandoned')
                  ))
                """,
                [
                    .int(Int64(Self.dispatchCircuitBreakFailures)), .text(error),
                    .maybeText(terminationReason), .text(dispatchID),
                    .int(workerProcessExited ? 1 : 0),
                ]
            )
            let context = try dispatchContext(dispatchID)
            let worker = try workerDispatch(dispatchID)
            if changes != 1 || context == nil {
                if context != nil, let worker, !worker.state.isSettled, !workerProcessExited {
                    throw OrchestrationError(
                        "task_not_startable",
                        "Dispatch \(dispatchID) has an active supervised worker; stop it or settle its report first."
                    )
                }
                return context
            }
            guard let context else { return nil }
            if worker != nil, workerProcessExited {
                try db.run(
                    """
                    UPDATE worker_dispatches
                    SET state = 'failed', stage = ?, last_error = ?, updated_at = datetime('now')
                    WHERE dispatch_id = ?
                      AND state NOT IN ('failed', 'succeeded', 'stopped', 'abandoned')
                    """,
                    [.text(workerStage), .text(error), .text(dispatchID)]
                )
            }
            let taskStatus: TaskStatus = context.status == .circuitBroken ? .failed : .ready
            // The status guard keeps a late failure from reopening a task already
            // completed or retried elsewhere.
            try db.run(
                """
                UPDATE tasks SET status = ?
                WHERE id = ? AND status = 'dispatched' AND NOT EXISTS (
                  SELECT 1 FROM dispatch_contexts
                  WHERE task_id = tasks.id AND status IN ('pending', 'dispatched')
                )
                """,
                [.text(taskStatus.rawValue), .text(context.taskID)]
            )
            return try dispatchContext(dispatchID)
        }
    }

    /// Complete one dispatch. The status guard keeps a late completion from reviving a
    /// dispatch already failed or circuit-broken.
    public func completeDispatch(_ dispatchID: String) throws {
        try db.run(
            """
            UPDATE dispatch_contexts
            SET status = 'completed', completed_at = datetime('now'),
                capability_revoked_at = COALESCE(capability_revoked_at, datetime('now'))
            WHERE id = ? AND status IN ('pending', 'dispatched')
            """,
            [.text(dispatchID)]
        )
    }

    /// Settle every still-active dispatch of a task with the task's terminal status.
    func settleActiveDispatchesForTask(
        _ taskID: String, status: DispatchStatus, failure: String? = nil
    ) throws {
        try db.run(
            """
            UPDATE dispatch_contexts
            SET status = ?, completed_at = COALESCE(completed_at, datetime('now')),
                last_failure = CASE
                  WHEN ? = 'failed' THEN COALESCE(?, last_failure, 'Task marked failed')
                  ELSE last_failure
                END,
                capability_revoked_at = COALESCE(capability_revoked_at, datetime('now'))
            WHERE task_id = ? AND status IN ('pending', 'dispatched')
            """,
            [.text(status.rawValue), .text(status.rawValue), .maybeText(failure), .text(taskID)]
        )
    }

    func completeActiveDispatchesForTask(_ taskID: String) throws {
        try settleActiveDispatchesForTask(taskID, status: .completed)
    }

    // MARK: - Heartbeats & staleness

    /// Record a heartbeat. Only bumps `status = 'dispatched'` rows — a zombie heartbeat
    /// from a finished dispatch must not mask a hung retry from the stale detector.
    public func recordHeartbeat(dispatchID: String, at timestamp: String) throws {
        try db.run(
            "UPDATE dispatch_contexts SET last_heartbeat_at = ? WHERE id = ? AND status = 'dispatched'",
            [.text(timestamp), .text(dispatchID)]
        )
    }

    /// Dispatches whose worker has been silent past the 10-minute threshold. This is a
    /// warning flag ONLY — callers log it; nothing here (or anywhere) auto-fails on it,
    /// because a false positive (slow but correct worker) costs more than a false
    /// negative (docs/research/orca-inventory.md §1.8). `julianday` comparison keeps
    /// space-format timestamps ordering correctly.
    public func staleDispatches(now: Date = Date()) throws -> [DispatchContext] {
        let threshold = Self.sqliteTimestamp(now.addingTimeInterval(-Self.heartbeatStaleInterval))
        return try db.query(
            """
            SELECT * FROM dispatch_contexts
            WHERE status = 'dispatched'
              AND dispatched_at IS NOT NULL
              AND julianday(dispatched_at) < julianday(?)
              AND (last_heartbeat_at IS NULL OR julianday(last_heartbeat_at) < julianday(?))
            """,
            [.text(threshold), .text(threshold)]
        ).map(DispatchContext.init)
    }

    /// The per-dispatch form of the staleness warning flag.
    public func isHeartbeatStale(_ dispatch: DispatchContext, now: Date = Date()) throws -> Bool {
        try staleDispatches(now: now).contains { $0.id == dispatch.id }
    }

    // MARK: - Dispatch capability

    /// Mint the per-dispatch secret handed to the worker (`--dispatch-capability`).
    /// Only its SHA-256 is stored; combined with `assignee_pane_key` it proves a
    /// `worker_done` came from the actual dispatched pane (§1.6).
    public func mintDispatchCapability(dispatchID: String) throws -> String {
        _ = try requireDispatchContext(dispatchID)
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        let capability = "dcap_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try db.run(
            "UPDATE dispatch_contexts SET capability_hash = ? WHERE id = ?",
            [.text(Self.sha256Hex(capability)), .text(dispatchID)]
        )
        return capability
    }

    public func verifyDispatchCapability(
        dispatchID: String, capability: String?, paneKey: String?
    ) throws -> (valid: Bool, reason: String) {
        guard let dispatch = try dispatchContext(dispatchID) else {
            return (false, "Unknown dispatch \(dispatchID).")
        }
        guard let expectedHash = dispatch.capabilityHash else {
            return (false, "Dispatch \(dispatchID) has no minted capability.")
        }
        if dispatch.capabilityRevokedAt != nil {
            return (false, "Dispatch \(dispatchID) capability was revoked.")
        }
        guard let capability, Self.sha256Hex(capability) == expectedHash else {
            return (false, "Dispatch capability does not match \(dispatchID).")
        }
        if let assigneePane = dispatch.assigneePaneKey, assigneePane != paneKey {
            return (false, "Dispatch \(dispatchID) capability presented from the wrong pane.")
        }
        return (true, "")
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
