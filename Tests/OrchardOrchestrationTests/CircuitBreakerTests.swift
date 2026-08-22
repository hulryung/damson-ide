import XCTest
@testable import OrchardOrchestration

/// 3 consecutive dispatch failures ⇒ circuit_broken dispatch + failed task, with the
/// failure count carried across retries so the budget accumulates per task, not per row.
final class CircuitBreakerTests: StoreTestCase {
    func testFailureBelowThresholdReturnsTaskToReady() throws {
        let fixture = try makeDispatchedTask()
        let failed = try XCTUnwrap(try store.failDispatch(fixture.dispatch.id, error: "crash 1"))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.failureCount, 1)
        XCTAssertEqual(failed.lastFailure, "crash 1")
        // Back to 'ready', not 'pending' — 'pending' would strand it, since promotion
        // only runs when a dependency completes.
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .ready)
    }

    func testThirdConsecutiveFailureBreaksCircuitAndFailsTask() throws {
        let fixture = try makeDispatchedTask()
        _ = try store.failDispatch(fixture.dispatch.id, error: "crash 1")

        let second = try store.createDispatchContext(
            taskID: fixture.task.id, assigneeHandle: "term_w2", assigneePaneKey: "pane_w2")
        XCTAssertEqual(second.failureCount, 1, "failure budget carries into the retry")
        _ = try store.failDispatch(second.id, error: "crash 2")
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .ready)

        let third = try store.createDispatchContext(
            taskID: fixture.task.id, assigneeHandle: "term_w3", assigneePaneKey: "pane_w3")
        XCTAssertEqual(third.failureCount, 2)
        let broken = try XCTUnwrap(try store.failDispatch(third.id, error: "crash 3"))

        XCTAssertEqual(broken.status, .circuitBroken)
        XCTAssertEqual(broken.failureCount, 3)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .failed)
    }

    func testCircuitBrokenTaskCannotBeRedispatched() throws {
        let fixture = try makeDispatchedTask()
        for handle in ["term_w1", "term_w2", "term_w3"] {
            let active = try XCTUnwrap(try store.activeDispatchForTask(fixture.task.id))
            _ = try store.failDispatch(active.id, error: "crash")
            if try store.task(fixture.task.id)?.status == .ready {
                _ = try store.createDispatchContext(
                    taskID: fixture.task.id, assigneeHandle: handle, assigneePaneKey: "pane_\(handle)")
            }
        }
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .failed)
        XCTAssertThrowsError(
            try store.createDispatchContext(taskID: fixture.task.id, assigneeHandle: "term_w4")
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "task_not_startable")
        }
    }

    func testFailDispatchRefusesWhileSupervisedWorkerIsLive() throws {
        let fixture = try makeDispatchedTask()
        _ = try store.createWorkerDispatch(dispatchID: fixture.dispatch.id)
        _ = try store.updateWorkerDispatch(fixture.dispatch.id, state: .ready)

        XCTAssertThrowsError(
            try store.failDispatch(fixture.dispatch.id, error: "manual fail")
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "task_not_startable")
        }
        // With the process provably gone, the same failure lands and settles the worker.
        let failed = try XCTUnwrap(try store.failDispatch(
            fixture.dispatch.id, error: "process exited", workerProcessExited: true))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(try store.workerDispatch(fixture.dispatch.id)?.state, .failed)
        XCTAssertEqual(try store.workerDispatch(fixture.dispatch.id)?.stage, "process_exited")
    }

    func testLateFailureCannotReopenASettledTask() throws {
        let fixture = try makeDispatchedTask()
        _ = try sendWorkerDone(fixture)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .completed)

        // A straggler failure for the already-settled dispatch changes nothing.
        let after = try store.failDispatch(fixture.dispatch.id, error: "late crash")
        XCTAssertEqual(after?.status, .completed)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .completed)
    }

    func testFailureCountSurvivesInterleavedTasks() throws {
        let fixture = try makeDispatchedTask()
        // Another task failing repeatedly must not consume this task's budget.
        let other = try store.createTask(runID: fixture.run.id, spec: "other")
        let otherDispatch = try store.createDispatchContext(
            taskID: other.id, assigneeHandle: "term_other", assigneePaneKey: "pane_other")
        _ = try store.failDispatch(otherDispatch.id, error: "other crash")

        _ = try store.failDispatch(fixture.dispatch.id, error: "crash 1")
        let retry = try store.createDispatchContext(
            taskID: fixture.task.id, assigneeHandle: "term_w2", assigneePaneKey: "pane_w2")
        XCTAssertEqual(retry.failureCount, 1)
    }
}
