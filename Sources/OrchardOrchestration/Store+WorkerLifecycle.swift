import Foundation

// Supervised-worker lifecycle transitions for the worker-* verbs (T7), additive on top
// of the T1 worker tables. Ported from ~/dev/orca/src/main/runtime/orchestration/db/
// worker-dispatch/{worker-dispatch-start,worker-dispatch-outcome,worker-dispatch-stop,
// worker-dispatch-abandon}.ts and db/worker-terminal/{worker-terminal-release,
// worker-terminal-listing}.ts, minus federation and cross-runtime epochs (v2 runs the
// verbs in-process against the live registry).

/// What `beginWorkerStop` found — the RPC layer branches on this to decide whether a
/// process action is still owed.
public enum WorkerStopBegin: Sendable {
    case stopping(WorkerDispatch)
    case alreadySettled(WorkerDispatch)
    /// The dispatch has no worker_dispatches row (`dispatch --inject` path): the
    /// assignment settles, but no process is ever touched.
    case contextOnly(state: String, alreadySettled: Bool, releasedCurrentTask: Bool)
}

public enum WorkerAbandonResult: Sendable {
    case abandoned(WorkerDispatch)
    case alreadyAbandoned(WorkerDispatch)
    /// The dispatch is no longer the task's current attempt; nothing changed.
    case stale(WorkerDispatch)
    case contextOnly(state: String, alreadySettled: Bool, releasedCurrentTask: Bool)
}

public enum WorkerReleaseRequest: Sendable {
    case requested(WorkerTerminalResource)
    case alreadyReleased(WorkerTerminalResource)
    case retained(WorkerTerminalResource?, reason: String)
}

public enum WorkerRetainResult: Sendable {
    case retained(WorkerTerminalResource)
    case alreadyReleased(WorkerTerminalResource)
    case noOwnedResource
    /// Release was already durably committed (`releasing`/`unknown`) and cannot be
    /// walked back to retained.
    case releaseCommitted(WorkerTerminalResource)
}

/// One `worker-list` row: dispatch + worker state + owned terminal resource.
/// `workerState` is `"unsupervised"` for context-only dispatches (no worker row).
public struct WorkerListRow: Sendable {
    public let dispatchID: String
    public let taskID: String
    public let runID: String
    public let workerState: String
    public let dispatchStatus: DispatchStatus
    public let agentTerminalHandle: String?
    public let resource: WorkerTerminalResource?
}

extension OrchestrationStore {
    // MARK: - worker-start transitions

    /// Accept a worker-start: dispatch row `pending` with no assignee yet (the agent
    /// terminal does not exist until later stages bind it), worker row
    /// `starting/accepted`, task → `dispatched`. `retryOf` allows restarting a task
    /// whose prior supervised attempt settled (failed/stopped/abandoned) without the
    /// task being `ready` again.
    public func createStartingWorkerDispatch(
        taskID: String,
        startOptions: String = "{}",
        retryOf: String? = nil
    ) throws -> (dispatch: DispatchContext, worker: WorkerDispatch) {
        try db.inTransaction {
            let task = try requireTask(taskID)
            if let retryOf {
                let prior = try dispatchContext(retryOf)
                let priorWorker = try workerDispatch(retryOf)
                let latest = try latestDispatchContext(taskID: taskID)
                guard let prior, prior.taskID == taskID, latest?.id == prior.id,
                      let priorWorker, priorWorker.state.isSettled,
                      priorWorker.state != .succeeded,
                      task.status == .failed || task.status == .blocked else {
                    throw OrchestrationError(
                        "task_not_startable",
                        "Task \(taskID) cannot retry from Dispatch \(retryOf).")
                }
            } else if task.status != .ready {
                throw OrchestrationError(
                    "task_not_startable",
                    "Task \(taskID) is \(task.status.rawValue); only a ready Task can start.")
            }
            let id = generateID("ctx")
            try db.run(
                """
                INSERT INTO dispatch_contexts (id, run_id, task_id, status, dispatched_at)
                VALUES (?, ?, ?, 'pending', datetime('now'))
                """,
                [.text(id), .text(task.runID), .text(taskID)])
            try db.run(
                """
                INSERT INTO worker_dispatches (dispatch_id, state, stage, start_options)
                VALUES (?, 'starting', 'accepted', ?)
                """,
                [.text(id), .text(startOptions)])
            try db.run(
                "UPDATE tasks SET status = 'dispatched', result = NULL, completed_at = NULL WHERE id = ?",
                [.text(taskID)])
            return (try requireDispatchContext(id), try requireWorkerDispatchRow(id))
        }
    }

    /// Bind the started agent terminal as the dispatch's proven assignee and mint the
    /// capability secret: assignee handle/pane/incarnation on the dispatch row, an
    /// `owned` (or `external`, for a reused pre-existing terminal) terminal resource,
    /// and the worker row's worktree/terminal facts.
    public func bindStartingWorkerAuthority(
        dispatchID: String,
        handle: String,
        paneKey: String?,
        processIncarnation: String?,
        worktreeID: String?,
        externalTerminal: Bool
    ) throws -> String {
        try db.inTransaction {
            let worker = try requireWorkerDispatchRow(dispatchID)
            guard worker.state == .starting else {
                throw OrchestrationError(
                    "dispatch_inactive", "Dispatch \(dispatchID) is not starting.")
            }
            try db.run(
                """
                UPDATE dispatch_contexts
                SET assignee_handle = ?, assignee_pane_key = ?, process_incarnation = ?
                WHERE id = ?
                """,
                [.text(handle), .maybeText(paneKey), .maybeText(processIncarnation), .text(dispatchID)])
            _ = try createWorkerTerminalResource(
                originDispatchID: dispatchID, ownerDispatchID: dispatchID,
                terminalHandle: handle, worktreeID: worktreeID, paneKey: paneKey,
                processIncarnation: processIncarnation,
                ownershipState: externalTerminal ? .external : .owned)
            if externalTerminal {
                // A reused terminal is never closeable by release; record why up front.
                _ = try db.run(
                    """
                    UPDATE worker_terminal_resources
                    SET release_state = 'retained', retained_reason = 'external_terminal'
                    WHERE owner_dispatch_id = ?
                    """,
                    [.text(dispatchID)])
            }
            _ = try updateWorkerDispatch(
                dispatchID, stage: "authority_bound",
                worktreeID: worktreeID, agentTerminalHandle: handle)
            return try mintDispatchCapability(dispatchID: dispatchID)
        }
    }

    /// The `ready` transition: preamble accepted, dispatch goes live (`dispatched`).
    @discardableResult
    public func markWorkerDispatchReady(_ dispatchID: String, effects: String? = nil) throws -> WorkerDispatch {
        try db.inTransaction {
            let dispatch = try requireDispatchContext(dispatchID)
            let worker = try requireWorkerDispatchRow(dispatchID)
            guard dispatch.status == .pending, worker.state == .starting else {
                throw OrchestrationError(
                    "dispatch_inactive", "Dispatch \(dispatchID) is not starting.")
            }
            try db.run(
                "UPDATE dispatch_contexts SET status = 'dispatched' WHERE id = ?",
                [.text(dispatchID)])
            try db.run(
                """
                UPDATE worker_dispatches
                SET state = 'ready', stage = 'input_accepted',
                    effects = COALESCE(?, effects), updated_at = datetime('now')
                WHERE dispatch_id = ?
                """,
                [.maybeText(effects), .text(dispatchID)])
            return try requireWorkerDispatchRow(dispatchID)
        }
    }

    /// A definitive worker-start failure: dispatch failed, capability revoked, task
    /// failed (unless another attempt is still active). Unlike `failDispatch` this does
    /// not feed the circuit breaker — the worker never ran, so there is no flaky-worker
    /// signal to accumulate (matching Orca's failWorkerStart).
    @discardableResult
    public func failWorkerStart(
        _ dispatchID: String, stage: String, reason: String, residualResources: String? = nil
    ) throws -> WorkerDispatch {
        try db.inTransaction {
            let dispatch = try requireDispatchContext(dispatchID)
            let worker = try requireWorkerDispatchRow(dispatchID)
            guard worker.state == .starting else {
                throw OrchestrationError(
                    "dispatch_inactive", "Dispatch \(dispatchID) is not starting.")
            }
            try db.run(
                """
                UPDATE dispatch_contexts
                SET status = 'failed', last_failure = ?, completed_at = datetime('now'),
                    capability_revoked_at = COALESCE(capability_revoked_at, datetime('now'))
                WHERE id = ?
                """,
                [.text(reason), .text(dispatchID)])
            try db.run(
                """
                UPDATE worker_dispatches
                SET state = 'failed', stage = ?, last_error = ?,
                    residual_resources = COALESCE(?, residual_resources),
                    updated_at = datetime('now')
                WHERE dispatch_id = ?
                """,
                [.text(stage), .text(reason), .maybeText(residualResources), .text(dispatchID)])
            try db.run(
                """
                UPDATE tasks SET status = 'failed', completed_at = datetime('now')
                WHERE id = ? AND NOT EXISTS (
                  SELECT 1 FROM dispatch_contexts
                  WHERE task_id = tasks.id AND status IN ('pending', 'dispatched')
                )
                """,
                [.text(dispatch.taskID)])
            _ = try closeQuestionsForDispatch(dispatchID)
            return try requireWorkerDispatchRow(dispatchID)
        }
    }

    /// worker-start could not prove what happened (§1.7 `start_unknown`): resources may
    /// exist, the capability is revoked, and the task parks `blocked` for a human
    /// decision (worker-show / worker-abandon are the recovery commands).
    @discardableResult
    public func markWorkerStartUnknown(
        _ dispatchID: String, stage: String, reason: String, residualResources: String? = nil
    ) throws -> WorkerDispatch {
        try db.inTransaction {
            let dispatch = try requireDispatchContext(dispatchID)
            let worker = try requireWorkerDispatchRow(dispatchID)
            guard worker.state == .starting else {
                throw OrchestrationError(
                    "dispatch_inactive", "Dispatch \(dispatchID) is not starting.")
            }
            try db.run(
                """
                UPDATE worker_dispatches
                SET state = 'start_unknown', stage = ?, last_error = ?,
                    residual_resources = COALESCE(?, residual_resources),
                    updated_at = datetime('now')
                WHERE dispatch_id = ?
                """,
                [.text(stage), .text(reason), .maybeText(residualResources), .text(dispatchID)])
            try db.run(
                """
                UPDATE dispatch_contexts
                SET capability_revoked_at = COALESCE(capability_revoked_at, datetime('now'))
                WHERE id = ?
                """,
                [.text(dispatchID)])
            try db.run("UPDATE tasks SET status = 'blocked' WHERE id = ?", [.text(dispatch.taskID)])
            _ = try closeQuestionsForDispatch(dispatchID)
            return try requireWorkerDispatchRow(dispatchID)
        }
    }

    // MARK: - worker-stop / worker-abandon

    public func beginWorkerStop(_ dispatchID: String) throws -> WorkerStopBegin {
        try db.inTransaction {
            guard let dispatch = try dispatchContext(dispatchID) else {
                throw OrchestrationError("dispatch_not_found", "Dispatch \(dispatchID) was not found.")
            }
            guard let worker = try workerDispatch(dispatchID) else {
                let released = try releaseContextOnlyDispatch(dispatch, requestedState: "stopped")
                if !released.alreadySettled {
                    _ = try closeQuestionsForDispatch(dispatchID)
                }
                return .contextOnly(state: released.state,
                                    alreadySettled: released.alreadySettled,
                                    releasedCurrentTask: released.releasedCurrentTask)
            }
            if worker.state.isSettled {
                return .alreadySettled(worker)
            }
            guard worker.state == .ready || worker.state == .startUnknown else {
                throw OrchestrationError(
                    "dispatch_inactive", "Dispatch \(dispatchID) cannot stop from \(worker.state.rawValue).")
            }
            try db.run(
                """
                UPDATE worker_dispatches
                SET state = 'stopping', stage = 'stop_requested', updated_at = datetime('now')
                WHERE dispatch_id = ? AND state IN ('ready', 'start_unknown')
                """,
                [.text(dispatchID)])
            try db.run(
                """
                UPDATE dispatch_contexts
                SET capability_revoked_at = COALESCE(capability_revoked_at, datetime('now'))
                WHERE id = ?
                """,
                [.text(dispatchID)])
            try reconcileTaskAfterDispatchInterruption(taskID: dispatch.taskID, excluding: dispatchID)
            _ = try closeQuestionsForDispatch(dispatchID)
            return .stopping(try requireWorkerDispatchRow(dispatchID))
        }
    }

    @discardableResult
    public func settleWorkerStop(_ dispatchID: String) throws -> WorkerDispatch {
        try db.inTransaction {
            guard let worker = try workerDispatch(dispatchID),
                  let dispatch = try dispatchContext(dispatchID),
                  worker.state == .stopping else {
                throw OrchestrationError("dispatch_inactive", "Dispatch \(dispatchID) is not stopping.")
            }
            try db.run(
                """
                UPDATE worker_dispatches
                SET state = 'stopped', stage = 'process_stopped', updated_at = datetime('now')
                WHERE dispatch_id = ? AND state = 'stopping'
                """,
                [.text(dispatchID)])
            try db.run(
                """
                UPDATE dispatch_contexts
                SET status = 'failed', completed_at = datetime('now'), last_failure = 'stopped'
                WHERE id = ? AND status IN ('pending', 'dispatched')
                """,
                [.text(dispatchID)])
            try reconcileTaskAfterDispatchInterruption(taskID: dispatch.taskID, excluding: dispatchID)
            return try requireWorkerDispatchRow(dispatchID)
        }
    }

    /// The stop's process action could not be proven — never fake `stopped`
    /// (docs/research/orca-inventory.md §1.8's "degrade to read-only, never guess").
    @discardableResult
    public func markWorkerStopUnknown(_ dispatchID: String, reason: String) throws -> WorkerDispatch {
        guard let worker = try workerDispatch(dispatchID), worker.state == .stopping else {
            throw OrchestrationError("dispatch_inactive", "Dispatch \(dispatchID) is not stopping.")
        }
        try db.run(
            """
            UPDATE worker_dispatches
            SET state = 'stop_unknown', stage = 'stop_outcome_unknown', last_error = ?,
                updated_at = datetime('now')
            WHERE dispatch_id = ? AND state = 'stopping'
            """,
            [.text(reason), .text(dispatchID)])
        return try requireWorkerDispatchRow(dispatchID)
    }

    /// Abandon: give up lifecycle authority without touching any process. Possibly-live
    /// resources stay listed in the worker row's residual accounting.
    public func abandonWorkerDispatch(_ dispatchID: String) throws -> WorkerAbandonResult {
        try db.inTransaction {
            guard let dispatch = try dispatchContext(dispatchID) else {
                throw OrchestrationError("dispatch_not_found", "Dispatch \(dispatchID) was not found.")
            }
            guard let worker = try workerDispatch(dispatchID) else {
                let released = try releaseContextOnlyDispatch(dispatch, requestedState: "abandoned")
                if !released.alreadySettled {
                    _ = try closeQuestionsForDispatch(dispatchID)
                }
                return .contextOnly(state: released.state,
                                    alreadySettled: released.alreadySettled,
                                    releasedCurrentTask: released.releasedCurrentTask)
            }
            if worker.state == .abandoned {
                return .alreadyAbandoned(worker)
            }
            if try latestDispatchContext(taskID: dispatch.taskID)?.id != dispatchID {
                return .stale(worker)
            }
            if worker.state == .stopping {
                throw OrchestrationError(
                    "dispatch_inactive",
                    "Dispatch \(dispatchID) is stopping; wait for worker-stop to settle before abandoning.")
            }
            if worker.state == .succeeded {
                throw OrchestrationError(
                    "dispatch_inactive",
                    "Dispatch \(dispatchID) already succeeded and cannot be abandoned.")
            }
            try db.run(
                """
                UPDATE worker_dispatches
                SET state = 'abandoned', stage = 'abandoned', updated_at = datetime('now')
                WHERE dispatch_id = ?
                """,
                [.text(dispatchID)])
            try db.run(
                """
                UPDATE dispatch_contexts
                SET status = CASE WHEN status IN ('pending', 'dispatched') THEN 'failed' ELSE status END,
                    capability_revoked_at = COALESCE(capability_revoked_at, datetime('now')),
                    completed_at = COALESCE(completed_at, datetime('now'))
                WHERE id = ?
                """,
                [.text(dispatchID)])
            try reconcileTaskAfterDispatchInterruption(taskID: dispatch.taskID, excluding: dispatchID)
            _ = try closeQuestionsForDispatch(dispatchID)
            return .abandoned(try requireWorkerDispatchRow(dispatchID))
        }
    }

    /// A stop/abandon interrupted the attempt without a worker report: the task parks
    /// `blocked` (needs a coordinator decision — retry via `--retry-of` or fail it),
    /// unless another dispatch is still active.
    func reconcileTaskAfterDispatchInterruption(taskID: String, excluding dispatchID: String) throws {
        try db.run(
            """
            UPDATE tasks
            SET status = CASE WHEN EXISTS (
              SELECT 1 FROM dispatch_contexts
              WHERE task_id = tasks.id AND id != ? AND status IN ('pending', 'dispatched')
            ) THEN 'dispatched' ELSE 'blocked' END
            WHERE id = ? AND status IN ('dispatched', 'blocked')
            """,
            [.text(dispatchID), .text(taskID)])
    }

    /// Settle a dispatch that has no worker row (`dispatch --inject`): the assignment
    /// fails with the requested terminal state; no process is touched.
    private func releaseContextOnlyDispatch(
        _ dispatch: DispatchContext, requestedState: String
    ) throws -> (state: String, alreadySettled: Bool, releasedCurrentTask: Bool) {
        guard dispatch.status == .pending || dispatch.status == .dispatched else {
            let persisted = (dispatch.lastFailure == "abandoned" || dispatch.lastFailure == "stopped")
                ? dispatch.lastFailure! : dispatch.status.rawValue
            return (persisted, true, false)
        }
        try db.run(
            """
            UPDATE dispatch_contexts
            SET status = 'failed', last_failure = ?,
                capability_revoked_at = COALESCE(capability_revoked_at, datetime('now')),
                completed_at = COALESCE(completed_at, datetime('now'))
            WHERE id = ? AND status IN ('pending', 'dispatched')
            """,
            [.text(requestedState), .text(dispatch.id)])
        let remaining = try db.queryOne(
            """
            SELECT 1 AS present FROM dispatch_contexts
            WHERE task_id = ? AND status IN ('pending', 'dispatched') LIMIT 1
            """,
            [.text(dispatch.taskID)])
        var releasedCurrentTask = false
        if remaining == nil {
            let changes = try db.run(
                "UPDATE tasks SET status = 'blocked' WHERE id = ? AND status = 'dispatched'",
                [.text(dispatch.taskID)])
            releasedCurrentTask = changes > 0
        }
        return (requestedState, false, releasedCurrentTask)
    }

    // MARK: - worker-release / worker-retain

    /// Record durable release intent, or say why the terminal must be retained instead.
    /// Refusals (docs/research/orca-inventory.md §1.8): unsettled workers error;
    /// stopped/abandoned workers are `identity_unproven`; external (reused/pre-existing),
    /// user-taken-over, and transferred terminals are retained with their reason.
    public func requestWorkerTerminalRelease(_ dispatchID: String) throws -> WorkerReleaseRequest {
        try db.inTransaction {
            guard let dispatch = try dispatchContext(dispatchID) else {
                throw OrchestrationError("dispatch_not_found", "Dispatch \(dispatchID) was not found.")
            }
            guard let worker = try workerDispatch(dispatchID) else {
                guard dispatch.status == .completed || dispatch.status == .failed
                        || dispatch.status == .circuitBroken else {
                    throw OrchestrationError(
                        "dispatch_inactive",
                        "Dispatch \(dispatchID) is \(dispatch.status.rawValue); only a settled dispatch can release.")
                }
                return .retained(nil, reason: "no_owned_resource")
            }
            guard worker.state.isSettled else {
                // Release is post-completion cleanup only; an unsettled worker must be
                // stopped first, never silently closed.
                throw OrchestrationError(
                    "dispatch_inactive",
                    "Dispatch \(dispatchID) is \(worker.state.rawValue); only a settled worker can release. Use worker-stop to cancel an active worker.")
            }
            guard let resource = try workerTerminalResource(ownerDispatchID: dispatchID) else {
                return .retained(nil, reason: "no_owned_resource")
            }
            if resource.releaseState == .released || resource.ownershipState == .released {
                return .alreadyReleased(resource)
            }
            if worker.state == .stopped || worker.state == .abandoned {
                return .retained(resource, reason: "identity_unproven")
            }
            switch resource.ownershipState {
            case .external:
                return .retained(resource, reason: resource.retainedReason ?? "external_terminal")
            case .userOwned:
                return .retained(resource, reason: "user_takeover")
            case .transferred:
                return .retained(resource, reason: "ownership_transferred")
            case .owned, .released:
                break
            }
            if resource.releaseState == .retained, resource.retainedReason == "user_requested" {
                // The user explicitly retained earlier; a fresh release supersedes that
                // hold, and the (possibly stale) pinned archive goes with it.
                try db.run("DELETE FROM worker_terminal_archives WHERE dispatch_id = ?",
                           [.text(dispatchID)])
            }
            try db.run(
                """
                UPDATE worker_terminal_resources
                SET release_state = CASE WHEN release_state = 'releasing' THEN 'releasing' ELSE 'requested' END,
                    retained_reason = NULL,
                    release_requested_at = COALESCE(release_requested_at, datetime('now')),
                    release_error = NULL, updated_at = datetime('now')
                WHERE id = ?
                """,
                [.text(resource.id)])
            return .requested(try requireResource(resource.id))
        }
    }

    /// Archive-then-close, step 1: pin the output and commit `releasing` in one
    /// transaction, so the close that follows can never orphan an unarchived terminal.
    @discardableResult
    public func commitWorkerTerminalArchiveForRelease(
        dispatchID: String, resourceID: String,
        kind: WorkerTerminalArchiveKind, content: String
    ) throws -> WorkerTerminalResource {
        try db.inTransaction {
            _ = try archiveWorkerTerminalOutput(
                dispatchID: dispatchID, resourceID: resourceID, kind: kind, content: content)
            try db.run(
                """
                UPDATE worker_terminal_resources
                SET release_state = 'releasing', updated_at = datetime('now')
                WHERE id = ? AND ownership_state = 'owned'
                  AND release_state IN ('requested', 'releasing')
                """,
                [.text(resourceID)])
            return try requireResource(resourceID)
        }
    }

    @discardableResult
    public func settleWorkerTerminalRelease(resourceID: String) throws -> WorkerTerminalResource {
        try db.run(
            """
            UPDATE worker_terminal_resources
            SET release_state = 'released', ownership_state = 'released', retained_reason = NULL,
                release_completed_at = COALESCE(release_completed_at, datetime('now')),
                release_error = NULL, updated_at = datetime('now')
            WHERE id = ? AND release_state IN ('requested', 'releasing')
            """,
            [.text(resourceID)])
        return try requireResource(resourceID)
    }

    @discardableResult
    public func markWorkerTerminalReleaseUnknown(
        resourceID: String, reason: String
    ) throws -> WorkerTerminalResource {
        try db.run(
            """
            UPDATE worker_terminal_resources
            SET release_state = 'unknown', release_error = ?, updated_at = datetime('now')
            WHERE id = ? AND release_state IN ('requested', 'releasing', 'unknown')
            """,
            [.text(reason), .text(resourceID)])
        return try requireResource(resourceID)
    }

    @discardableResult
    public func revertWorkerTerminalReleaseToRetained(
        resourceID: String, reason: String
    ) throws -> WorkerTerminalResource {
        try db.run(
            """
            UPDATE worker_terminal_resources
            SET release_state = 'retained', retained_reason = ?, updated_at = datetime('now')
            WHERE id = ? AND release_state IN ('requested', 'releasing')
            """,
            [.text(reason), .text(resourceID)])
        return try requireResource(resourceID)
    }

    public func retainWorkerTerminalResource(_ dispatchID: String) throws -> WorkerRetainResult {
        try db.inTransaction {
            guard try dispatchContext(dispatchID) != nil else {
                throw OrchestrationError("dispatch_not_found", "Dispatch \(dispatchID) was not found.")
            }
            guard let resource = try workerTerminalResource(ownerDispatchID: dispatchID) else {
                return .noOwnedResource
            }
            if resource.releaseState == .released || resource.ownershipState == .released {
                return .alreadyReleased(resource)
            }
            if resource.releaseState == .releasing || resource.releaseState == .unknown {
                return .releaseCommitted(resource)
            }
            try db.run(
                """
                UPDATE worker_terminal_resources
                SET release_state = 'retained', retained_reason = 'user_requested',
                    updated_at = datetime('now')
                WHERE id = ? AND release_state IN ('not_requested', 'requested', 'retained')
                """,
                [.text(resource.id)])
            return .retained(try requireResource(resource.id))
        }
    }

    // MARK: - worker-list

    /// Every dispatch joined with its worker state and owned terminal resource
    /// (process accounting — deliberately independent of Task/Dispatch outcome).
    public func listWorkerRows(runID: String? = nil) throws -> [WorkerListRow] {
        let filter = runID != nil ? "WHERE d.run_id = ?" : ""
        let params: [SQLiteValue] = runID.map { [.text($0)] } ?? []
        let rows = try db.query(
            """
            SELECT d.id AS dispatch_id,
                   COALESCE(w.state, 'unsupervised') AS worker_state,
                   COALESCE(w.agent_terminal_handle, d.assignee_handle) AS agent_terminal_handle,
                   d.task_id, d.run_id, d.status AS dispatch_status
              FROM dispatch_contexts d
              LEFT JOIN worker_dispatches w ON w.dispatch_id = d.id
             \(filter)
             ORDER BY COALESCE(w.created_at, d.created_at), d.id
            """,
            params)
        return try rows.map { row in
            let dispatchID = try row.text("dispatch_id")
            let statusRaw = try row.text("dispatch_status")
            guard let status = DispatchStatus(rawValue: statusRaw) else {
                throw OrchestrationError("internal_error", "Unexpected dispatch status '\(statusRaw)'")
            }
            return WorkerListRow(
                dispatchID: dispatchID,
                taskID: try row.text("task_id"),
                runID: try row.text("run_id"),
                workerState: try row.text("worker_state"),
                dispatchStatus: status,
                agentTerminalHandle: try row.textOrNil("agent_terminal_handle"),
                resource: try workerTerminalResource(ownerDispatchID: dispatchID))
        }
    }

    // MARK: - Shared

    private func requireWorkerDispatchRow(_ dispatchID: String) throws -> WorkerDispatch {
        guard let worker = try workerDispatch(dispatchID) else {
            throw OrchestrationError("dispatch_not_found", "Worker dispatch \(dispatchID) was not found.")
        }
        return worker
    }

    private func requireResource(_ id: String) throws -> WorkerTerminalResource {
        guard let resource = try workerTerminalResource(id: id) else {
            throw OrchestrationError("terminal_not_found", "Worker terminal resource \(id) was not found.")
        }
        return resource
    }
}

/// Process accounting per worker-list row (Orca's `deriveWorkerTerminalListState`).
public enum WorkerTerminalListState: String, CaseIterable, Sendable {
    case active
    case reclaimable
    case retained
    case releasePending = "release_pending"
    case releaseUnknown = "release_unknown"
    case released

    public static func derive(workerState: String, agentTerminalHandle: String?,
                              resource: WorkerTerminalResource?) -> WorkerTerminalListState? {
        derive(
            workerState: workerState,
            agentTerminalHandle: agentTerminalHandle,
            releaseState: resource?.releaseState.rawValue,
            ownershipState: resource?.ownershipState.rawValue)
    }

    /// Primitive form of `derive` for observation (the in-app orchestration view
    /// and its tests) so callers never have to construct a resource row.
    public static func derive(
        workerState: String,
        agentTerminalHandle: String?,
        releaseState: String?,
        ownershipState: String?
    ) -> WorkerTerminalListState? {
        guard releaseState != nil || ownershipState != nil else {
            return agentTerminalHandle != nil ? .retained : nil
        }
        switch releaseState {
        case WorkerTerminalReleaseState.released.rawValue: return .released
        case WorkerTerminalReleaseState.unknown.rawValue: return .releaseUnknown
        case WorkerTerminalReleaseState.requested.rawValue,
             WorkerTerminalReleaseState.releasing.rawValue: return .releasePending
        case WorkerTerminalReleaseState.retained.rawValue: return .retained
        case WorkerTerminalReleaseState.notRequested.rawValue, .none: break
        default: break
        }
        if let ownershipState, ownershipState != WorkerTerminalOwnershipState.owned.rawValue {
            return .retained
        }
        if workerState == WorkerDispatchState.succeeded.rawValue
            || workerState == WorkerDispatchState.failed.rawValue {
            return .reclaimable
        }
        if let state = WorkerDispatchState(rawValue: workerState), state.isSettled {
            return .retained
        }
        return .active
    }
}
