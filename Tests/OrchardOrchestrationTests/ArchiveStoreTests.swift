import XCTest
@testable import OrchardOrchestration

/// T49 store seam: the cross-run archive inventory the Vault lists, and the additive
/// deletion API a prune executes through. The deletion tests are the load-bearing
/// ones — a prune must never be able to reach anything but `worker_terminal_archives`.
final class ArchiveStoreTests: StoreTestCase {

    // MARK: - Fixtures

    @discardableResult
    private func archive(
        _ fixture: Fixture,
        kind: WorkerTerminalArchiveKind = .terminalTail,
        content: String = #"{"lines":["hello"],"rawLines":["hello"]}"#
    ) throws -> WorkerTerminalArchive {
        let resource = try store.createWorkerTerminalResource(
            originDispatchID: fixture.dispatch.id,
            ownerDispatchID: fixture.dispatch.id,
            terminalHandle: "term_worker")
        return try store.archiveWorkerTerminalOutput(
            dispatchID: fixture.dispatch.id, resourceID: resource.id,
            kind: kind, content: content)
    }

    /// A settled dispatch: the shape retention is allowed to consider.
    private func settledFixture(spec: String = "settled work") throws -> Fixture {
        let fixture = try makeDispatchedTask(spec: spec)
        try store.completeDispatch(fixture.dispatch.id)
        return fixture
    }

    // MARK: - Inventory

    func testInventoryJoinsRunTaskAndDispatch() throws {
        let fixture = try settledFixture(spec: "build the vault")
        try archive(fixture)

        let records = try store.listWorkerArchives()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.dispatchID, fixture.dispatch.id)
        XCTAssertEqual(record.runID, fixture.run.id)
        XCTAssertEqual(record.taskID, fixture.task.id)
        XCTAssertEqual(record.taskSpec, "build the vault")
        XCTAssertEqual(record.runObjective, "test objective")
        XCTAssertEqual(record.kind, .terminalTail)
        XCTAssertEqual(record.dispatchStatus, .completed)
        XCTAssertEqual(record.agentHandle, "term_worker")
        // No worker_dispatches row: a context-only dispatch is unsupervised.
        XCTAssertEqual(record.workerState, "unsupervised")
        XCTAssertNil(record.engineID)
        XCTAssertEqual(record.byteSize, #"{"lines":["hello"],"rawLines":["hello"]}"#.utf8.count)
    }

    func testInventoryReportsEngineFromStartOptions() throws {
        let fixture = try makeDispatchedTask()
        try store.createWorkerDispatch(
            dispatchID: fixture.dispatch.id,
            startOptions: #"{"agent":"claude-code","launch":{"agent":"claude-code"}}"#)
        try archive(fixture)

        let record = try XCTUnwrap(try store.listWorkerArchives().first)
        XCTAssertEqual(record.engineID, "claude-code")
        XCTAssertEqual(record.workerState, "starting")
    }

    func testEngineFallsBackToLaunchAgent() {
        XCTAssertEqual(
            OrchestrationStore.engineID(startOptions: #"{"launch":{"agent":"codex"}}"#), "codex")
        XCTAssertNil(OrchestrationStore.engineID(startOptions: #"{"agent":""}"#))
        XCTAssertNil(OrchestrationStore.engineID(startOptions: "{}"))
        XCTAssertNil(OrchestrationStore.engineID(startOptions: nil))
        XCTAssertNil(OrchestrationStore.engineID(startOptions: "not json"))
    }

    func testContentScanIsBoundedAndFlagsTruncation() throws {
        let fixture = try settledFixture()
        let long = String(repeating: "x", count: 500)
        try archive(fixture, content: long)

        let bounded = try XCTUnwrap(try store.listWorkerArchives(contentScanLimit: 100).first)
        XCTAssertEqual(bounded.contentScan.count, 100)
        XCTAssertTrue(bounded.contentScanTruncated)
        XCTAssertEqual(bounded.byteSize, 500, "size is the stored size, not the scanned size")

        let whole = try XCTUnwrap(try store.listWorkerArchives(contentScanLimit: 4096).first)
        XCTAssertEqual(whole.contentScan.count, 500)
        XCTAssertFalse(whole.contentScanTruncated)

        let metadataOnly = try XCTUnwrap(try store.listWorkerArchives(contentScanLimit: 0).first)
        XCTAssertEqual(metadataOnly.contentScan, "")
        XCTAssertTrue(metadataOnly.contentScanTruncated)
    }

    func testInventoryListsArchivesAcrossRunsNewestFirst() throws {
        let older = try settledFixture(spec: "older run")
        try archive(older)
        // Same second resolution in SQLite, so pin the order explicitly.
        try store.db.run(
            "UPDATE worker_terminal_archives SET created_at = '2026-01-01 00:00:00' WHERE dispatch_id = ?",
            [.text(older.dispatch.id)])
        let newer = try settledFixture(spec: "newer run")
        try archive(newer)
        try store.db.run(
            "UPDATE worker_terminal_archives SET created_at = '2026-06-01 00:00:00' WHERE dispatch_id = ?",
            [.text(newer.dispatch.id)])

        let records = try store.listWorkerArchives()
        XCTAssertEqual(records.map(\.dispatchID), [newer.dispatch.id, older.dispatch.id])
        XCTAssertNotEqual(records[0].runID, records[1].runID, "archives span runs")
    }

    func testOrphanedArchiveStillLists() throws {
        let fixture = try settledFixture()
        try archive(fixture)
        // A partially reset database can leave an archive whose dispatch row is gone.
        try store.db.run("DELETE FROM dispatch_contexts WHERE id = ?", [.text(fixture.dispatch.id)])

        let record = try XCTUnwrap(try store.listWorkerArchives().first)
        XCTAssertNil(record.runID)
        XCTAssertNil(record.taskID)
        XCTAssertNil(record.dispatchStatus)
        XCTAssertEqual(record.dispatchID, fixture.dispatch.id)
    }

    func testTotalArchiveBytes() throws {
        XCTAssertEqual(try store.totalWorkerArchiveBytes(), 0)
        let first = try settledFixture(spec: "one")
        try archive(first, content: String(repeating: "a", count: 40))
        let second = try settledFixture(spec: "two")
        try archive(second, content: String(repeating: "b", count: 60))
        XCTAssertEqual(try store.totalWorkerArchiveBytes(), 100)
    }

    // MARK: - Live runs

    func testLiveRunIDsCoversDispatchedWorkAndSettles() throws {
        let fixture = try makeDispatchedTask()
        XCTAssertTrue(try store.liveRunIDs().contains(fixture.run.id))
        try store.completeDispatch(fixture.dispatch.id)
        XCTAssertFalse(try store.liveRunIDs().contains(fixture.run.id))
    }

    func testLiveRunIDsCoversUnsettledWorker() throws {
        let fixture = try settledFixture()
        try store.createWorkerDispatch(dispatchID: fixture.dispatch.id)
        XCTAssertTrue(try store.liveRunIDs().contains(fixture.run.id),
                      "a starting worker keeps its run live even with the context settled")
        _ = try store.updateWorkerDispatch(fixture.dispatch.id, state: .succeeded)
        XCTAssertFalse(try store.liveRunIDs().contains(fixture.run.id))
    }

    func testLiveRunIDsCoversPendingGate() throws {
        let fixture = try settledFixture()
        _ = try store.createGate(taskID: fixture.task.id, question: "ship it?", options: ["yes", "no"])
        XCTAssertTrue(try store.liveRunIDs().contains(fixture.run.id))
    }

    // MARK: - Deletion

    func testDeleteReportsCountAndFreedBytes() throws {
        let first = try settledFixture(spec: "one")
        try archive(first, content: String(repeating: "a", count: 30))
        let second = try settledFixture(spec: "two")
        try archive(second, content: String(repeating: "b", count: 70))

        let receipt = try store.deleteWorkerTerminalArchives(
            dispatchIDs: [first.dispatch.id, second.dispatch.id])
        XCTAssertEqual(receipt.deletedCount, 2)
        XCTAssertEqual(receipt.freedBytes, 100)
        XCTAssertEqual(Set(receipt.dispatchIDs), [first.dispatch.id, second.dispatch.id])
        XCTAssertTrue(try store.listWorkerArchives().isEmpty)
    }

    func testDeleteIsIdempotentAndIgnoresUnknownIDs() throws {
        let fixture = try settledFixture()
        try archive(fixture)

        let first = try store.deleteWorkerTerminalArchives(
            dispatchIDs: [fixture.dispatch.id, "ctx_missing", fixture.dispatch.id])
        XCTAssertEqual(first.deletedCount, 1)
        XCTAssertEqual(first.dispatchIDs, [fixture.dispatch.id])

        let second = try store.deleteWorkerTerminalArchives(dispatchIDs: [fixture.dispatch.id])
        XCTAssertEqual(second, .empty)
        XCTAssertEqual(second.deletedCount, 0)
        XCTAssertEqual(second.freedBytes, 0)

        XCTAssertEqual(try store.deleteWorkerTerminalArchives(dispatchIDs: []), .empty)
    }

    func testDeleteTouchesArchivesOnly() throws {
        let fixture = try makeDispatchedTask(spec: "keep everything else")
        try store.createWorkerDispatch(dispatchID: fixture.dispatch.id)
        let resource = try store.createWorkerTerminalResource(
            originDispatchID: fixture.dispatch.id,
            ownerDispatchID: fixture.dispatch.id,
            terminalHandle: "term_worker")
        _ = try store.archiveWorkerTerminalOutput(
            dispatchID: fixture.dispatch.id, resourceID: resource.id,
            kind: .terminalTail, content: #"{"lines":["out"]}"#)
        try sendStatusMessages(3, runID: fixture.run.id)
        _ = try sendWorkerDone(fixture)

        let messagesBefore = try store.db.query("SELECT COUNT(*) AS n FROM messages")[0].int("n")

        let receipt = try store.deleteWorkerTerminalArchives(dispatchIDs: [fixture.dispatch.id])
        XCTAssertEqual(receipt.deletedCount, 1)

        XCTAssertNil(try store.workerTerminalArchive(dispatchID: fixture.dispatch.id))
        XCTAssertEqual(
            try store.db.query("SELECT COUNT(*) AS n FROM messages")[0].int("n"), messagesBefore)
        XCTAssertNotNil(try store.task(fixture.task.id))
        XCTAssertNotNil(try store.dispatchContext(fixture.dispatch.id))
        XCTAssertNotNil(try store.workerDispatch(fixture.dispatch.id))
        XCTAssertNotNil(try store.workerTerminalResource(ownerDispatchID: fixture.dispatch.id))
        XCTAssertNotNil(try store.run(fixture.run.id))
    }

    func testDeleteChunksBeyondSQLiteVariableLimit() throws {
        // More ids than SQLITE_MAX_VARIABLE_NUMBER allows in one statement.
        var ids: [String] = []
        for index in 0..<3 {
            let fixture = try settledFixture(spec: "chunk \(index)")
            try archive(fixture, content: "x")
            ids.append(fixture.dispatch.id)
        }
        ids.append(contentsOf: (0..<1200).map { "ctx_absent_\($0)" })

        let receipt = try store.deleteWorkerTerminalArchives(dispatchIDs: ids)
        XCTAssertEqual(receipt.deletedCount, 3)
        XCTAssertEqual(receipt.freedBytes, 3)
        XCTAssertTrue(try store.listWorkerArchives().isEmpty)
    }
}
