import Foundation

// Tasks: work items with DAG deps. Readiness is computed, never scheduled — the
// coordinator polls `task-list --ready` and dispatches by hand (no scheduler, per
// docs/REBUILD-PLAN.md "Product decisions"). Ported from
// ~/dev/orca/src/main/runtime/orchestration/db/tasks/{task-store,task-status-transition}.ts.
extension OrchestrationStore {
    @discardableResult
    public func createTask(
        runID: String,
        spec: String,
        taskTitle: String? = nil,
        displayName: String? = nil,
        deps: [String] = [],
        parentID: String? = nil,
        createdByTerminalHandle: String? = nil,
        createdByPaneKey: String? = nil,
        createdByProcessIncarnation: String? = nil,
        createdByRunGeneration: Int? = nil
    ) throws -> OrchestrationTask {
        try db.inTransaction {
            try requireRun(runID)
            if let parentID {
                guard let parent = try task(parentID), parent.runID == runID else {
                    throw OrchestrationError(
                        "invalid_argument", "Parent task \(parentID) must belong to run \(runID)")
                }
            }
            for depID in deps {
                guard let dependency = try task(depID), dependency.runID == runID else {
                    throw OrchestrationError(
                        "invalid_argument", "Dependency task \(depID) must belong to run \(runID)")
                }
            }
            let id = generateID("task")
            let depsJSON = JSONCoding.encodeStringArray(deps)
            // Readiness is decided in the INSERT itself (json_each over deps): a task is
            // born 'ready' iff every dep exists in this run and is completed. Doing it in
            // SQL keeps create + readiness one atomic statement.
            try db.run(
                """
                INSERT INTO tasks (
                  id, run_id, parent_id, created_by_terminal_handle, created_by_pane_key,
                  created_by_process_incarnation, created_by_run_generation,
                  task_title, display_name, spec, status, deps
                ) VALUES (
                  ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                  CASE WHEN EXISTS (
                    SELECT 1
                    FROM json_each(?) requested
                    LEFT JOIN tasks dependency ON dependency.id = requested.value
                    WHERE dependency.id IS NULL
                       OR dependency.run_id <> ?
                       OR dependency.status <> 'completed'
                  ) THEN 'pending' ELSE 'ready' END,
                  ?
                )
                """,
                [
                    .text(id), .text(runID), .maybeText(parentID),
                    .maybeText(createdByTerminalHandle), .maybeText(createdByPaneKey),
                    .maybeText(createdByProcessIncarnation), .maybeInt(createdByRunGeneration),
                    .maybeText(taskTitle), .maybeText(displayName), .text(spec),
                    .text(depsJSON), .text(runID), .text(depsJSON),
                ]
            )
            return try requireTask(id)
        }
    }

    public func task(_ id: String) throws -> OrchestrationTask? {
        guard let row = try db.queryOne("SELECT * FROM tasks WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try OrchestrationTask(row: row)
    }

    func requireTask(_ id: String) throws -> OrchestrationTask {
        guard let task = try task(id) else {
            throw OrchestrationError("task_not_found", "Task \(id) was not found.")
        }
        return task
    }

    /// `task-list`; `ready: true` is the `--ready` DAG-readiness view.
    public func listTasks(
        runID: String? = nil, status: TaskStatus? = nil, ready: Bool = false
    ) throws -> [OrchestrationTask] {
        var conditions: [String] = []
        var params: [SQLiteValue] = []
        if let runID {
            conditions.append("run_id = ?")
            params.append(.text(runID))
        }
        if ready {
            conditions.append("status = 'ready'")
        } else if let status {
            conditions.append("status = ?")
            params.append(.text(status.rawValue))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return try db.query(
            "SELECT * FROM tasks \(whereClause) ORDER BY created_at, id", params
        ).map(OrchestrationTask.init)
    }

    /// Explicit status transition with the dispatch-consistency guards:
    /// - `dispatched` requires an active dispatch;
    /// - non-terminal states refuse while a dispatch is active;
    /// - terminal states refuse while a live *supervised* worker holds the dispatch
    ///   (stop or settle it first), and otherwise settle active dispatches with the task.
    @discardableResult
    public func updateTaskStatus(
        _ id: String, _ status: TaskStatus, result: String? = nil
    ) throws -> OrchestrationTask? {
        let terminal = status == .completed || status == .failed
        let requiresActiveDispatch = status == .dispatched
        let permitsActiveDispatch = terminal || requiresActiveDispatch
        return try db.inSavepoint("update_task_status") {
            let completedAt = terminal ? Self.sqliteTimestamp(Date()) : nil
            let changes = try db.run(
                """
                UPDATE tasks
                SET status = ?, result = COALESCE(?, result),
                    completed_at = COALESCE(?, completed_at)
                WHERE id = ?
                  AND (
                    ? = 0 OR EXISTS (
                      SELECT 1 FROM dispatch_contexts
                      WHERE task_id = tasks.id AND status IN ('pending', 'dispatched')
                    )
                  )
                  AND (
                    ? = 1 OR NOT EXISTS (
                      SELECT 1 FROM dispatch_contexts
                      WHERE task_id = tasks.id AND status IN ('pending', 'dispatched')
                    )
                  )
                  AND (
                    ? = 0 OR NOT EXISTS (
                      SELECT 1
                      FROM dispatch_contexts active
                      JOIN worker_dispatches worker ON worker.dispatch_id = active.id
                      WHERE active.task_id = tasks.id
                        AND active.status IN ('pending', 'dispatched')
                        AND worker.state NOT IN ('failed', 'succeeded', 'stopped', 'abandoned')
                    )
                  )
                """,
                [
                    .text(status.rawValue), .maybeText(result), .maybeText(completedAt), .text(id),
                    .int(requiresActiveDispatch ? 1 : 0),
                    .int(permitsActiveDispatch ? 1 : 0),
                    .int(terminal ? 1 : 0),
                ]
            )
            if changes != 1 {
                let task = try task(id)
                let active = try activeDispatchForTask(id)
                if task != nil, terminal, let activeWorker = try liveSupervisedDispatchID(taskID: id) {
                    throw OrchestrationError(
                        "task_not_startable",
                        "Task \(id) cannot move to \(status.rawValue) while supervised Dispatch \(activeWorker) is active; stop or settle its worker first."
                    )
                }
                if task != nil, requiresActiveDispatch, active == nil {
                    throw OrchestrationError(
                        "task_not_startable",
                        "Task \(id) cannot move to dispatched without an active Dispatch."
                    )
                }
                if task != nil, let active, !permitsActiveDispatch {
                    throw OrchestrationError(
                        "task_not_startable",
                        "Task \(id) cannot move to \(status.rawValue) while Dispatch \(active.id) is active."
                    )
                }
                return task
            }
            if terminal {
                try settleActiveDispatchesForTask(id, status: status == .completed ? .completed : .failed, failure: result)
            }
            if status == .completed {
                try promoteReadyTasks(completedTaskID: id)
            }
            return try task(id)
        }
    }

    /// Promote pending tasks whose last outstanding dependency just completed. Runs in
    /// the caller's transaction/savepoint, so a completed task never leaves its ready
    /// children unpromoted.
    func promoteReadyTasks(completedTaskID: String) throws {
        let candidates = try db.query("SELECT * FROM tasks WHERE status = 'pending'")
            .map(OrchestrationTask.init)
        for candidate in candidates where candidate.deps.contains(completedTaskID) {
            let allCompleted = try candidate.deps.allSatisfy { depID in
                try task(depID)?.status == .completed
            }
            if allCompleted {
                try db.run("UPDATE tasks SET status = 'ready' WHERE id = ?", [.text(candidate.id)])
            }
        }
    }

    /// The most recent dispatch of a task still holding a live supervised worker, if any.
    func liveSupervisedDispatchID(taskID: String, excluding dispatchID: String? = nil) throws -> String? {
        let exclusion = dispatchID != nil ? "AND active.id != ?" : ""
        var params: [SQLiteValue] = [.text(taskID)]
        if let dispatchID { params.append(.text(dispatchID)) }
        let row = try db.queryOne(
            """
            SELECT active.id AS id
            FROM dispatch_contexts active
            JOIN worker_dispatches worker ON worker.dispatch_id = active.id
            WHERE active.task_id = ? \(exclusion)
              AND active.status IN ('pending', 'dispatched')
              AND worker.state NOT IN ('failed', 'succeeded', 'stopped', 'abandoned')
            ORDER BY active.rowid DESC LIMIT 1
            """,
            params
        )
        return try row?.text("id")
    }
}
