import XCTest
@testable import OrchardOrchestration

/// Consumer-generation fencing: rebinding a Run bumps the generation, fences the
/// outstanding delivery, and turns every stale consumer's check/ack into
/// `consumer_fenced` instead of silently consuming the new coordinator's mail.
final class ConsumerFencingTests: StoreTestCase {
    func testWrongGenerationIsFencedOnCheck() throws {
        let run = try store.createRun(
            objective: "fence", coordinatorHandle: "term_a", coordinatorPaneKey: "pane_a")
        try sendStatusMessages(1, runID: run.id)

        XCTAssertThrowsError(
            try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 99)
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "consumer_fenced")
        }
    }

    func testRebindBumpsGenerationAndFencesOutstandingDelivery() throws {
        let run = try store.createRun(
            objective: "fence", coordinatorHandle: "term_a", coordinatorPaneKey: "pane_a")
        try sendStatusMessages(2, runID: run.id)
        let batch = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))

        let rebound = try store.bindRun(
            runID: run.id, coordinatorHandle: "term_b", coordinatorPaneKey: "pane_b")
        XCTAssertEqual(rebound.consumerGeneration, 2)

        // The outstanding delivery is fenced, not deleted.
        XCTAssertEqual(try store.delivery(batch.delivery.id)?.status, .fenced)
        XCTAssertFalse(try store.hasOutstandingRunDelivery(run.id))

        // The old consumer is fenced on both check and ack.
        XCTAssertThrowsError(
            try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1)
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "consumer_fenced")
        }
        XCTAssertThrowsError(
            try store.acknowledgeRunDelivery(
                runID: run.id, consumerGeneration: 1, deliveryID: batch.delivery.id)
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "consumer_fenced")
        }
    }

    func testNewConsumerRebatchesTheUnreadMessages() throws {
        let run = try store.createRun(
            objective: "fence", coordinatorHandle: "term_a", coordinatorPaneKey: "pane_a")
        try sendStatusMessages(2, runID: run.id)
        let old = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        try store.bindRun(runID: run.id, coordinatorHandle: "term_b", coordinatorPaneKey: "pane_b")

        // Fencing left the messages unread, so the new generation gets them again in a
        // fresh delivery.
        let fresh = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 2))
        XCTAssertFalse(fresh.replayed)
        XCTAssertNotEqual(fresh.delivery.id, old.delivery.id)
        XCTAssertEqual(fresh.messages.map(\.id), old.messages.map(\.id))
    }

    func testAckingAFencedDeliveryFromTheNewGenerationIsFenced() throws {
        let run = try store.createRun(
            objective: "fence", coordinatorHandle: "term_a", coordinatorPaneKey: "pane_a")
        try sendStatusMessages(1, runID: run.id)
        let old = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        try store.bindRun(runID: run.id, coordinatorHandle: "term_b", coordinatorPaneKey: "pane_b")

        // Even the *current* consumer cannot ack a fenced delivery — its batch is dead.
        XCTAssertThrowsError(
            try store.acknowledgeRunDelivery(
                runID: run.id, consumerGeneration: 2, deliveryID: old.delivery.id)
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "consumer_fenced")
        }
    }

    func testIdempotentRebindToSameCoordinatorDoesNotFence() throws {
        let run = try store.createRun(
            objective: "fence", coordinatorHandle: "term_a", coordinatorPaneKey: "pane_a")
        try sendStatusMessages(1, runID: run.id)
        let batch = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))

        // `run-use` re-issued by the same coordinator must not fence its own batch.
        let rebound = try store.bindRun(
            runID: run.id, coordinatorHandle: "term_a", coordinatorPaneKey: "pane_a")
        XCTAssertEqual(rebound.consumerGeneration, 1)
        XCTAssertEqual(try store.delivery(batch.delivery.id)?.status, .outstanding)
    }

    func testCreatingRunOnAPaneUnbindsItsOtherRuns() throws {
        let first = try store.createRun(
            objective: "one", coordinatorHandle: "term_a", coordinatorPaneKey: "pane_shared")
        _ = try store.createRun(
            objective: "two", coordinatorHandle: "term_a", coordinatorPaneKey: "pane_shared")
        XCTAssertNil(try store.run(first.id)?.coordinatorPaneKey)
    }
}
