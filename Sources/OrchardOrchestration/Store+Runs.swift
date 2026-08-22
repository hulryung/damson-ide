import Foundation

// Runs: durable namespace + coordinator inbox. Never schedules or places workers
// (docs/research/orca-inventory.md §1.1). Ported from
// ~/dev/orca/src/main/runtime/orchestration/db/runs/{run-create,run-lookup,run-binding}.ts
// minus the legacy-adoption paths (out of scope for v2 foundation).
extension OrchestrationStore {
    @discardableResult
    public func createRun(
        objective: String,
        coordinatorHandle: String,
        coordinatorPaneKey: String
    ) throws -> OrchestrationRun {
        let id = generateID("run")
        return try db.inTransaction {
            try unbindOtherRunsForPane(coordinatorPaneKey, excluding: id)
            // consumer_generation starts at 1: generation 0 means "never bound", so a
            // caller holding generation 0 can never pass the fence by accident.
            try db.run(
                """
                INSERT INTO runs (
                  id, objective, coordinator_handle, coordinator_pane_key, consumer_generation
                ) VALUES (?, ?, ?, ?, 1)
                """,
                [.text(id), .text(objective), .text(coordinatorHandle), .text(coordinatorPaneKey)]
            )
            return try requireRunRow(id)
        }
    }

    public func run(_ id: String) throws -> OrchestrationRun? {
        guard let row = try db.queryOne("SELECT * FROM runs WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try OrchestrationRun(row: row)
    }

    public func listRuns() throws -> [OrchestrationRun] {
        try db.query("SELECT * FROM runs ORDER BY created_at DESC").map(OrchestrationRun.init)
    }

    /// The run a coordinator pane is currently bound to, if any — `run-current`'s backing.
    public func runForCoordinatorPane(_ paneKey: String) throws -> OrchestrationRun? {
        guard let row = try db.queryOne(
            "SELECT * FROM runs WHERE coordinator_pane_key = ? ORDER BY updated_at DESC LIMIT 1",
            [.text(paneKey)]
        ) else { return nil }
        return try OrchestrationRun(row: row)
    }

    /// Rebind a Run to a (possibly new) coordinator. A changed binding bumps
    /// `consumer_generation` and fences the outstanding delivery, so the replaced
    /// consumer's next `check`/`ack` fails with `consumer_fenced` instead of silently
    /// consuming the new coordinator's mail. Rebinding to the identical pane+handle is a
    /// no-op — an idempotent `run-use` must not fence its own outstanding batch.
    @discardableResult
    public func bindRun(
        runID: String,
        coordinatorHandle: String,
        coordinatorPaneKey: String
    ) throws -> OrchestrationRun {
        try db.inTransaction {
            let run = try requireRunRow(runID)
            let sameBinding = run.coordinatorPaneKey == coordinatorPaneKey
                && run.coordinatorHandle == coordinatorHandle
            try unbindOtherRunsForPane(coordinatorPaneKey, excluding: runID)
            if !sameBinding {
                try db.run(
                    """
                    UPDATE runs
                    SET coordinator_handle = ?, coordinator_pane_key = ?,
                        consumer_generation = consumer_generation + 1,
                        updated_at = datetime('now')
                    WHERE id = ?
                    """,
                    [.text(coordinatorHandle), .text(coordinatorPaneKey), .text(runID)]
                )
                try fenceOutstandingDelivery(runID)
            }
            return try requireRunRow(runID)
        }
    }

    /// Throws `consumer_fenced` unless `consumerGeneration` is the Run's current one.
    @discardableResult
    func requireCurrentConsumer(_ runID: String, _ consumerGeneration: Int) throws -> OrchestrationRun {
        guard let run = try run(runID), run.consumerGeneration == consumerGeneration else {
            throw OrchestrationError(
                "consumer_fenced",
                "This mailbox consumer has been replaced. Rebind with run-use."
            )
        }
        return run
    }

    func requireRun(_ runID: String) throws {
        guard try run(runID) != nil else {
            throw OrchestrationError("run_not_found", "Run \(runID) was not found.")
        }
    }

    private func requireRunRow(_ id: String) throws -> OrchestrationRun {
        guard let run = try run(id) else {
            throw OrchestrationError("run_not_found", "Run \(id) was not found.")
        }
        return run
    }

    /// A pane coordinates at most one Run: binding it here detaches it elsewhere.
    private func unbindOtherRunsForPane(_ paneKey: String, excluding runID: String) throws {
        try db.run(
            """
            UPDATE runs SET coordinator_pane_key = NULL, updated_at = datetime('now')
            WHERE coordinator_pane_key = ? AND id != ?
            """,
            [.text(paneKey), .text(runID)]
        )
    }
}
