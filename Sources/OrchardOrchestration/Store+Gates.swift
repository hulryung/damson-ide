import Foundation

// Decision gates: human approval checkpoints. They are NEVER auto-resolved — the
// coordinator loop calling `reblockTasksWithPendingGates` every tick is what makes them
// checkpoints instead of suggestions (docs/research/orca-inventory.md §1.8). Ported from
// ~/dev/orca/.../db/decision-gates/decision-gate-store.ts and coordinator-decision-gates.ts.
extension OrchestrationStore {
    /// Open a gate on a task: records the question, settles the task's active
    /// dispatches (the worker asked and is done for now), and blocks the task.
    /// When `requester` is passed, it must own the task's active dispatch — payload
    /// knowledge alone is not authority to block someone else's task.
    @discardableResult
    public func createGate(
        taskID: String,
        question: String,
        options: [String] = [],
        requester: (handle: String, paneKey: String?, dispatchID: String)? = nil
    ) throws -> DecisionGate {
        try db.inSavepoint("create_gate") {
            let active = try activeDispatchForTask(taskID)
            if let requester {
                let owns = active.map { dispatch in
                    dispatch.id == requester.dispatchID && senderOwnsDispatch(
                        dispatch, handle: requester.handle, paneKey: requester.paneKey)
                } ?? false
                guard owns else {
                    throw OrchestrationError(
                        "consumer_fenced",
                        "Terminal \(requester.handle) does not own the active Dispatch for Task \(taskID)."
                    )
                }
            }
            if let activeWorker = try liveSupervisedDispatchID(taskID: taskID) {
                throw OrchestrationError(
                    "task_not_startable",
                    "Task \(taskID) cannot open a gate while supervised Dispatch \(activeWorker) is active; stop or settle its worker first."
                )
            }
            let task = try requireTask(taskID)
            let id = generateID("gate")
            try db.run(
                "INSERT INTO decision_gates (id, run_id, task_id, question, options) VALUES (?, ?, ?, ?, ?)",
                [
                    .text(id), .text(task.runID), .text(taskID), .text(question),
                    .text(JSONCoding.encodeStringArray(options)),
                ]
            )
            try completeActiveDispatchesForTask(taskID)
            try db.run("UPDATE tasks SET status = 'blocked' WHERE id = ?", [.text(taskID)])
            return try requireGate(id)
        }
    }

    /// Resolve a gate (a human decision arriving via `gate-resolve`) and return its task
    /// to `ready`. The resolved Q&A is what `DispatchPreamble` appends to the next
    /// dispatch of the task.
    @discardableResult
    public func resolveGate(_ gateID: String, resolution: String) throws -> DecisionGate? {
        guard let gate = try gate(gateID) else { return nil }
        return try db.inSavepoint("resolve_gate") {
            try db.run(
                "UPDATE decision_gates SET status = 'resolved', resolution = ?, resolved_at = datetime('now') WHERE id = ?",
                [.text(resolution), .text(gateID)]
            )
            _ = try updateTaskStatus(gate.taskID, .ready)
            return try self.gate(gateID)
        }
    }

    /// Expire a gate. The status guard keeps a late timeout from overwriting a gate the
    /// user already resolved.
    @discardableResult
    public func timeoutGate(_ gateID: String) throws -> DecisionGate? {
        try db.run(
            "UPDATE decision_gates SET status = 'timeout', resolved_at = datetime('now') WHERE id = ? AND status = 'pending'",
            [.text(gateID)]
        )
        return try gate(gateID)
    }

    public func gate(_ id: String) throws -> DecisionGate? {
        guard let row = try db.queryOne("SELECT * FROM decision_gates WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try DecisionGate(row: row)
    }

    public func listGates(taskID: String? = nil, status: GateStatus? = nil) throws -> [DecisionGate] {
        var conditions: [String] = []
        var params: [SQLiteValue] = []
        if let taskID {
            conditions.append("task_id = ?")
            params.append(.text(taskID))
        }
        if let status {
            conditions.append("status = ?")
            params.append(.text(status.rawValue))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return try db.query(
            "SELECT * FROM decision_gates \(whereClause) ORDER BY created_at, id", params
        ).map(DecisionGate.init)
    }

    /// Force-re-block every task with a pending gate — the coordinator-tick invariant:
    /// a gate exists, so its task must be `blocked` no matter what moved it since.
    /// A task that can't be re-blocked right now (an active dispatch raced in) is
    /// skipped this tick rather than wedging the loop; the next tick retries.
    /// Returns the IDs of tasks it re-blocked.
    @discardableResult
    public func reblockTasksWithPendingGates() throws -> [String] {
        var reblocked: [String] = []
        for gate in try listGates(status: .pending) {
            guard let task = try task(gate.taskID), task.status != .blocked else { continue }
            do {
                _ = try updateTaskStatus(gate.taskID, .blocked)
                reblocked.append(gate.taskID)
            } catch let error as OrchestrationError where error.code == "task_not_startable" {
                continue
            }
        }
        return reblocked
    }

    private func requireGate(_ id: String) throws -> DecisionGate {
        guard let gate = try gate(id) else {
            throw OrchestrationError("gate_not_found", "Gate \(id) was not found.")
        }
        return gate
    }

    /// Exact-identity ownership check: pane key when the dispatch recorded one
    /// (remint-stable), else the exact assignee handle.
    func senderOwnsDispatch(_ dispatch: DispatchContext, handle: String, paneKey: String?) -> Bool {
        if let assigneePane = dispatch.assigneePaneKey {
            return paneKey == assigneePane
        }
        return dispatch.assigneeHandle == handle
    }
}
