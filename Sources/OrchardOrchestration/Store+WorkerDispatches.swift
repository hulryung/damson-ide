import Foundation

// Supervised-worker resource accounting: worker_dispatches (state machine per Dispatch),
// worker_terminal_resources (owned terminal + ownership/release states), and
// worker_terminal_archives (output pinned before a terminal closes, so worker-read
// still works afterwards). Ported from ~/dev/orca/.../db/worker-dispatch/ and
// db/worker-terminal/ (store layer only — the process-facing release pipeline is T3+).
extension OrchestrationStore {
    @discardableResult
    public func createWorkerDispatch(
        dispatchID: String,
        startOptions: String = "{}"
    ) throws -> WorkerDispatch {
        _ = try requireDispatchContext(dispatchID)
        try db.run(
            "INSERT INTO worker_dispatches (dispatch_id, start_options) VALUES (?, ?)",
            [.text(dispatchID), .text(startOptions)]
        )
        return try requireWorkerDispatch(dispatchID)
    }

    public func workerDispatch(_ dispatchID: String) throws -> WorkerDispatch? {
        guard let row = try db.queryOne(
            "SELECT * FROM worker_dispatches WHERE dispatch_id = ?", [.text(dispatchID)]) else {
            return nil
        }
        return try WorkerDispatch(row: row)
    }

    public func listWorkerDispatches(states: [WorkerDispatchState]? = nil) throws -> [WorkerDispatch] {
        if let states, !states.isEmpty {
            let placeholders = states.map { _ in "?" }.joined(separator: ",")
            return try db.query(
                "SELECT * FROM worker_dispatches WHERE state IN (\(placeholders)) ORDER BY created_at, dispatch_id",
                states.map { .text($0.rawValue) }
            ).map(WorkerDispatch.init)
        }
        return try db.query("SELECT * FROM worker_dispatches ORDER BY created_at, dispatch_id")
            .map(WorkerDispatch.init)
    }

    /// Partial update of a worker dispatch's pipeline progress; nil fields keep their
    /// stored value.
    @discardableResult
    public func updateWorkerDispatch(
        _ dispatchID: String,
        state: WorkerDispatchState? = nil,
        stage: String? = nil,
        worktreeID: String? = nil,
        agentTerminalHandle: String? = nil,
        setupState: String? = nil,
        effects: String? = nil,
        residualResources: String? = nil,
        lastError: String? = nil
    ) throws -> WorkerDispatch {
        try db.run(
            """
            UPDATE worker_dispatches
            SET state = COALESCE(?, state),
                stage = COALESCE(?, stage),
                worktree_id = COALESCE(?, worktree_id),
                agent_terminal_handle = COALESCE(?, agent_terminal_handle),
                setup_state = COALESCE(?, setup_state),
                effects = COALESCE(?, effects),
                residual_resources = COALESCE(?, residual_resources),
                last_error = COALESCE(?, last_error),
                updated_at = datetime('now')
            WHERE dispatch_id = ?
            """,
            [
                .maybeText(state?.rawValue), .maybeText(stage), .maybeText(worktreeID),
                .maybeText(agentTerminalHandle), .maybeText(setupState), .maybeText(effects),
                .maybeText(residualResources), .maybeText(lastError), .text(dispatchID),
            ]
        )
        return try requireWorkerDispatch(dispatchID)
    }

    private func requireWorkerDispatch(_ dispatchID: String) throws -> WorkerDispatch {
        guard let worker = try workerDispatch(dispatchID) else {
            throw OrchestrationError(
                "dispatch_not_found", "Worker dispatch \(dispatchID) was not found.")
        }
        return worker
    }

    // MARK: - Worker terminal resources

    @discardableResult
    public func createWorkerTerminalResource(
        originDispatchID: String,
        ownerDispatchID: String,
        terminalHandle: String,
        worktreeID: String? = nil,
        paneKey: String? = nil,
        processIncarnation: String? = nil,
        ownershipState: WorkerTerminalOwnershipState = .owned
    ) throws -> WorkerTerminalResource {
        let id = generateID("wtr")
        try db.run(
            """
            INSERT INTO worker_terminal_resources (
              id, origin_dispatch_id, owner_dispatch_id, worktree_id,
              terminal_handle, pane_key, process_incarnation, ownership_state
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id), .text(originDispatchID), .text(ownerDispatchID),
                .maybeText(worktreeID), .text(terminalHandle), .maybeText(paneKey),
                .maybeText(processIncarnation), .text(ownershipState.rawValue),
            ]
        )
        return try requireWorkerTerminalResource(id)
    }

    public func workerTerminalResource(id: String) throws -> WorkerTerminalResource? {
        guard let row = try db.queryOne(
            "SELECT * FROM worker_terminal_resources WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try WorkerTerminalResource(row: row)
    }

    public func workerTerminalResource(ownerDispatchID: String) throws -> WorkerTerminalResource? {
        guard let row = try db.queryOne(
            "SELECT * FROM worker_terminal_resources WHERE owner_dispatch_id = ?",
            [.text(ownerDispatchID)]) else {
            return nil
        }
        return try WorkerTerminalResource(row: row)
    }

    @discardableResult
    public func updateWorkerTerminalResource(
        _ id: String,
        ownershipState: WorkerTerminalOwnershipState? = nil,
        releaseState: WorkerTerminalReleaseState? = nil,
        retainedReason: String? = nil,
        releaseError: String? = nil
    ) throws -> WorkerTerminalResource {
        try db.run(
            """
            UPDATE worker_terminal_resources
            SET ownership_state = COALESCE(?, ownership_state),
                release_state = COALESCE(?, release_state),
                retained_reason = COALESCE(?, retained_reason),
                release_error = COALESCE(?, release_error),
                release_requested_at = CASE WHEN ? = 'requested'
                  THEN COALESCE(release_requested_at, datetime('now')) ELSE release_requested_at END,
                release_completed_at = CASE WHEN ? = 'released'
                  THEN COALESCE(release_completed_at, datetime('now')) ELSE release_completed_at END,
                updated_at = datetime('now')
            WHERE id = ?
            """,
            [
                .maybeText(ownershipState?.rawValue), .maybeText(releaseState?.rawValue),
                .maybeText(retainedReason), .maybeText(releaseError),
                .maybeText(releaseState?.rawValue), .maybeText(releaseState?.rawValue),
                .text(id),
            ]
        )
        return try requireWorkerTerminalResource(id)
    }

    private func requireWorkerTerminalResource(_ id: String) throws -> WorkerTerminalResource {
        guard let resource = try workerTerminalResource(id: id) else {
            throw OrchestrationError(
                "terminal_not_found", "Worker terminal resource \(id) was not found.")
        }
        return resource
    }

    // MARK: - Worker terminal archives

    /// Pin a dispatch's output before its terminal closes (worker-release archives
    /// first — docs/research/orca-inventory.md §1.8). Idempotent: re-archiving the same
    /// dispatch keeps the first pin, since the terminal content only degrades after it.
    @discardableResult
    public func archiveWorkerTerminalOutput(
        dispatchID: String,
        resourceID: String,
        kind: WorkerTerminalArchiveKind,
        content: String
    ) throws -> WorkerTerminalArchive {
        try db.run(
            """
            INSERT OR IGNORE INTO worker_terminal_archives (dispatch_id, resource_id, kind, content)
            VALUES (?, ?, ?, ?)
            """,
            [.text(dispatchID), .text(resourceID), .text(kind.rawValue), .text(content)]
        )
        guard let archive = try workerTerminalArchive(dispatchID: dispatchID) else {
            throw OrchestrationError(
                "terminal_not_found", "Archive for dispatch \(dispatchID) was not found.")
        }
        return archive
    }

    public func workerTerminalArchive(dispatchID: String) throws -> WorkerTerminalArchive? {
        guard let row = try db.queryOne(
            "SELECT * FROM worker_terminal_archives WHERE dispatch_id = ?", [.text(dispatchID)]) else {
            return nil
        }
        return try WorkerTerminalArchive(row: row)
    }
}
