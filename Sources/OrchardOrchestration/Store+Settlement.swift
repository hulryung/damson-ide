import Foundation

// `(taskId, dispatchId)`-keyed worker-report settlement with typed rejections. A retried
// task has multiple dispatch rows; keying on both means a late report from a dead attempt
// can never settle the live retry (docs/research/orca-inventory.md §1.1, §8 item 2).
// Ported from ~/dev/orca/.../db/dispatch-context/worker-report-settlement.ts.
extension OrchestrationStore {
    public func settleWorkerReport(
        taskID: String,
        dispatchID: String,
        outcome: WorkerReportOutcome,
        result: String
    ) throws -> WorkerReportSettlement {
        try db.inTransaction {
            try settleWorkerReportInTransaction(
                taskID: taskID, dispatchID: dispatchID, outcome: outcome, result: result)
        }
    }

    /// The settlement body, for callers already inside a transaction (the send path).
    func settleWorkerReportInTransaction(
        taskID: String,
        dispatchID: String,
        outcome: WorkerReportOutcome,
        result: String
    ) throws -> WorkerReportSettlement {
        guard let task = try task(taskID) else {
            return .rejected(code: .unknownTask, reason: "Unknown task \(taskID).")
        }
        guard let dispatch = try dispatchContext(dispatchID) else {
            return .rejected(code: .unknownDispatch, reason: "Unknown dispatch \(dispatchID).")
        }
        if dispatch.taskID != taskID {
            return .rejected(
                code: .taskDispatchMismatch,
                reason: "Dispatch \(dispatchID) belongs to task \(dispatch.taskID), not \(taskID)."
            )
        }

        let expectedDispatchStatus: DispatchStatus = outcome == .succeeded ? .completed : .failed
        let expectedTaskStatus: TaskStatus = outcome == .succeeded ? .completed : .failed
        if dispatch.status == expectedDispatchStatus && task.status == expectedTaskStatus {
            return .settled(outcome: outcome, duplicate: true)
        }
        if dispatch.status != .dispatched || task.status != .dispatched {
            return .rejected(
                code: .inactiveDispatch,
                reason: "inactive dispatch \(dispatchID): it or task \(taskID) is already settled."
            )
        }
        // Another dispatch of this task with a live supervised worker blocks settlement:
        // completing "around" a live sibling would orphan that worker's resources.
        if let conflicting = try liveSupervisedDispatchID(taskID: taskID, excluding: dispatchID) {
            return .rejected(
                code: .inactiveDispatch,
                reason: "Task \(taskID) still has active supervised Dispatch \(conflicting); stop or settle it before completing \(dispatchID)."
            )
        }
        // An unsupervised (`--inject`) dispatch may settle only if it is the task's
        // current attempt; a superseded one is stale.
        let reportingWorker = try workerDispatch(dispatchID)
        let latest = try activeDispatchForTask(taskID)
        if reportingWorker == nil, latest?.id != dispatchID {
            return .rejected(
                code: .staleDispatch,
                reason: "Dispatch \(dispatchID) is not the current dispatch for task \(taskID)."
            )
        }
        let siblingIDs = try db.query(
            """
            SELECT id FROM dispatch_contexts
            WHERE task_id = ? AND id != ? AND status IN ('pending', 'dispatched')
            """,
            [.text(taskID), .text(dispatchID)]
        ).map { try $0.text("id") }

        return try db.inSavepoint("settle_worker_report") {
            let dispatchChanges = try db.run(
                """
                UPDATE dispatch_contexts
                SET status = ?, completed_at = datetime('now'),
                    last_failure = CASE WHEN ? = 'failed' THEN ? ELSE last_failure END,
                    capability_revoked_at = COALESCE(capability_revoked_at, datetime('now'))
                WHERE id = ? AND status = 'dispatched'
                """,
                [
                    .text(expectedDispatchStatus.rawValue),
                    .text(expectedDispatchStatus.rawValue), .text(result), .text(dispatchID),
                ]
            )
            let taskChanges = try db.run(
                """
                UPDATE tasks
                SET status = ?, result = ?, completed_at = datetime('now')
                WHERE id = ? AND status = 'dispatched'
                """,
                [.text(expectedTaskStatus.rawValue), .text(result), .text(taskID)]
            )
            if dispatchChanges != 1 || taskChanges != 1 {
                // Surfacing a rejection out of a savepoint means throwing to roll back,
                // then translating — the caller sees a typed rejection, not an error.
                throw SettlementRace()
            }
            try db.run(
                """
                UPDATE worker_dispatches
                SET state = ?, stage = 'settled', updated_at = datetime('now')
                WHERE dispatch_id = ? AND state = 'ready'
                """,
                [
                    .text(outcome == .succeeded ? WorkerDispatchState.succeeded.rawValue : WorkerDispatchState.failed.rawValue),
                    .text(dispatchID),
                ]
            )
            try settleActiveDispatchesForTask(
                taskID, status: expectedDispatchStatus,
                failure: outcome == .failed ? result : nil)
            try closeQuestionsForDispatch(dispatchID)
            for sibling in siblingIDs {
                try closeQuestionsForDispatch(sibling)
            }
            if outcome == .succeeded {
                try promoteReadyTasks(completedTaskID: taskID)
            }
            return .settled(outcome: outcome, duplicate: false)
        } rescuing: { error in
            guard error is SettlementRace else { throw error }
            return .rejected(
                code: .inactiveDispatch,
                reason: "Dispatch \(dispatchID) changed while its worker report was settling."
            )
        }
    }
}

/// Internal signal: the guarded settlement UPDATEs raced another writer.
private struct SettlementRace: Error {}

extension SQLiteDatabase {
    /// `inSavepoint` variant that lets the caller translate a rollback-causing error
    /// into a value instead of rethrowing.
    func inSavepoint<T>(
        _ name: String, _ body: () throws -> T, rescuing rescue: (Error) throws -> T
    ) throws -> T {
        do {
            return try inSavepoint(name, body)
        } catch {
            return try rescue(error)
        }
    }
}
