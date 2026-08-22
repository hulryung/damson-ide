import XCTest
@testable import OrchardOrchestration

/// `(taskId, dispatchId)`-keyed settlement: worker_done auto-completes its task and
/// dispatch, everything else gets a typed rejection.
final class SettlementTests: StoreTestCase {
    func testWorkerDoneSucceededCompletesTaskAndDispatch() throws {
        let fixture = try makeDispatchedTask()
        let receipt = try sendWorkerDone(fixture)

        XCTAssertEqual(
            receipt.lifecycle, .completed(taskID: fixture.task.id, dispatchID: fixture.dispatch.id))
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .completed)
        let dispatch = try XCTUnwrap(try store.dispatchContext(fixture.dispatch.id))
        XCTAssertEqual(dispatch.status, .completed)
        XCTAssertNotNil(dispatch.completedAt)
        XCTAssertNotNil(dispatch.capabilityRevokedAt)
        // The task result records worker-report provenance.
        let result = try XCTUnwrap(JSONCoding.decodeObject(try store.task(fixture.task.id)?.result))
        XCTAssertEqual(result["provenance"] as? String, "worker_report")
        XCTAssertEqual(result["outcome"] as? String, "succeeded")
    }

    func testWorkerDoneFailedFailsTaskAndDispatch() throws {
        let fixture = try makeDispatchedTask()
        let receipt = try sendWorkerDone(fixture, outcome: "failed")

        XCTAssertEqual(
            receipt.lifecycle, .failed(taskID: fixture.task.id, dispatchID: fixture.dispatch.id))
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .failed)
        let dispatch = try XCTUnwrap(try store.dispatchContext(fixture.dispatch.id))
        XCTAssertEqual(dispatch.status, .failed)
        XCTAssertNotNil(dispatch.lastFailure)
    }

    func testDuplicateWorkerDoneIsIdempotent() throws {
        let fixture = try makeDispatchedTask()
        _ = try sendWorkerDone(fixture)
        let settlement = try store.settleWorkerReport(
            taskID: fixture.task.id, dispatchID: fixture.dispatch.id,
            outcome: .succeeded, result: "{}")
        XCTAssertEqual(settlement, .settled(outcome: .succeeded, duplicate: true))
    }

    // MARK: - The five typed rejections

    func testUnknownTaskRejection() throws {
        let fixture = try makeDispatchedTask()
        let settlement = try store.settleWorkerReport(
            taskID: "task_missing", dispatchID: fixture.dispatch.id,
            outcome: .succeeded, result: "{}")
        assertRejected(settlement, .unknownTask)
    }

    func testUnknownDispatchRejection() throws {
        let fixture = try makeDispatchedTask()
        let settlement = try store.settleWorkerReport(
            taskID: fixture.task.id, dispatchID: "ctx_missing",
            outcome: .succeeded, result: "{}")
        assertRejected(settlement, .unknownDispatch)
    }

    func testTaskDispatchMismatchRejection() throws {
        let fixture = try makeDispatchedTask()
        let otherTask = try store.createTask(runID: fixture.run.id, spec: "other")
        let otherDispatch = try store.createDispatchContext(
            taskID: otherTask.id, assigneeHandle: "term_other", assigneePaneKey: "pane_other")

        let settlement = try store.settleWorkerReport(
            taskID: fixture.task.id, dispatchID: otherDispatch.id,
            outcome: .succeeded, result: "{}")
        assertRejected(settlement, .taskDispatchMismatch)
    }

    func testInactiveDispatchRejectionAfterOppositeSettlement() throws {
        let fixture = try makeDispatchedTask()
        _ = try sendWorkerDone(fixture, outcome: "failed")
        // A succeeded report against the already-failed dispatch is not a duplicate —
        // it contradicts the recorded outcome, so it must be rejected.
        let settlement = try store.settleWorkerReport(
            taskID: fixture.task.id, dispatchID: fixture.dispatch.id,
            outcome: .succeeded, result: "{}")
        assertRejected(settlement, .inactiveDispatch)
    }

    func testLateReportFromFailedAttemptCannotSettleLiveRetry() throws {
        let fixture = try makeDispatchedTask()
        // First attempt dies; the task returns to ready and is re-dispatched elsewhere.
        _ = try store.failDispatch(fixture.dispatch.id, error: "worker crashed")
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .ready)
        let retry = try store.createDispatchContext(
            taskID: fixture.task.id, assigneeHandle: "term_retry", assigneePaneKey: "pane_retry")

        // The dead attempt's late report cannot settle the live retry.
        let settlement = try store.settleWorkerReport(
            taskID: fixture.task.id, dispatchID: fixture.dispatch.id,
            outcome: .succeeded, result: "{}")
        assertRejected(settlement, .inactiveDispatch)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .dispatched)
        XCTAssertEqual(try store.dispatchContext(retry.id)?.status, .dispatched)
    }

    func testStaleDispatchRejectionForSupersededActiveAttempt() throws {
        let fixture = try makeDispatchedTask()
        // Two active dispatch rows for one task can only arise from a race the claim
        // SQL lost (or a legacy import); construct it directly to pin the guard.
        try store.db.run(
            """
            INSERT INTO dispatch_contexts (
              id, run_id, task_id, assignee_handle, status, dispatched_at
            ) VALUES ('ctx_newer', ?, ?, 'term_newer', 'dispatched', datetime('now'))
            """,
            [.text(fixture.run.id), .text(fixture.task.id)]
        )
        // The older attempt has no worker_dispatches row and is not the current
        // (latest) dispatch, so its report is stale.
        let settlement = try store.settleWorkerReport(
            taskID: fixture.task.id, dispatchID: fixture.dispatch.id,
            outcome: .succeeded, result: "{}")
        assertRejected(settlement, .staleDispatch)
    }

    func testLiveSupervisedSiblingBlocksSettlement() throws {
        let fixture = try makeDispatchedTask()
        // A sibling dispatch of the same task whose supervised worker is still live —
        // constructed directly, since the claim SQL normally prevents two active rows.
        try store.db.run(
            """
            INSERT INTO dispatch_contexts (
              id, run_id, task_id, assignee_handle, status, dispatched_at
            ) VALUES ('ctx_sib', ?, ?, 'term_sib', 'dispatched', datetime('now'))
            """,
            [.text(fixture.run.id), .text(fixture.task.id)]
        )
        _ = try store.createWorkerDispatch(dispatchID: "ctx_sib")
        _ = try store.updateWorkerDispatch("ctx_sib", state: .ready)

        // Completing "around" the live sibling is refused…
        let settlement = try store.settleWorkerReport(
            taskID: fixture.task.id, dispatchID: fixture.dispatch.id,
            outcome: .succeeded, result: "{}")
        assertRejected(settlement, .inactiveDispatch)

        // …while the live supervised attempt itself settles fine, and settlement sweeps
        // the leftover sibling with it.
        let siblingSettlement = try store.settleWorkerReport(
            taskID: fixture.task.id, dispatchID: "ctx_sib", outcome: .succeeded, result: "{}")
        XCTAssertEqual(siblingSettlement, .settled(outcome: .succeeded, duplicate: false))
        XCTAssertEqual(try store.workerDispatch("ctx_sib")?.state, .succeeded)
        XCTAssertEqual(try store.dispatchContext(fixture.dispatch.id)?.status, .completed)
    }

    // MARK: - Send-path payload rejections

    func testWorkerDoneWithoutOutcomeIsRefusedAtSend() throws {
        let fixture = try makeDispatchedTask()
        XCTAssertThrowsError(
            try store.sendMessage(OutboundMessage(
                from: "term_worker", senderPaneKey: "pane_worker", runID: fixture.run.id,
                subject: "done", type: .workerDone,
                payload: JSONCoding.encodeObject(
                    ["taskId": fixture.task.id, "dispatchId": fixture.dispatch.id])))
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "invalid_argument")
        }
    }

    func testWorkerDoneMissingDispatchIDIsRejectedAndRowConverted() throws {
        let fixture = try makeDispatchedTask()
        let receipt = try store.sendMessage(OutboundMessage(
            from: "term_worker", senderPaneKey: "pane_worker", runID: fixture.run.id,
            subject: "done", type: .workerDone,
            payload: JSONCoding.encodeObject(
                ["taskId": fixture.task.id, "outcome": "succeeded"])))
        guard case .rejected(let code, _)? = receipt.lifecycle else {
            return XCTFail("expected rejection, got \(String(describing: receipt.lifecycle))")
        }
        XCTAssertEqual(code, "missing_dispatch_id")
        // The row was rewritten into an auditable rejection, and the task is untouched.
        let stored = try XCTUnwrap(try store.message(receipt.messages[0].id))
        XCTAssertTrue(stored.subject.hasPrefix("Rejected worker_done"))
        XCTAssertEqual(stored.priority, .high)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .dispatched)
    }

    func testWorkerDoneFromWrongPaneIsRejected() throws {
        let fixture = try makeDispatchedTask()
        let receipt = try sendWorkerDone(fixture, from: "term_imposter", senderPaneKey: "pane_imposter")
        guard case .rejected(let code, _)? = receipt.lifecycle else {
            return XCTFail("expected rejection, got \(String(describing: receipt.lifecycle))")
        }
        XCTAssertEqual(code, "sender_not_assignee")
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .dispatched)
        XCTAssertEqual(try store.dispatchContext(fixture.dispatch.id)?.status, .dispatched)
    }

    func testSettlementClosesPendingQuestionsOfTheDispatch() throws {
        let fixture = try makeDispatchedTask()
        let (question, _) = try store.createQuestion(
            runID: fixture.run.id, dispatchID: fixture.dispatch.id,
            askerHandle: "term_worker", question: "which color?")
        _ = try sendWorkerDone(fixture)
        XCTAssertEqual(try store.question(question.messageID)?.status, .closed)
    }

    func testSettlementPromotesDependentTasks() throws {
        let fixture = try makeDispatchedTask()
        let dependent = try store.createTask(
            runID: fixture.run.id, spec: "downstream", deps: [fixture.task.id])
        XCTAssertEqual(dependent.status, .pending)
        _ = try sendWorkerDone(fixture)
        XCTAssertEqual(try store.task(dependent.id)?.status, .ready)
    }

    func testFailedOutcomeDoesNotPromoteDependents() throws {
        let fixture = try makeDispatchedTask()
        let dependent = try store.createTask(
            runID: fixture.run.id, spec: "downstream", deps: [fixture.task.id])
        _ = try sendWorkerDone(fixture, outcome: "failed")
        XCTAssertEqual(try store.task(dependent.id)?.status, .pending)
    }

    func testWorkerDoneSuppressesItsEarlierHeartbeats() throws {
        let fixture = try makeDispatchedTask()
        try sendHeartbeat(fixture)
        try sendHeartbeat(fixture)
        _ = try sendWorkerDone(fixture)

        let unreadHeartbeats = try store.unreadMessages(
            to: "run:\(fixture.run.id)", types: [.heartbeat])
        XCTAssertTrue(unreadHeartbeats.isEmpty)
        // The worker_done itself stays unread for the coordinator's next batch.
        let unreadDone = try store.unreadMessages(to: "run:\(fixture.run.id)", types: [.workerDone])
        XCTAssertEqual(unreadDone.count, 1)
    }
}
