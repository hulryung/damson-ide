import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// UI-free orchestration view projection: run/task/dispatch row models and the
/// archive decode that `worker-read` uses for cleaned vs raw lines.
final class OrchestrationViewProjectionTests: XCTestCase {

    // MARK: - Names / titles

    func testDisplayNamePrefersDisplayThenTitleThenSpec() {
        XCTAssertEqual(
            OrchestrationProjection.displayName(
                displayName: "T44", taskTitle: "In-app view", spec: "Build the window"),
            "T44")
        XCTAssertEqual(
            OrchestrationProjection.displayName(
                displayName: nil, taskTitle: "In-app view", spec: "Build the window"),
            "In-app view")
        XCTAssertEqual(
            OrchestrationProjection.displayName(
                displayName: "  ", taskTitle: nil, spec: "Build the window"),
            "Build the window")
    }

    func testTitlePrefersTaskTitleThenDisplayThenSpec() {
        XCTAssertEqual(
            OrchestrationProjection.title(
                displayName: "T44", taskTitle: "In-app view", spec: "Build the window"),
            "In-app view")
        XCTAssertEqual(
            OrchestrationProjection.title(
                displayName: "T44", taskTitle: nil, spec: "Build the window"),
            "T44")
    }

    func testAbbreviateSpecMatchesBriefTaskList() {
        XCTAssertEqual(OrchestrationProjection.abbreviateSpec("short"), "short")
        let long = String(repeating: "a", count: 90)
        let abbreviated = OrchestrationProjection.abbreviateSpec(long)
        XCTAssertEqual(abbreviated.count, 80)
        XCTAssertTrue(abbreviated.hasSuffix("…"))
    }

    func testTaskRowLabelPrefersDisplayName() {
        let row = OrchestrationProjection.taskRow(
            id: "task_1", status: "ready", deps: ["task_0"],
            displayName: "T44", taskTitle: "In-app view", spec: "Build it",
            dispatches: [])
        XCTAssertEqual(row.displayName, "T44")
        XCTAssertEqual(row.title, "In-app view")
        XCTAssertEqual(row.label, "T44")
        XCTAssertEqual(row.deps, ["task_0"])
    }

    // MARK: - Counts

    func testTaskCountsByStatus() {
        let counts = OrchestrationProjection.counts(statuses: [
            "pending", "ready", "ready", "dispatched", "completed", "failed", "blocked",
        ])
        XCTAssertEqual(counts.total, 7)
        XCTAssertEqual(counts.pending, 1)
        XCTAssertEqual(counts.ready, 2)
        XCTAssertEqual(counts.dispatched, 1)
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.blocked, 1)
        XCTAssertTrue(counts.summary.contains("7 tasks"))
        XCTAssertTrue(counts.summary.contains("1 dispatched"))
    }

    func testEmptyCounts() {
        let counts = OrchestrationProjection.counts(statuses: [])
        XCTAssertEqual(counts.total, 0)
        XCTAssertEqual(counts.summary, "0 tasks")
    }

    func testRunRowCountsFromChildTasks() {
        let run = OrchestrationProjection.runRow(
            id: "run_1",
            objective: "Wave 11",
            createdAt: "2026-08-24 01:00:00",
            tasks: [
                OrchestrationProjection.taskRow(
                    id: "task_a", status: "completed", deps: [],
                    displayName: "T43", taskTitle: nil, spec: "ssh restore",
                    dispatches: []),
                OrchestrationProjection.taskRow(
                    id: "task_b", status: "dispatched", deps: ["task_a"],
                    displayName: "T44", taskTitle: "Orch view", spec: "Build view",
                    dispatches: []),
            ])
        XCTAssertEqual(run.counts.total, 2)
        XCTAssertEqual(run.counts.completed, 1)
        XCTAssertEqual(run.counts.dispatched, 1)
        XCTAssertEqual(run.objective, "Wave 11")
        XCTAssertEqual(run.createdAt, "2026-08-24 01:00:00")
    }

    // MARK: - Dispatch / terminal state

    func testTerminalStateMirrorsWorkerListDerive() {
        XCTAssertEqual(
            OrchestrationProjection.terminalState(
                workerState: "ready", agentHandle: "term_w",
                releaseState: nil, ownershipState: nil),
            "retained")
        XCTAssertNil(
            OrchestrationProjection.terminalState(
                workerState: "unsupervised", agentHandle: nil,
                releaseState: nil, ownershipState: nil))
        XCTAssertEqual(
            OrchestrationProjection.terminalState(
                workerState: "ready", agentHandle: "term_w",
                releaseState: "not_requested", ownershipState: "owned"),
            "active")
        XCTAssertEqual(
            OrchestrationProjection.terminalState(
                workerState: "succeeded", agentHandle: "term_w",
                releaseState: "not_requested", ownershipState: "owned"),
            "reclaimable")
        XCTAssertEqual(
            OrchestrationProjection.terminalState(
                workerState: "failed", agentHandle: "term_w",
                releaseState: "released", ownershipState: "released"),
            "released")
        XCTAssertEqual(
            OrchestrationProjection.terminalState(
                workerState: "succeeded", agentHandle: "term_w",
                releaseState: "retained", ownershipState: "owned"),
            "retained")
        XCTAssertEqual(
            OrchestrationProjection.terminalState(
                workerState: "ready", agentHandle: "term_w",
                releaseState: "releasing", ownershipState: "owned"),
            "release_pending")
        XCTAssertEqual(
            OrchestrationProjection.terminalState(
                workerState: "ready", agentHandle: "term_w",
                releaseState: "unknown", ownershipState: "owned"),
            "release_unknown")
        XCTAssertEqual(
            OrchestrationProjection.terminalState(
                workerState: "ready", agentHandle: "term_w",
                releaseState: "not_requested", ownershipState: "external"),
            "retained")
    }

    func testDispatchRowCarriesStatusesAndHandle() {
        let row = OrchestrationProjection.dispatchRow(
            id: "ctx_1",
            dispatchStatus: "dispatched",
            workerState: "ready",
            agentHandle: "term_worker",
            releaseState: "not_requested",
            ownershipState: "owned",
            hasArchive: false)
        XCTAssertEqual(row.dispatchStatus, "dispatched")
        XCTAssertEqual(row.workerState, "ready")
        XCTAssertEqual(row.terminalState, "active")
        XCTAssertEqual(row.agentHandle, "term_worker")
        XCTAssertFalse(row.hasArchive)
    }

    // MARK: - Archive decode (worker-read shape)

    func testArchiveViewPrefersCleanedLinesAndKeepsRaw() {
        let json = """
        {"lines":["building the thing","all tests passed"],\
        "rawLines":["spinner","building the thing","spinner","all tests passed"],\
        "fallbackReason":"provider_transcript_unavailable"}
        """
        let view = OrchestrationProjection.archiveView(
            dispatchID: "ctx_1", kind: "terminal_tail", contentJSON: json)
        XCTAssertFalse(view.isTranscript)
        XCTAssertEqual(view.cleanedLines, ["building the thing", "all tests passed"])
        XCTAssertEqual(view.rawLines.count, 4)
        XCTAssertEqual(view.lines(showRaw: false), view.cleanedLines)
        XCTAssertEqual(view.lines(showRaw: true), view.rawLines)
    }

    func testArchiveViewFallsBackToCleanedWhenRawMissing() {
        let json = #"{"lines":["readable only"]}"#
        let view = OrchestrationProjection.archiveView(
            dispatchID: "ctx_1", kind: "terminal_tail", contentJSON: json)
        XCTAssertEqual(view.lines(showRaw: true), ["readable only"])
        XCTAssertEqual(view.lines(showRaw: false), ["readable only"])
    }

    func testTranscriptPinServesContentAndIgnoresRawToggle() {
        let json = #"{"content":"line one\nline two","path":"/tmp/session.jsonl","truncated":false}"#
        let view = OrchestrationProjection.archiveView(
            dispatchID: "ctx_1", kind: "transcript_pin", contentJSON: json)
        XCTAssertTrue(view.isTranscript)
        XCTAssertEqual(view.transcript, "line one\nline two")
        XCTAssertEqual(view.lines(showRaw: false), ["line one", "line two"])
        XCTAssertEqual(view.lines(showRaw: true), ["line one", "line two"])
    }

    func testArchiveViewEmptyJSONIsEmpty() {
        let view = OrchestrationProjection.archiveView(
            dispatchID: "ctx_1", kind: "terminal_tail", contentJSON: "{}")
        XCTAssertEqual(view.cleanedLines, [])
        XCTAssertEqual(view.rawLines, [])
        XCTAssertEqual(view.lines(showRaw: false), [])
    }

    // MARK: - Live store snapshot

    func testViewSnapshotProjectsRunTaskAndDispatch() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-view-\(UUID().uuidString).db").path
        let live = try LiveOrchestrationStore(databasePath: path)
        let created = try await live.runCreate([
            "objective": .string("Wave 11 orch view"),
            "from": .string("term_coord"),
        ])
        let runID = try XCTUnwrap(created.field("runId")?.stringValue)
        let first = try await live.taskCreate([
            "run": .string(runID),
            "spec": .string("Restore remote panes"),
            "task-title": .string("SSH stage 4"),
            "display-name": .string("T43"),
            "from": .string("term_coord"),
        ])
        let depID = try XCTUnwrap(first.field("taskId")?.stringValue)
        let second = try await live.taskCreate([
            "run": .string(runID),
            "spec": .string("Build the in-app orchestration view"),
            "task-title": .string("In-app orch view"),
            "display-name": .string("T44"),
            "deps": .string(depID),
            "from": .string("term_coord"),
        ])
        let taskID = try XCTUnwrap(second.field("taskId")?.stringValue)
        _ = try await live.taskUpdate([
            "id": .string(depID), "status": .string("completed"),
        ])
        let dispatched = try await live.dispatchTask([
            "task": .string(taskID), "to": .string("term_worker"),
        ])
        let dispatchID = try XCTUnwrap(dispatched.field("dispatchId")?.stringValue)

        let snapshot = try await live.viewSnapshot()
        XCTAssertEqual(snapshot.runs.count, 1)
        let run = try XCTUnwrap(snapshot.runs.first)
        XCTAssertEqual(run.id, runID)
        XCTAssertEqual(run.objective, "Wave 11 orch view")
        XCTAssertFalse(run.createdAt.isEmpty)
        XCTAssertEqual(run.counts.total, 2)
        XCTAssertEqual(run.counts.completed, 1)
        XCTAssertEqual(run.counts.dispatched, 1)

        let t43 = try XCTUnwrap(run.tasks.first { $0.id == depID })
        XCTAssertEqual(t43.displayName, "T43")
        XCTAssertEqual(t43.title, "SSH stage 4")
        XCTAssertEqual(t43.status, "completed")
        XCTAssertEqual(t43.dispatches, [])

        let t44 = try XCTUnwrap(run.tasks.first { $0.id == taskID })
        XCTAssertEqual(t44.displayName, "T44")
        XCTAssertEqual(t44.title, "In-app orch view")
        XCTAssertEqual(t44.status, "dispatched")
        XCTAssertEqual(t44.deps, [depID])
        XCTAssertEqual(t44.dispatches.count, 1)
        let dispatch = try XCTUnwrap(t44.dispatches.first)
        XCTAssertEqual(dispatch.id, dispatchID)
        XCTAssertEqual(dispatch.dispatchStatus, "dispatched")
        XCTAssertEqual(dispatch.workerState, "unsupervised")
        XCTAssertEqual(dispatch.agentHandle, "term_worker")
        XCTAssertEqual(dispatch.terminalState, "retained")
        XCTAssertFalse(dispatch.hasArchive)
        let archive = try await live.viewArchive(dispatchID: dispatchID)
        XCTAssertNil(archive)
    }

    func testViewSnapshotEmptyStore() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-view-empty-\(UUID().uuidString).db").path
        let live = try LiveOrchestrationStore(databasePath: path)
        let snapshot = try await live.viewSnapshot()
        XCTAssertEqual(snapshot, .empty)
    }
}
