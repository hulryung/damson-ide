import XCTest
@testable import OrchardOrchestration

/// `--retry-request` idempotency: receipts keyed on (caller, requestID) + payload hash
/// make exact retries safe and mismatched reuse loud.
final class MutationReceiptTests: StoreTestCase {
    func testExactRetryReplaysReceiptWithoutRerunning() throws {
        let caller = try store.localMutationCallerFingerprint()
        var executions = 0
        let first = try store.performIdempotentMutation(
            callerFingerprint: caller, requestID: "req_1", method: "task-create",
            payload: #"{"spec":"x"}"#
        ) {
            executions += 1
            return #"{"taskId":"task_abc"}"#
        }
        XCTAssertFalse(first.replayed)

        let retry = try store.performIdempotentMutation(
            callerFingerprint: caller, requestID: "req_1", method: "task-create",
            payload: #"{"spec":"x"}"#
        ) {
            executions += 1
            return #"{"taskId":"task_DIFFERENT"}"#
        }
        XCTAssertTrue(retry.replayed)
        XCTAssertEqual(retry.receipt, first.receipt)
        XCTAssertEqual(executions, 1, "the mutation body must not re-run on retry")
    }

    func testRequestIDReuseWithDifferentPayloadIsMismatch() throws {
        let caller = try store.localMutationCallerFingerprint()
        _ = try store.performIdempotentMutation(
            callerFingerprint: caller, requestID: "req_1", method: "task-create",
            payload: #"{"spec":"x"}"#
        ) { "ok" }

        XCTAssertThrowsError(
            try store.performIdempotentMutation(
                callerFingerprint: caller, requestID: "req_1", method: "task-create",
                payload: #"{"spec":"DIFFERENT"}"#
            ) { "ok" }
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "request_mismatch")
        }
    }

    func testRequestIDReuseWithDifferentMethodIsMismatch() throws {
        let caller = try store.localMutationCallerFingerprint()
        _ = try store.performIdempotentMutation(
            callerFingerprint: caller, requestID: "req_1", method: "task-create", payload: "{}"
        ) { "ok" }
        XCTAssertThrowsError(
            try store.performIdempotentMutation(
                callerFingerprint: caller, requestID: "req_1", method: "gate-resolve", payload: "{}"
            ) { "ok" }
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "request_mismatch")
        }
    }

    func testFailedOperationDiscardsPendingReceiptSoRetryCanRun() throws {
        let caller = try store.localMutationCallerFingerprint()
        struct Boom: Error {}
        XCTAssertThrowsError(
            try store.performIdempotentMutation(
                callerFingerprint: caller, requestID: "req_1", method: "task-create", payload: "{}"
            ) { throw Boom() }
        )
        // The pending receipt was discarded, so the retry executes the operation.
        let retry = try store.performIdempotentMutation(
            callerFingerprint: caller, requestID: "req_1", method: "task-create", payload: "{}"
        ) { "recovered" }
        XCTAssertFalse(retry.replayed)
        XCTAssertEqual(retry.receipt, "recovered")
    }

    func testDistinctCallersDoNotShareReceipts() throws {
        _ = try store.performIdempotentMutation(
            callerFingerprint: "caller_a", requestID: "req_1", method: "m", payload: "{}"
        ) { "a" }
        let other = try store.performIdempotentMutation(
            callerFingerprint: "caller_b", requestID: "req_1", method: "m", payload: "{}"
        ) { "b" }
        XCTAssertFalse(other.replayed)
        XCTAssertEqual(other.receipt, "b")
    }

    func testLocalCallerFingerprintIsStable() throws {
        let first = try store.localMutationCallerFingerprint()
        let second = try store.localMutationCallerFingerprint()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
    }

    func testBeginReportsPendingForCrashedMutation() throws {
        let caller = try store.localMutationCallerFingerprint()
        let started = try store.beginMutationReceipt(
            callerFingerprint: caller, requestID: "req_1", method: "m", payloadHash: "h")
        guard case .started = started else { return XCTFail("expected started") }

        // Same request again without completion → pending, so the RPC layer can decide
        // how to recover instead of double-running.
        let again = try store.beginMutationReceipt(
            callerFingerprint: caller, requestID: "req_1", method: "m", payloadHash: "h")
        guard case .pending = again else { return XCTFail("expected pending, got \(again)") }
    }
}
