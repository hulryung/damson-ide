import XCTest
@testable import OrchardOrchestration

/// Schema/store smoke tests: WAL journaling, verbatim enum strings, version stamping,
/// reopen-in-place.
final class OrchardOrchestrationTests: StoreTestCase {
    func testSchemaVersionIsStamped() throws {
        XCTAssertEqual(OrchardOrchestration.schemaVersion, 1)
        let version = try XCTUnwrap(store.db.queryOne("PRAGMA user_version")).int("user_version")
        XCTAssertEqual(try version, OrchardOrchestration.schemaVersion)
    }

    func testJournalModeIsWAL() throws {
        let mode = try XCTUnwrap(store.db.queryOne("PRAGMA journal_mode")).text("journal_mode")
        XCTAssertEqual(try mode.lowercased(), "wal")
    }

    func testEnumStringsAreVerbatim() {
        // docs/research/orca-inventory.md §1.3 — copied verbatim; a drift here corrupts
        // the CHECK constraints and the wire protocol at once.
        XCTAssertEqual(MessageType.allCases.map(\.rawValue), [
            "status", "dispatch", "worker_done", "merge_ready", "escalation",
            "handoff", "decision_gate", "question", "heartbeat",
        ])
        XCTAssertEqual(MessagePriority.allCases.map(\.rawValue), ["normal", "high", "urgent"])
        XCTAssertEqual(TaskStatus.allCases.map(\.rawValue), [
            "pending", "ready", "dispatched", "completed", "failed", "blocked",
        ])
        XCTAssertEqual(DispatchStatus.allCases.map(\.rawValue), [
            "pending", "dispatched", "completed", "failed", "circuit_broken",
        ])
        XCTAssertEqual(GateStatus.allCases.map(\.rawValue), ["pending", "resolved", "timeout"])
        XCTAssertEqual(QuestionStatus.allCases.map(\.rawValue), ["pending", "answered", "closed"])
        XCTAssertEqual(DeliveryStatus.allCases.map(\.rawValue), [
            "outstanding", "acknowledged", "fenced",
        ])
        XCTAssertEqual(WorkerDispatchState.allCases.map(\.rawValue), [
            "starting", "ready", "start_unknown", "failed", "succeeded",
            "stopping", "stop_unknown", "stopped", "abandoned",
        ])
        XCTAssertEqual(WorkerTerminalOwnershipState.allCases.map(\.rawValue), [
            "owned", "transferred", "user_owned", "external", "released",
        ])
        XCTAssertEqual(WorkerTerminalReleaseState.allCases.map(\.rawValue), [
            "not_requested", "retained", "requested", "releasing", "released", "unknown",
        ])
        XCTAssertEqual(WorkerReportOutcome.allCases.map(\.rawValue), ["succeeded", "failed"])
    }

    func testEnumCheckConstraintsRejectDrift() throws {
        let fixture = try makeDispatchedTask()
        XCTAssertThrowsError(
            try store.db.run(
                "INSERT INTO messages (id, run_id, from_handle, to_handle, subject, type) VALUES ('m1', ?, 'a', 'b', 's', 'not_a_type')",
                [.text(fixture.run.id)]
            )
        )
        XCTAssertThrowsError(
            try store.db.run(
                "UPDATE tasks SET status = 'not_a_status' WHERE id = ?", [.text(fixture.task.id)])
        )
    }

    func testStoreReopensExistingDatabase() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-orchestration-reopen-\(UUID().uuidString).db").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        var runID = ""
        do {
            let first = try OrchestrationStore(path: path)
            runID = try first.createRun(
                objective: "persisted", coordinatorHandle: "term_c", coordinatorPaneKey: "pane_c").id
            first.close()
        }
        let reopened = try OrchestrationStore(path: path)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.run(runID)?.objective, "persisted")
    }

    func testFutureSchemaVersionRefusesToOpen() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-orchestration-skew-\(UUID().uuidString).db").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        do {
            let first = try OrchestrationStore(path: path)
            try first.db.exec("PRAGMA user_version = 99")
            first.close()
        }
        XCTAssertThrowsError(try OrchestrationStore(path: path)) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "schema_version_skew")
        }
    }
}
