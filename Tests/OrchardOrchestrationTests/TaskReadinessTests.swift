import XCTest
@testable import OrchardOrchestration

/// DAG readiness: computed at create, promoted on dependency completion, surfaced via
/// `listTasks(ready:)` (`task-list --ready`).
final class TaskReadinessTests: StoreTestCase {
    private func makeRun() throws -> OrchestrationRun {
        try store.createRun(
            objective: "dag", coordinatorHandle: "term_coord", coordinatorPaneKey: "pane_coord")
    }

    func testTaskWithNoDepsIsBornReady() throws {
        let run = try makeRun()
        let task = try store.createTask(runID: run.id, spec: "leaf")
        XCTAssertEqual(task.status, .ready)
    }

    func testTaskWithIncompleteDepsIsBornPending() throws {
        let run = try makeRun()
        let dep = try store.createTask(runID: run.id, spec: "dep")
        let task = try store.createTask(runID: run.id, spec: "child", deps: [dep.id])
        XCTAssertEqual(task.status, .pending)
    }

    func testTaskWithAllDepsCompletedIsBornReady() throws {
        let run = try makeRun()
        let dep = try store.createTask(runID: run.id, spec: "dep")
        _ = try store.createDispatchContext(taskID: dep.id, assigneeHandle: "term_w")
        _ = try store.updateTaskStatus(dep.id, .completed)

        let task = try store.createTask(runID: run.id, spec: "child", deps: [dep.id])
        XCTAssertEqual(task.status, .ready)
    }

    func testUnknownDependencyIsRefused() throws {
        let run = try makeRun()
        XCTAssertThrowsError(
            try store.createTask(runID: run.id, spec: "child", deps: ["task_ghost"])
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "invalid_argument")
        }
    }

    func testCrossRunDependencyIsRefused() throws {
        let runA = try makeRun()
        let runB = try store.createRun(
            objective: "other", coordinatorHandle: "term_other", coordinatorPaneKey: "pane_other")
        let foreign = try store.createTask(runID: runB.id, spec: "foreign")
        XCTAssertThrowsError(
            try store.createTask(runID: runA.id, spec: "child", deps: [foreign.id]))
    }

    func testCompletionPromotesOnlyFullySatisfiedDependents() throws {
        let run = try makeRun()
        let depA = try store.createTask(runID: run.id, spec: "A")
        let depB = try store.createTask(runID: run.id, spec: "B")
        let needsA = try store.createTask(runID: run.id, spec: "needs A", deps: [depA.id])
        let needsBoth = try store.createTask(runID: run.id, spec: "needs both", deps: [depA.id, depB.id])

        _ = try store.createDispatchContext(taskID: depA.id, assigneeHandle: "term_a")
        _ = try store.updateTaskStatus(depA.id, .completed)

        XCTAssertEqual(try store.task(needsA.id)?.status, .ready)
        XCTAssertEqual(try store.task(needsBoth.id)?.status, .pending)

        _ = try store.createDispatchContext(taskID: depB.id, assigneeHandle: "term_b")
        _ = try store.updateTaskStatus(depB.id, .completed)
        XCTAssertEqual(try store.task(needsBoth.id)?.status, .ready)
    }

    func testListTasksReadyFiltersToReadyOnly() throws {
        let run = try makeRun()
        let ready = try store.createTask(runID: run.id, spec: "ready")
        let pending = try store.createTask(runID: run.id, spec: "pending", deps: [ready.id])
        _ = pending

        let readyList = try store.listTasks(runID: run.id, ready: true)
        XCTAssertEqual(readyList.map(\.id), [ready.id])
        XCTAssertEqual(try store.listTasks(runID: run.id).count, 2)
    }

    func testDispatchedRequiresActiveDispatch() throws {
        let run = try makeRun()
        let task = try store.createTask(runID: run.id, spec: "t")
        XCTAssertThrowsError(try store.updateTaskStatus(task.id, .dispatched)) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "task_not_startable")
        }
    }

    func testNonTerminalTransitionRefusedWhileDispatchActive() throws {
        let fixture = try makeDispatchedTask()
        XCTAssertThrowsError(try store.updateTaskStatus(fixture.task.id, .ready)) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "task_not_startable")
        }
    }

    func testManualCompletionSettlesActiveDispatch() throws {
        let fixture = try makeDispatchedTask()
        _ = try store.updateTaskStatus(fixture.task.id, .completed, result: "manual override")
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .completed)
        XCTAssertEqual(try store.dispatchContext(fixture.dispatch.id)?.status, .completed)
    }

    func testTerminalTransitionRefusedWhileSupervisedWorkerLive() throws {
        let fixture = try makeDispatchedTask()
        _ = try store.createWorkerDispatch(dispatchID: fixture.dispatch.id)
        _ = try store.updateWorkerDispatch(fixture.dispatch.id, state: .ready)
        XCTAssertThrowsError(try store.updateTaskStatus(fixture.task.id, .completed)) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "task_not_startable")
        }
    }
}
