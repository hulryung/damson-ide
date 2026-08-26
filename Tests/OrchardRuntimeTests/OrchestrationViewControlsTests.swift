import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// UI-free T47 rules: enablement per dispatch/worker state, confirm copy,
/// audit formatting, and receipt/error → mutation result.
final class OrchestrationViewControlsTests: XCTestCase {

    // MARK: - Settled / enablement

    func testSettledUsesWorkerStateForSupervisedDispatches() {
        XCTAssertFalse(OrchestrationViewControls.isSettled(
            dispatchStatus: "dispatched", workerState: "ready"))
        XCTAssertFalse(OrchestrationViewControls.isSettled(
            dispatchStatus: "dispatched", workerState: "starting"))
        XCTAssertFalse(OrchestrationViewControls.isSettled(
            dispatchStatus: "dispatched", workerState: "start_unknown"))
        XCTAssertFalse(OrchestrationViewControls.isSettled(
            dispatchStatus: "dispatched", workerState: "stopping"))
        XCTAssertFalse(OrchestrationViewControls.isSettled(
            dispatchStatus: "failed", workerState: "stop_unknown"))
        XCTAssertTrue(OrchestrationViewControls.isSettled(
            dispatchStatus: "completed", workerState: "succeeded"))
        XCTAssertTrue(OrchestrationViewControls.isSettled(
            dispatchStatus: "failed", workerState: "failed"))
        XCTAssertTrue(OrchestrationViewControls.isSettled(
            dispatchStatus: "failed", workerState: "stopped"))
        XCTAssertTrue(OrchestrationViewControls.isSettled(
            dispatchStatus: "failed", workerState: "abandoned"))
    }

    func testSettledUsesDispatchStatusForUnsupervised() {
        XCTAssertFalse(OrchestrationViewControls.isSettled(
            dispatchStatus: "dispatched", workerState: "unsupervised"))
        XCTAssertFalse(OrchestrationViewControls.isSettled(
            dispatchStatus: "pending", workerState: "unsupervised"))
        XCTAssertTrue(OrchestrationViewControls.isSettled(
            dispatchStatus: "completed", workerState: "unsupervised"))
        XCTAssertTrue(OrchestrationViewControls.isSettled(
            dispatchStatus: "failed", workerState: "unsupervised"))
        XCTAssertTrue(OrchestrationViewControls.isSettled(
            dispatchStatus: "circuit_broken", workerState: "unsupervised"))
    }

    func testReleaseEnabledOnlyWhenSettled() {
        let live = OrchestrationViewControls.enablement(
            dispatchStatus: "dispatched", workerState: "ready",
            terminalState: "active", agentHandle: "term_w")
        XCTAssertFalse(live.release)
        XCTAssertTrue(live.stop)
        XCTAssertTrue(live.retain)

        let done = OrchestrationViewControls.enablement(
            dispatchStatus: "completed", workerState: "succeeded",
            terminalState: "reclaimable", agentHandle: "term_w")
        XCTAssertTrue(done.release)
        XCTAssertFalse(done.stop)
        XCTAssertTrue(done.retain)
    }

    func testStopNeverOfferedForSettledDispatches() {
        for worker in ["succeeded", "failed", "stopped", "abandoned"] {
            let controls = OrchestrationViewControls.enablement(
                dispatchStatus: "failed", workerState: worker,
                terminalState: "reclaimable", agentHandle: "term_w")
            XCTAssertFalse(controls.stop, "stop offered for settled \(worker)")
            XCTAssertTrue(controls.release)
        }
        let unsupervised = OrchestrationViewControls.enablement(
            dispatchStatus: "completed", workerState: "unsupervised",
            terminalState: "retained", agentHandle: "term_w")
        XCTAssertFalse(unsupervised.stop)
        XCTAssertTrue(unsupervised.release)
    }

    func testRetainHiddenOnceReleased() {
        let released = OrchestrationViewControls.enablement(
            dispatchStatus: "completed", workerState: "succeeded",
            terminalState: "released", agentHandle: "term_w")
        XCTAssertTrue(released.release)
        XCTAssertFalse(released.retain)
        XCTAssertFalse(released.stop)
    }

    func testRetainHiddenWithoutTerminal() {
        let bare = OrchestrationViewControls.enablement(
            dispatchStatus: "completed", workerState: "succeeded",
            terminalState: nil, agentHandle: nil)
        XCTAssertTrue(bare.release)
        XCTAssertFalse(bare.retain)
        XCTAssertFalse(bare.stop)
    }

    // MARK: - Confirm copy

    func testReleaseConfirmNamesTheExactTerminal() {
        XCTAssertEqual(
            OrchestrationViewControls.releaseConfirmTitle(terminalHandle: "term_abc"),
            "Release terminal term_abc?")
        XCTAssertEqual(
            OrchestrationViewControls.releaseConfirmBody(terminalHandle: "term_abc"),
            "This archives inspectable output, then closes terminal term_abc.")
        XCTAssertTrue(
            OrchestrationViewControls.releaseConfirmTitle(terminalHandle: nil)
                .contains("dispatch"))
        XCTAssertFalse(
            OrchestrationViewControls.releaseConfirmBody(terminalHandle: "  ")
                .contains("closes terminal"))
    }

    func testStopConfirmNamesTheTaskAndWarnsFailure() {
        XCTAssertEqual(
            OrchestrationViewControls.stopConfirmTitle(taskTitle: "T47 view controls"),
            "Stop “T47 view controls”?")
        XCTAssertEqual(
            OrchestrationViewControls.stopConfirmBody(),
            "The dispatch will be failed.")
    }

    // MARK: - Audit

    func testAuditLineIsTimestampActionTargetOutcomeReason() {
        let stamp = Date(timeIntervalSince1970: 1_777_046_400)
        let line = OrchestrationViewControls.formatAudit(
            timestamp: stamp,
            action: "worker-release",
            target: "ctx_1",
            outcome: "retained",
            reason: "identity_unproven")
        XCTAssertTrue(line.contains("worker-release"))
        XCTAssertTrue(line.contains("ctx_1"))
        XCTAssertTrue(line.contains("retained"))
        XCTAssertTrue(line.contains("identity_unproven"))
        XCTAssertTrue(line.hasPrefix(OrchestrationViewControls.iso8601.string(from: stamp)))
    }

    func testAuditOmitsEmptyReason() {
        let line = OrchestrationViewControls.formatAudit(
            timestamp: Date(timeIntervalSince1970: 0),
            action: "worker-stop",
            target: "ctx_2",
            outcome: "stopped")
        XCTAssertEqual(
            line.split(separator: "  ").map(String.init).suffix(3),
            ["worker-stop", "ctx_2", "stopped"])
    }

    // MARK: - Receipt / error parsing

    func testReleaseReceiptSurfacesTypedRetainReason() {
        let result = OrchestrationViewControls.result(
            action: "worker-release",
            target: "ctx_1",
            receipt: .object([
                "state": .string("retained"),
                "reason": .string("identity_unproven"),
                "processAction": .string("none"),
            ]),
            timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.outcome, "retained")
        XCTAssertEqual(result.reason, "identity_unproven")
        XCTAssertTrue(result.isRefusal)
        XCTAssertEqual(result.displayReason, "identity_unproven")
        XCTAssertTrue(OrchestrationViewControls.formatAudit(result).contains("identity_unproven"))
    }

    func testUserRequestedRetainIsNotARefusal() {
        let result = OrchestrationViewControls.result(
            action: "worker-retain",
            target: "ctx_1",
            receipt: .object([
                "state": .string("retained"),
                "reason": .string("user_requested"),
            ]))
        XCTAssertFalse(result.isRefusal)
        XCTAssertEqual(result.displayReason, "user_requested")
    }

    func testRPCErrorBecomesInlineTypedReason() {
        let result = OrchestrationViewControls.result(
            action: "worker-release",
            target: "ctx_1",
            error: RPCServiceError(
                code: "dispatch_inactive",
                message: "Dispatch ctx_1 is ready; only a settled worker can release."))
        XCTAssertEqual(result.outcome, "error")
        XCTAssertEqual(result.reason, "dispatch_inactive")
        XCTAssertTrue(result.isRefusal)
        XCTAssertEqual(result.displayReason, "dispatch_inactive")
    }

    func testGateReceiptUsesStatusAndResolution() {
        let result = OrchestrationViewControls.result(
            action: "gate-resolve",
            target: "gate_1",
            receipt: .object([
                "gate": .object([
                    "id": .string("gate_1"),
                    "status": .string("resolved"),
                    "resolution": .string("yes"),
                ]),
            ]))
        XCTAssertEqual(result.outcome, "resolved")
        XCTAssertEqual(result.message, "yes")
        XCTAssertFalse(result.isRefusal)
    }

    // MARK: - Live store verb wiring

    func testViewSnapshotIncludesPendingGates() async throws {
        let live = try isolatedStore()
        let created = try await live.runCreate([
            "objective": .string("Wave 12 controls"),
            "from": .string("term_coord"),
        ])
        let runID = try XCTUnwrap(created.field("runId")?.stringValue)
        let task = try await live.taskCreate([
            "run": .string(runID),
            "spec": .string("Need a human decision"),
            "display-name": .string("T47"),
            "from": .string("term_coord"),
        ])
        let taskID = try XCTUnwrap(task.field("taskId")?.stringValue)
        let gate = try await live.gateCreate([
            "task": .string(taskID),
            "question": .string("Ship to prod?"),
            "options": .string("yes,no"),
        ])
        let gateID = try XCTUnwrap(gate.field("gateId")?.stringValue)

        let snapshot = try await live.viewSnapshot()
        let row = try XCTUnwrap(snapshot.runs.first?.tasks.first { $0.id == taskID })
        XCTAssertEqual(row.status, "blocked")
        XCTAssertEqual(row.gates.count, 1)
        XCTAssertEqual(row.gates.first?.id, gateID)
        XCTAssertEqual(row.gates.first?.question, "Ship to prod?")
        XCTAssertEqual(row.gates.first?.options, ["yes", "no"])
        XCTAssertEqual(row.gates.first?.status, "pending")
    }

    func testViewGateResolveUsesTheVerbPath() async throws {
        let live = try isolatedStore()
        let created = try await live.runCreate([
            "objective": .string("Wave 12 gate"),
            "from": .string("term_coord"),
        ])
        let runID = try XCTUnwrap(created.field("runId")?.stringValue)
        let task = try await live.taskCreate([
            "run": .string(runID),
            "spec": .string("Decide"),
            "from": .string("term_coord"),
        ])
        let taskID = try XCTUnwrap(task.field("taskId")?.stringValue)
        let gate = try await live.gateCreate([
            "task": .string(taskID),
            "question": .string("Approve?"),
            "options": .string("yes,no"),
        ])
        let gateID = try XCTUnwrap(gate.field("gateId")?.stringValue)

        let missing = await live.viewGateResolve(gateID: "gate_missing", resolution: "yes")
        XCTAssertEqual(missing.outcome, "error")
        XCTAssertEqual(missing.reason, "gate_not_found")
        XCTAssertTrue(missing.isRefusal)

        let resolved = await live.viewGateResolve(gateID: gateID, resolution: "yes")
        XCTAssertEqual(resolved.action, "gate-resolve")
        XCTAssertEqual(resolved.target, gateID)
        XCTAssertEqual(resolved.outcome, "resolved")
        XCTAssertEqual(resolved.message, "yes")

        let snapshot = try await live.viewSnapshot()
        let row = try XCTUnwrap(snapshot.runs.first?.tasks.first { $0.id == taskID })
        XCTAssertEqual(row.status, "ready")
        XCTAssertTrue(row.gates.isEmpty)
    }

    func testViewWorkerReleaseOnUnsettledUsesVerbRefusal() async throws {
        let live = try isolatedStore()
        let created = try await live.runCreate([
            "objective": .string("Wave 12 release"),
            "from": .string("term_coord"),
        ])
        let runID = try XCTUnwrap(created.field("runId")?.stringValue)
        let task = try await live.taskCreate([
            "run": .string(runID),
            "spec": .string("Live worker"),
            "from": .string("term_coord"),
        ])
        let taskID = try XCTUnwrap(task.field("taskId")?.stringValue)
        let dispatched = try await live.dispatchTask([
            "task": .string(taskID), "to": .string("term_worker"),
        ])
        let dispatchID = try XCTUnwrap(dispatched.field("dispatchId")?.stringValue)

        let result = await live.viewWorkerRelease(
            dispatchID: dispatchID, runtime: unusedWorkerRuntime())
        XCTAssertEqual(result.action, "worker-release")
        XCTAssertEqual(result.target, dispatchID)
        XCTAssertEqual(result.outcome, "error")
        XCTAssertEqual(result.reason, "dispatch_inactive")
        XCTAssertTrue(result.isRefusal)
        XCTAssertTrue(result.message?.contains("settled") == true)
    }

    func testViewWorkerRetainMissingDispatchIsTyped() async throws {
        let live = try isolatedStore()
        let result = await live.viewWorkerRetain(dispatchID: "ctx_missing")
        XCTAssertEqual(result.outcome, "error")
        XCTAssertEqual(result.reason, "dispatch_not_found")
        XCTAssertTrue(result.isRefusal)
    }

    func testViewWorkerStopOnUnsupervisedUsesVerbPath() async throws {
        let live = try isolatedStore()
        let created = try await live.runCreate([
            "objective": .string("Wave 12 stop"),
            "from": .string("term_coord"),
        ])
        let runID = try XCTUnwrap(created.field("runId")?.stringValue)
        let task = try await live.taskCreate([
            "run": .string(runID),
            "spec": .string("Injected assignment"),
            "from": .string("term_coord"),
        ])
        let taskID = try XCTUnwrap(task.field("taskId")?.stringValue)
        let dispatched = try await live.dispatchTask([
            "task": .string(taskID), "to": .string("term_worker"),
        ])
        let dispatchID = try XCTUnwrap(dispatched.field("dispatchId")?.stringValue)

        let result = await live.viewWorkerStop(
            dispatchID: dispatchID, runtime: unusedWorkerRuntime())
        XCTAssertEqual(result.action, "worker-stop")
        XCTAssertEqual(result.target, dispatchID)
        XCTAssertEqual(result.outcome, "stopped")
        XCTAssertEqual(result.message,
                       "The assignment was stopped without closing its unsupervised terminal process.")

        let snapshot = try await live.viewSnapshot()
        let row = try XCTUnwrap(snapshot.runs.first?.tasks.first?.dispatches.first)
        XCTAssertEqual(row.dispatchStatus, "failed")
        XCTAssertFalse(OrchestrationViewControls.enablement(
            dispatchStatus: row.dispatchStatus, workerState: row.workerState,
            terminalState: row.terminalState, agentHandle: row.agentHandle).stop)

        let missing = await live.viewWorkerStop(
            dispatchID: "ctx_missing", runtime: unusedWorkerRuntime())
        XCTAssertEqual(missing.outcome, "error")
        XCTAssertEqual(missing.reason, "dispatch_not_found")
        XCTAssertTrue(missing.isRefusal)
    }

    func testViewGateResolveEmptyResolutionIsTyped() async throws {
        let live = try isolatedStore()
        let result = await live.viewGateResolve(gateID: "gate_1", resolution: "")
        XCTAssertEqual(result.outcome, "error")
        XCTAssertEqual(result.reason, "invalid_argument")
        XCTAssertTrue(result.isRefusal)
    }

    // MARK: - Helpers

    private func isolatedStore() throws -> LiveOrchestrationStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("orch-controls-\(UUID().uuidString).db").path
        return try LiveOrchestrationStore(databasePath: path)
    }

    private func unusedWorkerRuntime() -> WorkerRuntimeContext {
        struct Unused: Error {}
        return WorkerRuntimeContext(
            createWorktree: { _ in throw Unused() },
            resolveWorktree: { _, _ in throw Unused() },
            createAgentTerminal: { _, _ in throw Unused() },
            lookupTerminal: { _ in .missing },
            waitForAgentIdle: { _, _ in throw Unused() },
            injectPrompt: { _, _ in throw Unused() },
            readTerminal: { _, _, _ in throw Unused() },
            closeTerminal: { _ in })
    }
}
