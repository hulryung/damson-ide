import XCTest
@testable import OrchardOrchestration

/// Decision gates never auto-resolve, and a pending gate force-re-blocks its task.
final class GateTests: StoreTestCase {
    func testCreateGateBlocksTaskAndSettlesActiveDispatches() throws {
        let fixture = try makeDispatchedTask()
        let gate = try store.createGate(taskID: fixture.task.id, question: "ship it?", options: ["yes", "no"])

        XCTAssertEqual(gate.status, .pending)
        XCTAssertEqual(gate.options, ["yes", "no"])
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .blocked)
        // The worker asked and is done for now: its dispatch completes.
        XCTAssertEqual(try store.dispatchContext(fixture.dispatch.id)?.status, .completed)
    }

    func testResolveGateReturnsTaskToReady() throws {
        let fixture = try makeDispatchedTask()
        let gate = try store.createGate(taskID: fixture.task.id, question: "ship it?")
        let resolved = try XCTUnwrap(try store.resolveGate(gate.id, resolution: "yes"))

        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertEqual(resolved.resolution, "yes")
        XCTAssertNotNil(resolved.resolvedAt)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .ready)
    }

    func testGatesNeverAutoResolve() throws {
        let fixture = try makeDispatchedTask()
        let gate = try store.createGate(taskID: fixture.task.id, question: "ship it?")

        // Nothing that happens around the task resolves the gate: not reblock ticks,
        // not task-status churn, not other traffic.
        _ = try store.reblockTasksWithPendingGates()
        try sendStatusMessages(3, runID: fixture.run.id)
        XCTAssertEqual(try store.gate(gate.id)?.status, .pending)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .blocked)
    }

    func testPendingGateForceReblocksItsTask() throws {
        let fixture = try makeDispatchedTask()
        let gate = try store.createGate(taskID: fixture.task.id, question: "ship it?")
        _ = gate

        // Someone (or a bug) moves the gated task off 'blocked'…
        _ = try store.updateTaskStatus(fixture.task.id, .ready)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .ready)

        // …the coordinator tick restores the invariant.
        let reblocked = try store.reblockTasksWithPendingGates()
        XCTAssertEqual(reblocked, [fixture.task.id])
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .blocked)
    }

    func testReblockLeavesResolvedGatesAlone() throws {
        let fixture = try makeDispatchedTask()
        let gate = try store.createGate(taskID: fixture.task.id, question: "ship it?")
        _ = try store.resolveGate(gate.id, resolution: "yes")

        let reblocked = try store.reblockTasksWithPendingGates()
        XCTAssertTrue(reblocked.isEmpty)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .ready)
    }

    func testTimeoutOnlyExpiresPendingGates() throws {
        let fixture = try makeDispatchedTask()
        let gate = try store.createGate(taskID: fixture.task.id, question: "ship it?")
        _ = try store.resolveGate(gate.id, resolution: "yes")

        // A late timeout must not overwrite the human's resolution.
        let after = try store.timeoutGate(gate.id)
        XCTAssertEqual(after?.status, .resolved)
        XCTAssertEqual(after?.resolution, "yes")
    }

    func testGateRequesterMustOwnActiveDispatch() throws {
        let fixture = try makeDispatchedTask()
        XCTAssertThrowsError(
            try store.createGate(
                taskID: fixture.task.id, question: "ship it?",
                requester: (handle: "term_imposter", paneKey: "pane_imposter", dispatchID: fixture.dispatch.id))
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "consumer_fenced")
        }
        // The real assignee (matching pane) may open the gate.
        let gate = try store.createGate(
            taskID: fixture.task.id, question: "ship it?",
            requester: (handle: "term_worker", paneKey: "pane_worker", dispatchID: fixture.dispatch.id))
        XCTAssertEqual(gate.status, .pending)
    }

    func testGateRefusedWhileSupervisedWorkerIsLive() throws {
        let fixture = try makeDispatchedTask()
        _ = try store.createWorkerDispatch(dispatchID: fixture.dispatch.id)
        _ = try store.updateWorkerDispatch(fixture.dispatch.id, state: .ready)

        XCTAssertThrowsError(
            try store.createGate(taskID: fixture.task.id, question: "ship it?")
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "task_not_startable")
        }
    }

    func testResolvedGateQAFlowsIntoNextPreamble() throws {
        let fixture = try makeDispatchedTask()
        let gate = try store.createGate(taskID: fixture.task.id, question: "Which DB?")
        _ = try store.resolveGate(gate.id, resolution: "SQLite")

        let resolvedGates = try store.listGates(taskID: fixture.task.id, status: .resolved)
            .compactMap { gate in gate.resolution.map { (question: gate.question, resolution: $0) } }
        let preamble = DispatchPreamble.build(DispatchPreamble.Params(
            taskID: fixture.task.id, dispatchID: "ctx_retry", taskSpec: "retry it",
            coordinatorHandle: "term_coord", workerHandle: "term_worker",
            resolvedGates: resolvedGates))
        XCTAssertTrue(preamble.contains("RESOLVED DECISION GATES"))
        XCTAssertTrue(preamble.contains("Q: Which DB?"))
        XCTAssertTrue(preamble.contains("A: SQLite"))
    }
}
