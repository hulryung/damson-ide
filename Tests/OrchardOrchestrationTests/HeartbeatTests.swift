import XCTest
@testable import OrchardOrchestration

/// Heartbeats refresh dispatch liveness; staleness (10 min) computes a warning flag
/// only and never mutates status.
final class HeartbeatTests: StoreTestCase {
    func testHeartbeatRecordsLastHeartbeatAt() throws {
        let fixture = try makeDispatchedTask()
        let receipt = try sendHeartbeat(fixture)
        XCTAssertEqual(receipt.lifecycle, .heartbeatRecorded(dispatchID: fixture.dispatch.id))
        XCTAssertNotNil(try store.dispatchContext(fixture.dispatch.id)?.lastHeartbeatAt)
    }

    func testHeartbeatForSettledDispatchIsSuppressed() throws {
        let fixture = try makeDispatchedTask()
        _ = try sendWorkerDone(fixture)

        let receipt = try sendHeartbeat(fixture)
        XCTAssertEqual(receipt.lifecycle, .suppressed)
        // Suppressed rows are consumed immediately: retained for audit, never delivered.
        XCTAssertEqual(receipt.messages.first?.read, true)
        let unread = try store.unreadMessages(to: "run:\(fixture.run.id)", types: [.heartbeat])
        XCTAssertTrue(unread.isEmpty)
    }

    func testSuppressedHeartbeatDoesNotWakeWaiters() throws {
        let fixture = try makeDispatchedTask()
        _ = try sendWorkerDone(fixture)
        var notified = 0
        store.onMessageArrived = { _, _ in notified += 1 }
        _ = try sendHeartbeat(fixture)
        XCTAssertEqual(notified, 0)
    }

    func testWrongPaneHeartbeatIsRejectedAndDoesNotRefreshLiveness() throws {
        let fixture = try makeDispatchedTask()
        let receipt = try sendHeartbeat(fixture, from: "term_imposter", senderPaneKey: "pane_imposter")
        guard case .rejected(let code, _)? = receipt.lifecycle else {
            return XCTFail("expected rejection, got \(String(describing: receipt.lifecycle))")
        }
        XCTAssertEqual(code, "sender_not_assignee")
        XCTAssertNil(try store.dispatchContext(fixture.dispatch.id)?.lastHeartbeatAt)
    }

    func testZombieHeartbeatCannotRefreshFinishedDispatchRow() throws {
        let fixture = try makeDispatchedTask()
        _ = try sendWorkerDone(fixture)
        // Direct store write path: the status guard alone must refuse it.
        try store.recordHeartbeat(dispatchID: fixture.dispatch.id, at: "2099-01-01 00:00:00")
        XCTAssertNil(try store.dispatchContext(fixture.dispatch.id)?.lastHeartbeatAt)
    }

    func testStalenessIsAWarningFlagOnly() throws {
        let fixture = try makeDispatchedTask()

        // Not stale when checked within the threshold of dispatch.
        XCTAssertTrue(try store.staleDispatches(now: Date()).isEmpty)

        // Stale when 10 minutes pass with no heartbeat…
        let later = Date().addingTimeInterval(11 * 60)
        let stale = try store.staleDispatches(now: later)
        XCTAssertEqual(stale.map(\.id), [fixture.dispatch.id])
        let dispatch = try XCTUnwrap(try store.dispatchContext(fixture.dispatch.id))
        XCTAssertTrue(try store.isHeartbeatStale(dispatch, now: later))

        // …and the flag changed NOTHING: status stays dispatched, task stays dispatched.
        XCTAssertEqual(try store.dispatchContext(fixture.dispatch.id)?.status, .dispatched)
        XCTAssertEqual(try store.task(fixture.task.id)?.status, .dispatched)
    }

    func testFreshHeartbeatClearsTheStalenessWindow() throws {
        let fixture = try makeDispatchedTask()
        let later = Date().addingTimeInterval(11 * 60)
        XCTAssertFalse(try store.staleDispatches(now: later).isEmpty)

        // A heartbeat stamped inside the window brings the dispatch back to fresh.
        try store.recordHeartbeat(
            dispatchID: fixture.dispatch.id,
            at: OrchestrationStore.sqliteTimestamp(later.addingTimeInterval(-60)))
        XCTAssertTrue(try store.staleDispatches(now: later).isEmpty)
    }

    func testSettledDispatchesAreNeverReportedStale() throws {
        let fixture = try makeDispatchedTask()
        _ = try sendWorkerDone(fixture)
        let later = Date().addingTimeInterval(60 * 60)
        XCTAssertTrue(try store.staleDispatches(now: later).isEmpty)
    }
}
