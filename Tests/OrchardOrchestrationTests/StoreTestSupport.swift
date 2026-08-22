import XCTest
@testable import OrchardOrchestration

/// Base fixture: a fresh file-backed store per test (WAL needs a real file) plus the
/// canonical run/task/dispatch scaffolding most scenarios start from.
class StoreTestCase: XCTestCase {
    var store: OrchestrationStore!
    private var databasePath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-orchestration-test-\(UUID().uuidString).db").path
        store = try OrchestrationStore(path: databasePath)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if let databasePath {
            // WAL leaves -wal/-shm sidecars next to the DB.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databasePath + suffix)
            }
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    struct Fixture {
        let run: OrchestrationRun
        let task: OrchestrationTask
        let dispatch: DispatchContext
    }

    /// One run + one ready task claimed by `workerHandle` — the minimal live dispatch.
    @discardableResult
    func makeDispatchedTask(
        workerHandle: String = "term_worker",
        workerPaneKey: String? = "pane_worker",
        spec: String = "do the thing"
    ) throws -> Fixture {
        let run = try store.createRun(
            objective: "test objective",
            coordinatorHandle: "term_coord",
            coordinatorPaneKey: "pane_coord")
        let task = try store.createTask(runID: run.id, spec: spec)
        let dispatch = try store.createDispatchContext(
            taskID: task.id,
            assigneeHandle: workerHandle,
            assigneePaneKey: workerPaneKey)
        return Fixture(run: run, task: task, dispatch: dispatch)
    }

    /// A worker_done payload as the CLI would assemble it.
    func workerDonePayload(
        taskID: String, dispatchID: String, outcome: String = "succeeded",
        filesModified: [String] = [], reportPath: String? = nil
    ) -> String {
        var object: [String: Any] = [
            "taskId": taskID,
            "dispatchId": dispatchID,
            "outcome": outcome,
            "filesModified": filesModified,
        ]
        if let reportPath { object["reportPath"] = reportPath }
        return JSONCoding.encodeObject(object)
    }

    func heartbeatPayload(taskID: String, dispatchID: String, phase: String = "implementing") -> String {
        JSONCoding.encodeObject(["taskId": taskID, "dispatchId": dispatchID, "phase": phase])
    }

    /// Send a worker_done from the dispatched worker's own identity.
    @discardableResult
    func sendWorkerDone(
        _ fixture: Fixture,
        outcome: String = "succeeded",
        from: String = "term_worker",
        senderPaneKey: String? = "pane_worker",
        taskID: String? = nil,
        dispatchID: String? = nil
    ) throws -> SendReceipt {
        try store.sendMessage(OutboundMessage(
            from: from,
            senderPaneKey: senderPaneKey,
            runID: fixture.run.id,
            subject: "done",
            body: "Did the thing. Found nothing odd. Nothing left.",
            type: .workerDone,
            payload: workerDonePayload(
                taskID: taskID ?? fixture.task.id,
                dispatchID: dispatchID ?? fixture.dispatch.id,
                outcome: outcome)
        ))
    }

    @discardableResult
    func sendHeartbeat(
        _ fixture: Fixture,
        from: String = "term_worker",
        senderPaneKey: String? = "pane_worker",
        dispatchID: String? = nil
    ) throws -> SendReceipt {
        try store.sendMessage(OutboundMessage(
            from: from,
            senderPaneKey: senderPaneKey,
            runID: fixture.run.id,
            subject: "alive",
            type: .heartbeat,
            payload: heartbeatPayload(
                taskID: fixture.task.id,
                dispatchID: dispatchID ?? fixture.dispatch.id)
        ))
    }

    /// Send `count` plain status messages into the run mailbox.
    func sendStatusMessages(_ count: Int, runID: String, from: String = "term_worker") throws {
        for index in 0..<count {
            try store.sendMessage(OutboundMessage(
                from: from, runID: runID, subject: "status \(index)", type: .status))
        }
    }

    func assertRejected(
        _ settlement: WorkerReportSettlement,
        _ code: SettlementRejectionCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let actual, _) = settlement else {
            XCTFail("Expected rejection \(code), got \(settlement)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, code, file: file, line: line)
    }
}
