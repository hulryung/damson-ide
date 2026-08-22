import XCTest
@testable import OrchardOrchestration

/// FIFO delivery batching: oldest unread batch, cap 50, verbatim replay until ack,
/// exactly one outstanding delivery per Run.
final class DeliveryBatchingTests: StoreTestCase {
    private func makeRun() throws -> OrchestrationRun {
        try store.createRun(
            objective: "batching", coordinatorHandle: "term_coord", coordinatorPaneKey: "pane_coord")
    }

    func testEmptyMailboxYieldsNoDelivery() throws {
        let run = try makeRun()
        XCTAssertNil(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        XCTAssertFalse(try store.hasOutstandingRunDelivery(run.id))
    }

    func testBatchIsOldestFirstAndCappedAt50() throws {
        let run = try makeRun()
        try sendStatusMessages(55, runID: run.id)

        let batch = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        XCTAssertFalse(batch.replayed)
        XCTAssertEqual(batch.messages.count, 50)
        XCTAssertEqual(batch.messages.first?.subject, "status 0")
        XCTAssertEqual(batch.messages.last?.subject, "status 49")
        // FIFO by monotonic sequence.
        XCTAssertEqual(batch.messages.map(\.sequence), batch.messages.map(\.sequence).sorted())
    }

    func testExplicitLimitCannotExceedCap() throws {
        let run = try makeRun()
        try sendStatusMessages(55, runID: run.id)
        let batch = try XCTUnwrap(
            try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1, limit: 500))
        XCTAssertEqual(batch.messages.count, 50)
    }

    func testUnackedDeliveryReplaysVerbatim() throws {
        let run = try makeRun()
        try sendStatusMessages(3, runID: run.id)

        let first = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        // New mail lands between checks…
        try sendStatusMessages(2, runID: run.id, from: "term_late")

        let replay = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        // …but the unacked batch replays with exactly the original message IDs.
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.delivery.id, first.delivery.id)
        XCTAssertEqual(replay.messages.map(\.id), first.messages.map(\.id))
    }

    func testOnlyOneOutstandingDeliveryPerRun() throws {
        let run = try makeRun()
        try sendStatusMessages(2, runID: run.id)
        _ = try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1)

        // The unique partial index refuses a second outstanding row outright.
        XCTAssertThrowsError(
            try store.db.run(
                "INSERT INTO deliveries (id, run_id, consumer_generation, message_ids) VALUES ('d2', ?, 1, '[]')",
                [.text(run.id)]
            )
        )
    }

    func testAckMarksMessagesReadAndAdvancesToNextBatch() throws {
        let run = try makeRun()
        try sendStatusMessages(3, runID: run.id)

        let first = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        try sendStatusMessages(1, runID: run.id, from: "term_late")

        let ack = try store.acknowledgeRunDelivery(
            runID: run.id, consumerGeneration: 1, deliveryID: first.delivery.id)
        XCTAssertFalse(ack.duplicate)
        XCTAssertEqual(ack.delivery.status, .acknowledged)
        for id in first.messages.map(\.id) {
            XCTAssertEqual(try store.message(id)?.read, true)
        }

        let second = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        XCTAssertFalse(second.replayed)
        XCTAssertNotEqual(second.delivery.id, first.delivery.id)
        XCTAssertEqual(second.messages.count, 1)
    }

    func testDuplicateAckIsIdempotent() throws {
        let run = try makeRun()
        try sendStatusMessages(1, runID: run.id)
        let batch = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        _ = try store.acknowledgeRunDelivery(
            runID: run.id, consumerGeneration: 1, deliveryID: batch.delivery.id)
        let again = try store.acknowledgeRunDelivery(
            runID: run.id, consumerGeneration: 1, deliveryID: batch.delivery.id)
        XCTAssertTrue(again.duplicate)
    }

    func testAckOfForeignDeliveryIsStale() throws {
        let runA = try makeRun()
        let runB = try store.createRun(
            objective: "other", coordinatorHandle: "term_other", coordinatorPaneKey: "pane_other")
        try sendStatusMessages(1, runID: runA.id)
        let batch = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: runA.id, consumerGeneration: 1))

        XCTAssertThrowsError(
            try store.acknowledgeRunDelivery(
                runID: runB.id, consumerGeneration: 1, deliveryID: batch.delivery.id)
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "stale_delivery")
        }
    }

    func testWakeTypesGateCreationButNotBatchContent() throws {
        let run = try makeRun()
        try sendStatusMessages(2, runID: run.id)

        // No unread message of a waking type → no delivery is created at all.
        XCTAssertNil(try store.getOrCreateRunDelivery(
            runID: run.id, consumerGeneration: 1, wakeTypes: [.workerDone, .escalation]))

        try store.sendMessage(OutboundMessage(
            from: "term_worker", runID: run.id, subject: "blocked",
            type: .escalation, payload: "{}"))

        // A waking type exists → the batch is created, and it is the FULL oldest batch,
        // status messages included (§1.5: --types filters what wakes, not what returns).
        let batch = try XCTUnwrap(try store.getOrCreateRunDelivery(
            runID: run.id, consumerGeneration: 1, wakeTypes: [.workerDone, .escalation]))
        XCTAssertEqual(batch.messages.count, 3)
        XCTAssertEqual(batch.messages.first?.type, .status)
        XCTAssertEqual(batch.messages.last?.type, .escalation)
    }

    func testDeliveryMessagesPreserveRecordedOrder() throws {
        let run = try makeRun()
        try sendStatusMessages(5, runID: run.id)
        let batch = try XCTUnwrap(try store.getOrCreateRunDelivery(runID: run.id, consumerGeneration: 1))
        let rematerialized = try store.deliveryMessages(batch.delivery)
        XCTAssertEqual(rematerialized.map(\.id), batch.delivery.messageIDs)
    }
}
