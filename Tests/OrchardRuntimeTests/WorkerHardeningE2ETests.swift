import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// T11 dogfood acceptance: the LIVE runtime assembly (real SQLite store, real terminal
/// service on scripted PTYs, real workspace registry, the wired exit-escalation seam)
/// driven through the same command registry the socket serves — worker-start a shell
/// agent, read the injected preamble back like a real worker, and prove:
///   • lifecycle sends settle ONLY with the minted capability from the assignee pane;
///   • wrong/missing capability and wrong-pane sends get typed rejections that never
///     settle the dispatch;
///   • a live dispatch's PTY dying fails the dispatch and escalates (priority-high,
///     Run-addressed, waking `check --wait`) — while deliberate closes never escalate.
final class WorkerHardeningE2ETests: XCTestCase {

    /// MainActor holder for the scripted sessions the host's factory spawns.
    @MainActor
    private final class SessionBox {
        var sessions: [String: ScriptedTerminalSession] = [:]   // by handle
    }

    private var root: URL!
    private var host: OrchardRuntimeHost!
    private var box: SessionBox!
    private var workspaceSelector: String!

    override func setUp() async throws {
        try await super.setUp()
        root = URL(fileURLWithPath: "/tmp/o-hard-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scoped = ScopedFileManager(root: root)
        let box = await MainActor.run { SessionBox() }
        self.box = box
        host = try await MainActor.run {
            try OrchardRuntimeHost(
                fileManager: scoped,
                terminalFactory: { spec, _ in
                    let session = ScriptedTerminalSession()
                    box.sessions[spec.handle] = session
                    return session
                })
        }

        // A plain folder registered as a repo yields a folder workspace — a real
        // worker placement with no git involved.
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let added = await perform("repo-add", ["path": .string(folder.path)])
        XCTAssertTrue(added.ok, String(describing: added.error))
        workspaceSelector = "path:" + folder.path
    }

    override func tearDown() async throws {
        if let host { await MainActor.run { host.shutdown() } }
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - Harness

    private func perform(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await host.inMemory.perform(RPCRequest(method: method, params: .object(params)))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
    }

    private struct StartedWorker {
        let taskID: String
        let dispatchID: String
        let handle: String
        let capability: String
        let session: ScriptedTerminalSession
    }

    /// run-create (once) + task-create + `worker-start --agent shell` against the live
    /// registry, driving the scripted shell to readiness (no foreground job + quiet
    /// screen — the generic non-TUI detector path), then reading the capability back
    /// out of the injected preamble exactly as the dispatched worker would.
    private func startShellWorker(spec: String) async throws -> StartedWorker {
        let runs = await perform("run-list")
        if runs.result?.field("count")?.numberValue == 0 {
            let created = await perform("run-create", [
                "objective": .string("harden the loop"), "from": .string("term_boss")])
            XCTAssertTrue(created.ok, String(describing: created.error))
        }
        let task = await perform("task-create", [
            "spec": .string(spec), "from": .string("term_boss")])
        let taskID = try XCTUnwrap(task.result?.field("taskId")?.stringValue)

        let known = await MainActor.run { [box] in Set(box!.sessions.keys) }
        let params: [String: JSONValue] = [
            "task": .string(taskID),
            "agent": .string("shell"),
            "worktree": .string(workspaceSelector),
            "timeout-ms": .number(15000),
        ]
        let server = host.inMemory
        let pending = Task {
            await server.perform(RPCRequest(method: "worker-start", params: .object(params)))
        }

        try await waitUntil("shell terminal spawn") { [box] in
            box!.sessions.keys.contains { !known.contains($0) }
        }
        let session = await MainActor.run { [box] () -> ScriptedTerminalSession in
            let handle = box!.sessions.keys.first { !known.contains($0) }!
            return box!.sessions[handle]!
        }
        // Back at the shell prompt: no foreground job, and the pump keeps re-painting
        // the prompt. Since T82 the shell also has to *answer*: worker-start proves a
        // bare shell is executing input by running a nonce probe, and the scripted
        // session has no shell behind it, so the pump prints what a real `printf`
        // would — first for the readiness probe, then for the contract's own marker.
        await MainActor.run { session.hasRunningForegroundJob = false }
        let pump = Task { @MainActor in
            var answered: Set<String> = []
            while !Task.isCancelled {
                session.showScreen(["$ "])
                let text = session.writtenText
                var from = text.startIndex
                while let hit = text.range(of: "orchard-shell-ready %s\\n' '",
                                           range: from..<text.endIndex) {
                    let nonce = String(text[hit.upperBound...].prefix { $0.isLetter || $0.isNumber })
                    if !nonce.isEmpty, answered.insert(nonce).inserted {
                        session.emitOutput("orchard-shell-ready \(nonce)\n")
                    }
                    from = hit.upperBound
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let response = await pending.value
        pump.cancel()
        XCTAssertTrue(response.ok, String(describing: response.error))
        XCTAssertEqual(response.result?.field("state")?.stringValue, "ready")
        let dispatchID = try XCTUnwrap(response.result?.field("dispatchId")?.stringValue)
        let terminalEffect = response.result?.field("effects")?.arrayValue?
            .first { $0.field("kind")?.stringValue == "terminal" }
        let handle = try XCTUnwrap(terminalEffect?.field("id")?.stringValue)

        // The worker's view: the capability secret arrives only via the dispatch input.
        // Keyed on the secret's own prefix, not on the flag before it — a shell worker's
        // contract (T82) also spells the flag with an exported variable reference, and
        // only the value itself is common to every delivery shape.
        let typed = await MainActor.run { session.writtenText }
        XCTAssertTrue(typed.contains("--task-id \(taskID)"))
        XCTAssertTrue(typed.contains("--dispatch-id \(dispatchID)"))
        let secretStart = try XCTUnwrap(typed.range(of: "dcap_")).lowerBound
        let capability = String(typed[secretStart...]
            .prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        XCTAssertTrue(capability.hasPrefix("dcap_"))
        return StartedWorker(taskID: taskID, dispatchID: dispatchID,
                             handle: handle, capability: capability, session: session)
    }

    private func workerDone(_ worker: StartedWorker, from: String? = nil,
                            capability: String?) async -> RPCResponse {
        var params: [String: JSONValue] = [
            "from": .string(from ?? worker.handle),
            "type": .string("worker_done"),
            "subject": .string("done"),
            "body": .string("Did the work. Found nothing odd. Nothing left."),
            "task-id": .string(worker.taskID),
            "dispatch-id": .string(worker.dispatchID),
            "outcome": .string("succeeded"),
        ]
        if let capability { params["dispatch-capability"] = .string(capability) }
        return await perform("send", params)
    }

    private func taskStatus(_ taskID: String) async -> String? {
        let tasks = await perform("task-list")
        return tasks.result?.field("tasks")?.arrayValue?
            .first { $0.field("id")?.stringValue == taskID }?
            .field("status")?.stringValue
    }

    private func dispatchShow(_ dispatchID: String) async -> RPCResponse {
        await perform("dispatch-show", ["id": .string(dispatchID)])
    }

    // MARK: - Capability enforcement on lifecycle sends

    func testLifecycleSendsSettleOnlyWithCapabilityFromTheAssigneePane() async throws {
        let worker = try await startShellWorker(spec: "prove the capability gate")

        // A missing capability is a typed rejection — recorded, never settled.
        let bare = await workerDone(worker, capability: nil)
        XCTAssertTrue(bare.ok, String(describing: bare.error))
        XCTAssertEqual(bare.result?.field("lifecycle")?.field("status")?.stringValue, "rejected")
        XCTAssertEqual(bare.result?.field("lifecycle")?.field("code")?.stringValue,
                       "dispatch_capability_invalid")
        XCTAssertTrue(bare.result?.field("lifecycle")?.field("reason")?.stringValue?
            .contains("--dispatch-capability") == true)

        // A forged capability is a typed rejection.
        let forged = await workerDone(worker, capability: "dcap_forgedforgedforgedforgedforge")
        XCTAssertEqual(forged.result?.field("lifecycle")?.field("status")?.stringValue, "rejected")
        XCTAssertEqual(forged.result?.field("lifecycle")?.field("code")?.stringValue,
                       "dispatch_capability_invalid")
        XCTAssertTrue(forged.result?.field("lifecycle")?.field("reason")?.stringValue?
            .contains("does not match") == true)

        // The REAL capability from the wrong pane is still a rejection — payload
        // knowledge (even of the secret) is not pane authority.
        let wrongPane = await workerDone(worker, from: "term_intruder",
                                         capability: worker.capability)
        XCTAssertEqual(wrongPane.result?.field("lifecycle")?.field("status")?.stringValue, "rejected")
        XCTAssertEqual(wrongPane.result?.field("lifecycle")?.field("code")?.stringValue,
                       "dispatch_capability_invalid")
        XCTAssertTrue(wrongPane.result?.field("lifecycle")?.field("reason")?.stringValue?
            .contains("wrong pane") == true)

        // Heartbeats are gated the same way; a rejected one must not refresh liveness.
        let bareBeat = await perform("send", [
            "from": .string(worker.handle), "type": .string("heartbeat"),
            "subject": .string("alive"), "dispatch-id": .string(worker.dispatchID),
            "phase": .string("implementing"),
        ])
        XCTAssertEqual(bareBeat.result?.field("lifecycle")?.field("code")?.stringValue,
                       "dispatch_capability_invalid")
        var shown = await dispatchShow(worker.dispatchID)
        XCTAssertEqual(shown.result?.field("dispatch")?.field("last_heartbeat_at"), JSONValue.null)

        // `ask` refuses without the capability BEFORE any question row exists.
        let bareAsk = await perform("ask", [
            "from": .string(worker.handle), "question": .string("may I?"),
            "timeout-ms": .number(500),
        ])
        XCTAssertFalse(bareAsk.ok)
        XCTAssertEqual(bareAsk.error?.code, "dispatch_capability_invalid")

        // Nothing above settled anything.
        shown = await dispatchShow(worker.dispatchID)
        XCTAssertEqual(shown.result?.field("dispatch")?.field("status")?.stringValue, "dispatched")
        let status = await taskStatus(worker.taskID)
        XCTAssertEqual(status, "dispatched")

        // Coordinator-originated non-lifecycle sends are unaffected by enforcement.
        let note = await perform("send", [
            "from": .string("term_boss"), "to": .string(worker.handle),
            "subject": .string("fyi"), "body": .string("carry on"),
        ])
        XCTAssertTrue(note.ok, String(describing: note.error))
        XCTAssertNil(note.result?.field("lifecycle"))

        // The real capability from the real pane: heartbeat records, worker_done settles.
        let beat = await perform("send", [
            "from": .string(worker.handle),
            "dispatch-capability": .string(worker.capability),
            "type": .string("heartbeat"), "subject": .string("alive"),
            "dispatch-id": .string(worker.dispatchID), "phase": .string("reviewing"),
        ])
        XCTAssertEqual(beat.result?.field("lifecycle")?.field("status")?.stringValue,
                       "heartbeat_recorded")
        shown = await dispatchShow(worker.dispatchID)
        XCTAssertNotEqual(shown.result?.field("dispatch")?.field("last_heartbeat_at"), JSONValue.null)

        let done = await workerDone(worker, capability: worker.capability)
        XCTAssertTrue(done.ok, String(describing: done.error))
        XCTAssertEqual(done.result?.field("lifecycle")?.field("status")?.stringValue, "settled")
        XCTAssertEqual(done.result?.field("lifecycle")?.field("outcome")?.stringValue, "succeeded")
        shown = await dispatchShow(worker.dispatchID)
        XCTAssertEqual(shown.result?.field("dispatch")?.field("status")?.stringValue, "completed")
        XCTAssertEqual(shown.result?.field("workerDispatch")?.field("state")?.stringValue,
                       "succeeded")
        let settled = await taskStatus(worker.taskID)
        XCTAssertEqual(settled, "completed")
    }

    // MARK: - Worker-process-exit auto-escalation

    func testPTYDeathFailsTheDispatchAndEscalatesToTheRun() async throws {
        let worker = try await startShellWorker(spec: "die mid-flight")
        let runs = await perform("run-list")
        let runID = try XCTUnwrap(
            runs.result?.field("runs")?.arrayValue?.first?.field("id")?.stringValue)

        // Park the coordinator's long-poll BEFORE the death; the escalation must wake it.
        let server = host.inMemory
        let waiter = Task {
            await server.perform(RPCRequest(method: "check", params: .object([
                "terminal": .string("term_boss"), "wait": .bool(true),
                "types": .string("escalation"), "timeout-ms": .number(10000),
            ])))
        }
        try await waitUntil("check --wait parked") { [host] in
            host!.waitCenter.waiterCount >= 1
        }

        await MainActor.run { worker.session.exit(code: 137) }

        let woken = await waiter.value
        XCTAssertTrue(woken.ok, String(describing: woken.error))
        XCTAssertEqual(woken.result?.field("count")?.numberValue, 1)
        let escalation = try XCTUnwrap(woken.result?.field("messages")?.arrayValue?.first)
        XCTAssertEqual(escalation.field("type")?.stringValue, "escalation")
        XCTAssertEqual(escalation.field("priority")?.stringValue, "high")
        XCTAssertEqual(escalation.field("to_handle")?.stringValue, "run:\(runID)")
        let payloadText = try XCTUnwrap(escalation.field("payload")?.stringValue)
        let payload = try XCTUnwrap(
            try JSONDecoder().decode(JSONValue.self, from: Data(payloadText.utf8)).objectValue)
        XCTAssertEqual(payload["taskId"]?.stringValue, worker.taskID)
        XCTAssertEqual(payload["dispatchId"]?.stringValue, worker.dispatchID)
        XCTAssertEqual(payload["exitCode"]?.numberValue, 137)

        // The dispatch failed with the process-exit provenance; the task went back to
        // ready (one failure — far from the circuit breaker).
        let shown = await dispatchShow(worker.dispatchID)
        XCTAssertEqual(shown.result?.field("dispatch")?.field("status")?.stringValue, "failed")
        XCTAssertEqual(shown.result?.field("dispatch")?.field("termination_reason")?.stringValue,
                       "worker_process_exited")
        XCTAssertEqual(shown.result?.field("workerDispatch")?.field("state")?.stringValue, "failed")
        XCTAssertEqual(shown.result?.field("workerDispatch")?.field("stage")?.stringValue,
                       "process_exited")
        let status = await taskStatus(worker.taskID)
        XCTAssertEqual(status, "ready")

        // A late worker_done from the dead attempt cannot settle anything.
        let late = await workerDone(worker, capability: worker.capability)
        XCTAssertTrue(late.ok)
        XCTAssertEqual(late.result?.field("lifecycle")?.field("status")?.stringValue, "rejected")
    }

    func testDeliberateClosesNeverEscalate() async throws {
        // Coordinator worker-stop: the stop owns settlement; no escalation appears.
        let stopped = try await startShellWorker(spec: "stopped on purpose")
        let stop = await perform("worker-stop", ["dispatch": .string(stopped.dispatchID)])
        XCTAssertTrue(stop.ok, String(describing: stop.error))
        XCTAssertEqual(stop.result?.field("state")?.stringValue, "stopped")

        // User close of a live worker's pane: the dispatch fails (deliberate_close),
        // but nothing escalates.
        let closed = try await startShellWorker(spec: "closed by the user")
        try await MainActor.run { [host] in
            try host!.terminalService.close(handle: closed.handle)
        }
        var settled = false
        for _ in 0..<50 {
            let shown = await dispatchShow(closed.dispatchID)
            if shown.result?.field("dispatch")?.field("status")?.stringValue == "failed" {
                settled = true
                XCTAssertEqual(
                    shown.result?.field("dispatch")?.field("termination_reason")?.stringValue,
                    "deliberate_close")
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(settled, "the user close never failed the live dispatch")

        // Neither deliberate path produced an escalation in the Run's history.
        let history = await perform("check", [
            "terminal": .string("term_boss"), "all": .bool(true),
            "types": .string("escalation"),
        ])
        XCTAssertTrue(history.ok, String(describing: history.error))
        XCTAssertEqual(history.result?.field("count")?.numberValue, 0,
                       String(describing: history.result))
    }
}
