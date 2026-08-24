import XCTest
import OrchardOrchestration
@testable import OrchardRuntime

/// T49 UI-free logic: how archives group into run → task → dispatch, what the text
/// filter matches, and how a transcript pin decides between a message stream and
/// plain text.
final class VaultProjectionTests: XCTestCase {

    // MARK: - Fixtures

    private func record(
        dispatch: String,
        run: String? = "run_1",
        runObjective: String? = "Wave 12",
        task: String? = "task_1",
        taskTitle: String? = "Vault",
        taskDisplayName: String? = "T49",
        spec: String = "build the vault",
        kind: WorkerTerminalArchiveKind = .terminalTail,
        createdAt: String = "2026-08-01 10:00:00",
        bytes: Int = 100,
        handle: String? = "term_worker",
        engine: String? = "claude-code",
        status: DispatchStatus? = .completed,
        scan: String = "",
        scanTruncated: Bool = false
    ) -> WorkerArchiveRecord {
        WorkerArchiveRecord(
            dispatchID: dispatch,
            kind: kind,
            createdAt: createdAt,
            byteSize: bytes,
            runID: run,
            runObjective: runObjective,
            runCreatedAt: "2026-07-01 09:00:00",
            taskID: task,
            taskTitle: taskTitle,
            taskDisplayName: taskDisplayName,
            taskSpec: spec,
            dispatchStatus: status,
            workerState: "succeeded",
            agentHandle: handle,
            engineID: engine,
            contentScan: scan,
            contentScanTruncated: scanTruncated)
    }

    // MARK: - Grouping

    func testGroupsByRunThenTaskPreservingStoreOrder() {
        let snapshot = VaultProjection.snapshot(records: [
            record(dispatch: "ctx_c", run: "run_2", runObjective: "Wave 13", task: "task_9",
                   taskDisplayName: "T50", bytes: 10),
            record(dispatch: "ctx_b", task: "task_2", taskDisplayName: "T48", bytes: 20),
            record(dispatch: "ctx_a", task: "task_1", bytes: 30),
            record(dispatch: "ctx_a2", task: "task_1", bytes: 40),
        ])

        XCTAssertEqual(snapshot.runs.map(\.id), ["run_2", "run_1"])
        XCTAssertEqual(snapshot.runs[1].tasks.map(\.id), ["task_2", "task_1"])
        XCTAssertEqual(snapshot.runs[1].tasks[1].archives.map(\.dispatchID), ["ctx_a", "ctx_a2"])
        XCTAssertEqual(snapshot.archiveCount, 4)
        XCTAssertEqual(snapshot.byteSize, 100)
        XCTAssertEqual(snapshot.runs[1].byteSize, 90)
        XCTAssertEqual(snapshot.runs[1].tasks[1].byteSize, 70)
    }

    func testTaskLabelPrefersDisplayNameThenTitleThenSpec() {
        let snapshot = VaultProjection.snapshot(records: [
            record(dispatch: "ctx_a", task: "task_1", taskTitle: "Vault", taskDisplayName: "T49"),
            record(dispatch: "ctx_b", task: "task_2", taskTitle: "Automations", taskDisplayName: nil),
            record(dispatch: "ctx_c", task: "task_3", taskTitle: nil, taskDisplayName: nil,
                   spec: "unnamed work"),
        ])
        let tasks = snapshot.runs[0].tasks
        XCTAssertEqual(tasks[0].label, "T49")
        XCTAssertEqual(tasks[0].title, "Vault")
        XCTAssertEqual(tasks[1].label, "Automations")
        XCTAssertEqual(tasks[2].label, "unnamed work")
    }

    func testOrphanedArchivesGroupUnderTheirOwnRun() {
        let snapshot = VaultProjection.snapshot(records: [
            record(dispatch: "ctx_orphan", run: nil, runObjective: nil, task: nil,
                   taskTitle: nil, taskDisplayName: nil, status: nil),
        ])
        XCTAssertEqual(snapshot.runs.map(\.id), [VaultProjection.orphanRunID])
        XCTAssertEqual(snapshot.runs[0].objective, VaultProjection.orphanRunObjective)
        XCTAssertEqual(snapshot.runs[0].tasks[0].id, VaultProjection.orphanTaskID)
        XCTAssertEqual(snapshot.runs[0].tasks[0].archives[0].dispatchStatus, "unknown")
    }

    func testLiveRunsAreMarked() {
        let snapshot = VaultProjection.snapshot(
            records: [record(dispatch: "ctx_a"), record(dispatch: "ctx_b", run: "run_2")],
            liveRunIDs: ["run_2"])
        XCTAssertEqual(snapshot.runs.first { $0.id == "run_1" }?.isLive, false)
        XCTAssertEqual(snapshot.runs.first { $0.id == "run_2" }?.isLive, true)
    }

    func testScanTruncationSurfacesOnTheSnapshot() {
        XCTAssertFalse(VaultProjection.snapshot(records: [record(dispatch: "ctx_a")]).scanTruncated)
        let truncated = VaultProjection.snapshot(
            records: [record(dispatch: "ctx_a"), record(dispatch: "ctx_b", scanTruncated: true)],
            scanLimit: 4096)
        XCTAssertTrue(truncated.scanTruncated)
        XCTAssertEqual(truncated.scanLimit, 4096)
    }

    func testArchiveLookupAcrossRuns() {
        let snapshot = VaultProjection.snapshot(records: [
            record(dispatch: "ctx_a"), record(dispatch: "ctx_b", run: "run_2"),
        ])
        XCTAssertEqual(snapshot.archive(dispatchID: "ctx_b")?.dispatchID, "ctx_b")
        XCTAssertNil(snapshot.archive(dispatchID: "ctx_missing"))
    }

    // MARK: - Filtering

    func testFilterMatchesMetadataCaseInsensitively() {
        let row = VaultProjection.row(record(dispatch: "ctx_abc", handle: "term_worker_7"))
        XCTAssertTrue(VaultProjection.matches(row, query: "CTX_ABC"))
        XCTAssertTrue(VaultProjection.matches(row, query: "term_worker_7"))
        XCTAssertTrue(VaultProjection.matches(row, query: "claude-code"))
        XCTAssertTrue(VaultProjection.matches(row, query: "wave 12"))
        XCTAssertTrue(VaultProjection.matches(row, query: ""))
        XCTAssertFalse(VaultProjection.matches(row, query: "codex"))
    }

    func testFilterMatchesScannedContent() {
        let row = VaultProjection.row(
            record(dispatch: "ctx_a", scan: #"{"lines":["error: cannot find Foo in scope"]}"#))
        XCTAssertTrue(VaultProjection.matches(row, query: "cannot find Foo"))
        XCTAssertFalse(VaultProjection.matches(row, query: "segmentation fault"))
    }

    func testFilterRequiresEveryTerm() {
        let row = VaultProjection.row(record(dispatch: "ctx_a", scan: "build failed"))
        XCTAssertTrue(VaultProjection.matches(row, query: "build failed"))
        XCTAssertTrue(VaultProjection.matches(row, query: "failed T49"))
        XCTAssertFalse(VaultProjection.matches(row, query: "failed T99"))
    }

    func testFilteredSnapshotDropsEmptyRunsAndTasks() {
        let snapshot = VaultProjection.snapshot(records: [
            record(dispatch: "ctx_a", task: "task_1", taskDisplayName: "T49"),
            record(dispatch: "ctx_b", task: "task_2", taskDisplayName: "T48"),
            record(dispatch: "ctx_c", run: "run_2", runObjective: "Wave 13", task: "task_9",
                   taskDisplayName: "T50"),
        ])

        let filtered = VaultProjection.filtered(snapshot, query: "T48")
        XCTAssertEqual(filtered.runs.count, 1)
        XCTAssertEqual(filtered.runs[0].tasks.map(\.id), ["task_2"])
        XCTAssertEqual(filtered.archiveCount, 1)

        XCTAssertTrue(VaultProjection.filtered(snapshot, query: "nothing here").isEmpty)
        XCTAssertEqual(VaultProjection.filtered(snapshot, query: "   ").archiveCount, 3)
    }

    func testFilterOnRunObjectiveKeepsEveryArchiveInThatRun() {
        let snapshot = VaultProjection.snapshot(records: [
            record(dispatch: "ctx_a", task: "task_1"),
            record(dispatch: "ctx_b", task: "task_2", taskDisplayName: "T48"),
            record(dispatch: "ctx_c", run: "run_2", runObjective: "Wave 13", task: "task_9"),
        ])
        let filtered = VaultProjection.filtered(snapshot, query: "Wave 12")
        XCTAssertEqual(filtered.runs.map(\.id), ["run_1"])
        XCTAssertEqual(filtered.archiveCount, 2)
    }

    // MARK: - Transcript pins

    func testTranscriptPinParsesMessageStream() {
        let jsonl = """
        {"type":"user","timestamp":"2026-08-01T10:00:00Z","message":{"role":"user","content":"start the vault"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."},{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Build complete!"}]}}
        """
        let messages = try? XCTUnwrap(VaultProjection.transcriptMessages(jsonl))
        XCTAssertEqual(messages?.count, 3)
        XCTAssertEqual(messages?[0].role, "user")
        XCTAssertEqual(messages?[0].timestamp, "2026-08-01T10:00:00Z")
        XCTAssertEqual(messages?[0].text, "start the vault")
        XCTAssertEqual(messages?[1].role, "assistant")
        XCTAssertEqual(messages?[1].text, "On it.\n[tool_use Bash] {\"command\":\"swift build\"}")
        XCTAssertEqual(messages?[2].text, "[tool_result] Build complete!")
        XCTAssertEqual(messages?.map(\.id), [0, 1, 2])
    }

    func testTranscriptPinRendersThinkingBlocks() {
        let jsonl = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"weigh it"}]}}"#
        XCTAssertEqual(VaultProjection.transcriptMessages(jsonl)?.first?.text, "[thinking] weigh it")
    }

    func testPlainTextPinIsNotAMessageStream() {
        XCTAssertNil(VaultProjection.transcriptMessages("just some terminal text\nsecond line"))
        XCTAssertNil(VaultProjection.transcriptMessages(""))
        XCTAssertNil(VaultProjection.transcriptMessages("   \n  "))
    }

    func testMostlyUnparseablePinFallsBackToPlainText() {
        let mixed = """
        {"type":"user","message":{"role":"user","content":"one real line"}}
        not json at all
        neither is this
        nor this
        """
        XCTAssertNil(VaultProjection.transcriptMessages(mixed))
    }

    func testEntriesWithNoRenderableContentAreSkipped() {
        let jsonl = """
        {"type":"system","subtype":"init"}
        {"type":"user","message":{"role":"user","content":"hello"}}
        """
        let messages = VaultProjection.transcriptMessages(jsonl)
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?[0].text, "hello")
    }

    // MARK: - Labels

    func testByteLabels() {
        XCTAssertEqual(VaultProjection.byteLabel(0), "0 B")
        XCTAssertEqual(VaultProjection.byteLabel(512), "512 B")
        XCTAssertEqual(VaultProjection.byteLabel(2048), "2 KB")
        XCTAssertEqual(VaultProjection.byteLabel(5 * 1024 * 1024), "5.0 MB")
        XCTAssertEqual(VaultProjection.byteLabel(3 * 1024 * 1024 * 1024), "3.0 GB")
    }

    func testKindLabels() {
        XCTAssertEqual(VaultProjection.kindLabel("transcript_pin"), "transcript pin")
        XCTAssertEqual(VaultProjection.kindLabel("terminal_tail"), "terminal tail")
        XCTAssertEqual(VaultProjection.kindLabel("something_else"), "something_else")
    }

    func testProducerLabelFallsBackFromEngineToHandleToState() {
        XCTAssertEqual(VaultProjection.row(record(dispatch: "ctx_a")).producerLabel, "claude-code")
        XCTAssertEqual(
            VaultProjection.row(record(dispatch: "ctx_a", engine: nil)).producerLabel, "term_worker")
        XCTAssertEqual(
            VaultProjection.row(record(dispatch: "ctx_a", handle: nil, engine: nil)).producerLabel,
            "succeeded")
    }
}
