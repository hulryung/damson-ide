import XCTest
@testable import OrchardOrchestration
@testable import OrchardRuntime

/// The Vault's runtime seam end to end against a real store: the grouped snapshot,
/// the reader's reuse of the `worker-read` decode, and the dry-run → confirm prune
/// (including a preview that went stale between the two).
final class VaultStoreTests: XCTestCase {
    private var databasePath: String!
    private var store: OrchestrationStore!
    private var live: LiveOrchestrationStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-vault-test-\(UUID().uuidString).db").path
        store = try OrchestrationStore(path: databasePath)
        live = LiveOrchestrationStore(store: store)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        live = nil
        if let databasePath {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databasePath + suffix)
            }
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @discardableResult
    private func archivedDispatch(
        objective: String = "wave 12",
        spec: String = "build the vault",
        kind: WorkerTerminalArchiveKind = .terminalTail,
        content: String = #"{"lines":["clean"],"rawLines":["raw\u001b[0m"]}"#,
        settle: Bool = true,
        runID: String? = nil
    ) throws -> (run: String, task: String, dispatch: String) {
        let run = try runID ?? store.createRun(objective: objective, coordinatorHandle: "term_c", coordinatorPaneKey: "pane_c").id
        let task = try store.createTask(runID: run, spec: spec)
        let dispatch = try store.createDispatchContext(taskID: task.id, assigneeHandle: "term_w")
        let resource = try store.createWorkerTerminalResource(
            originDispatchID: dispatch.id, ownerDispatchID: dispatch.id, terminalHandle: "term_w")
        _ = try store.archiveWorkerTerminalOutput(
            dispatchID: dispatch.id, resourceID: resource.id, kind: kind, content: content)
        if settle { try store.completeDispatch(dispatch.id) }
        return (run, task.id, dispatch.id)
    }

    private func age(_ dispatchID: String, days: Int) throws {
        let stamp = OrchestrationStore.sqliteTimestamp(
            Date().addingTimeInterval(-Double(days) * 86_400))
        try store.db.run(
            "UPDATE worker_terminal_archives SET created_at = ? WHERE dispatch_id = ?",
            [.text(stamp), .text(dispatchID)])
    }

    // MARK: - Snapshot

    func testSnapshotGroupsAndMarksLiveRuns() async throws {
        let settled = try archivedDispatch(objective: "settled run")
        let liveOne = try archivedDispatch(objective: "live run", settle: false)

        let snapshot = try await live.vaultSnapshot()
        XCTAssertEqual(snapshot.archiveCount, 2)
        XCTAssertEqual(snapshot.runs.first { $0.id == settled.run }?.isLive, false)
        XCTAssertEqual(snapshot.runs.first { $0.id == liveOne.run }?.isLive, true)
        XCTAssertEqual(
            snapshot.runs.first { $0.id == settled.run }?.tasks.first?.archives.first?.dispatchID,
            settled.dispatch)
    }

    func testSnapshotContentIsFilterableAndBounded() async throws {
        _ = try archivedDispatch(content: #"{"lines":["needle in the tail"]}"#)

        let snapshot = try await live.vaultSnapshot()
        XCTAssertEqual(VaultProjection.filtered(snapshot, query: "needle").archiveCount, 1)
        XCTAssertTrue(VaultProjection.filtered(snapshot, query: "haystack").isEmpty)

        let clipped = try await live.vaultSnapshot(contentScanLimit: 4)
        XCTAssertTrue(VaultProjection.filtered(clipped, query: "needle").isEmpty)
        XCTAssertTrue(clipped.scanTruncated, "a clipped scan says so rather than implying absence")
    }

    // MARK: - Reader

    func testReaderServesTheSameCleanedAndRawTextWorkerReadDoes() async throws {
        let created = try archivedDispatch()
        let loaded = try await live.vaultArchive(dispatchID: created.dispatch)
        let archive = try XCTUnwrap(loaded)
        XCTAssertEqual(archive.lines(showRaw: false), ["clean"])
        XCTAssertEqual(archive.lines(showRaw: true), ["raw\u{1b}[0m"])
        XCTAssertFalse(archive.isTranscript)
    }

    func testReaderServesTranscriptPinsAsTheirDocument() async throws {
        let pinned = #"{"content":"{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}","path":"/tmp/x.jsonl"}"#
        let created = try archivedDispatch(kind: .transcriptPin, content: pinned)

        let loaded = try await live.vaultArchive(dispatchID: created.dispatch)
        let archive = try XCTUnwrap(loaded)
        XCTAssertTrue(archive.isTranscript)
        let messages = try XCTUnwrap(
            VaultProjection.transcriptMessages(try XCTUnwrap(archive.transcript)))
        XCTAssertEqual(messages.map(\.text), ["hi"])
    }

    func testReaderIsNilWhenNothingWasPinned() async throws {
        let run = try store.createRun(objective: "no archive", coordinatorHandle: "term_c", coordinatorPaneKey: "pane_c")
        let task = try store.createTask(runID: run.id, spec: "work")
        let dispatch = try store.createDispatchContext(taskID: task.id, assigneeHandle: "term_w")
        let archive = try await live.vaultArchive(dispatchID: dispatch.id)
        XCTAssertNil(archive)
    }

    // MARK: - Prune

    func testPreviewIsADryRunThatDeletesNothing() async throws {
        let old = try archivedDispatch(objective: "old run")
        try age(old.dispatch, days: 400)

        let plan = try await live.vaultPrunePreview(policy: .default)
        XCTAssertEqual(plan.dispatchIDs, [old.dispatch])
        XCTAssertFalse(plan.isEmpty)
        XCTAssertNotNil(try store.workerTerminalArchive(dispatchID: old.dispatch),
                        "a preview never deletes")
    }

    func testConfirmedPruneDeletesOnlyArchives() async throws {
        let old = try archivedDispatch(objective: "old run")
        try age(old.dispatch, days: 400)
        let fresh = try archivedDispatch(objective: "fresh run")

        let plan = try await live.vaultPrunePreview(policy: .default)
        let receipt = try await live.vaultPrune(policy: .default, confirming: plan.dispatchIDs)

        XCTAssertEqual(receipt.deletedCount, 1)
        XCTAssertEqual(receipt.deletedDispatchIDs, [old.dispatch])
        XCTAssertTrue(receipt.skippedDispatchIDs.isEmpty)
        XCTAssertNil(try store.workerTerminalArchive(dispatchID: old.dispatch))
        XCTAssertNotNil(try store.workerTerminalArchive(dispatchID: fresh.dispatch))
        // The run, task and dispatch the archive belonged to are untouched.
        XCTAssertNotNil(try store.run(old.run))
        XCTAssertNotNil(try store.task(old.task))
        XCTAssertNotNil(try store.dispatchContext(old.dispatch))
    }

    func testPruneNeverTouchesARunThatWentLiveAfterThePreview() async throws {
        let old = try archivedDispatch(objective: "old run")
        try age(old.dispatch, days: 400)

        let plan = try await live.vaultPrunePreview(policy: .default)
        XCTAssertEqual(plan.dispatchIDs, [old.dispatch])

        // The coordinator starts new work in that run between preview and confirm.
        let revived = try store.createTask(runID: old.run, spec: "more work")
        _ = try store.createDispatchContext(taskID: revived.id, assigneeHandle: "term_w2")

        let receipt = try await live.vaultPrune(policy: .default, confirming: plan.dispatchIDs)
        XCTAssertEqual(receipt.deletedCount, 0)
        XCTAssertEqual(receipt.skippedDispatchIDs, [old.dispatch])
        XCTAssertNotNil(try store.workerTerminalArchive(dispatchID: old.dispatch))
    }

    func testPruneRefusesIDsThePolicyDidNotSelect() async throws {
        let old = try archivedDispatch(objective: "old run")
        try age(old.dispatch, days: 400)
        let fresh = try archivedDispatch(objective: "fresh run")

        // A caller confirming an id outside the plan (a stale or hand-built list)
        // cannot use the prune path to delete it.
        let receipt = try await live.vaultPrune(
            policy: .default, confirming: [old.dispatch, fresh.dispatch])
        XCTAssertEqual(receipt.deletedDispatchIDs, [old.dispatch])
        XCTAssertEqual(receipt.skippedDispatchIDs, [fresh.dispatch])
        XCTAssertNotNil(try store.workerTerminalArchive(dispatchID: fresh.dispatch))
    }

    func testPruneWithRetentionOffDoesNothing() async throws {
        let old = try archivedDispatch(objective: "old run")
        try age(old.dispatch, days: 4000)

        let plan = try await live.vaultPrunePreview(policy: .keepForever)
        XCTAssertTrue(plan.isEmpty)
        let receipt = try await live.vaultPrune(policy: .keepForever, confirming: [old.dispatch])
        XCTAssertEqual(receipt.deletedCount, 0)
        XCTAssertNotNil(try store.workerTerminalArchive(dispatchID: old.dispatch))
    }

    func testEmptyConfirmationIsANoOp() async throws {
        _ = try archivedDispatch()
        let receipt = try await live.vaultPrune(policy: .default, confirming: [])
        XCTAssertEqual(receipt, .empty)
    }
}
