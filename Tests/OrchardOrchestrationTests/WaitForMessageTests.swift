import XCTest
@testable import OrchardOrchestration

/// The `check --wait` long-poll primitive: resolved on message arrival, filtered by
/// type/recipient, timing out as a checkpoint (not a failure).
final class WaitForMessageTests: StoreTestCase {
    func testWaiterResolvesOnMatchingArrival() async throws {
        let center = MessageWaitCenter()
        let waiting = Task {
            await center.waitForMessage(
                recipient: "run:r1", types: [.workerDone, .escalation], timeout: 5)
        }
        // Give the waiter time to register before notifying.
        try await Task.sleep(nanoseconds: 50_000_000)
        center.notifyMessageArrived(recipient: "run:r1", type: .workerDone)

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .arrived(recipient: "run:r1", type: .workerDone))
        XCTAssertEqual(center.waiterCount, 0)
    }

    func testNonMatchingTypeDoesNotWake() async throws {
        let center = MessageWaitCenter()
        let waiting = Task {
            await center.waitForMessage(recipient: "run:r1", types: [.workerDone], timeout: 0.4)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        // A status message must not wake a worker_done-focused waiter…
        center.notifyMessageArrived(recipient: "run:r1", type: .status)
        // …nor a matching type for a different recipient.
        center.notifyMessageArrived(recipient: "run:other", type: .workerDone)

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .timedOut)
    }

    func testTimeoutResolvesTimedOut() async {
        let center = MessageWaitCenter()
        let outcome = await center.waitForMessage(recipient: "run:r1", timeout: 0.1)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(center.waiterCount, 0)
    }

    func testNilFiltersMatchAnything() async throws {
        let center = MessageWaitCenter()
        let waiting = Task {
            await center.waitForMessage(timeout: 5)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        center.notifyMessageArrived(recipient: "term_x", type: .handoff)
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .arrived(recipient: "term_x", type: .handoff))
    }

    func testMultipleMatchingWaitersAllWake() async throws {
        let center = MessageWaitCenter()
        let first = Task { await center.waitForMessage(recipient: "run:r1", timeout: 5) }
        let second = Task { await center.waitForMessage(recipient: "run:r1", timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        center.notifyMessageArrived(recipient: "run:r1", type: .status)

        let outcomes = await [first.value, second.value]
        XCTAssertEqual(outcomes, [
            .arrived(recipient: "run:r1", type: .status),
            .arrived(recipient: "run:r1", type: .status),
        ])
    }

    func testStoreSendWiresIntoWaitCenter() async throws {
        let fixture = try makeDispatchedTask()
        let center = MessageWaitCenter()
        store.onMessageArrived = { recipient, type in
            center.notifyMessageArrived(recipient: recipient, type: type)
        }

        let runAddress = "run:\(fixture.run.id)"
        let waiting = Task {
            await center.waitForMessage(recipient: runAddress, types: [.workerDone], timeout: 5)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try sendWorkerDone(fixture)

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .arrived(recipient: runAddress, type: .workerDone))

        // The woken caller re-reads the store and finds the batch that woke it.
        let batch = try XCTUnwrap(try store.getOrCreateRunDelivery(
            runID: fixture.run.id, consumerGeneration: 1, wakeTypes: [.workerDone]))
        XCTAssertEqual(batch.messages.last?.type, .workerDone)
    }
}
