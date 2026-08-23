import XCTest
import OrchardOrchestration
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// T7 acceptance: the worker lifecycle verbs end to end against T1's real SQLite
/// store, T3's real terminal service (scripted PTYs, fast pipeline/detector configs),
/// and a stubbed workspace seam — worker-start's staged receipt, the three-state
/// agentWait convention, archive-before-close release, and the stop/abandon/retain/
/// list semantics.
final class WorkerVerbTests: XCTestCase {

    /// The main-actor half of the harness: the terminal service, its scripted
    /// sessions, and the stub workspace registry the context closures consult.
    @MainActor
    private final class TerminalHarness {
        var sessions: [String: ScriptedTerminalSession] = [:]   // by handle
        private(set) var service: TerminalService!
        var workspaces: [String: WorkerWorktreeReceipt] = [:]
        var worktreeCreates: [WorkerWorktreeSpec] = []

        init() {
            var detector = ReadinessDetector.Config()
            detector.idleDebounce = 1
            detector.spawnFloor = 0
            var pipeline = SendPipelineConfig()
            pipeline.submitDelay = 0.05
            pipeline.verifyTimeout = 1.0
            pipeline.verifyPollInterval = 0.01
            service = TerminalService(
                factory: { [weak self] spec, _ in
                    let session = ScriptedTerminalSession()
                    self?.sessions[spec.handle] = session
                    return session
                },
                pipeline: pipeline,
                detectorConfig: detector)
        }

        func createWorktree(_ spec: WorkerWorktreeSpec) -> WorkerWorktreeReceipt {
            worktreeCreates.append(spec)
            let name = spec.name ?? "worker-\(worktreeCreates.count)"
            let receipt = WorkerWorktreeReceipt(
                id: "repo::/wt/\(name)", instanceId: UUID().uuidString,
                path: "/wt/\(name)", displayName: name)
            workspaces[receipt.id] = receipt
            return receipt
        }
    }

    private var terminalHarness: TerminalHarness!
    private var store: OrchestrationStore!
    private var live: LiveOrchestrationStore!
    private var handler: WorkerCommandHandler!

    override func setUp() async throws {
        try await super.setUp()
        let harness = await MainActor.run { TerminalHarness() }
        terminalHarness = harness
        store = try OrchestrationStore.temporary()
        // The pane-key resolver must be live (as in RuntimeAssembly): worker_done
        // settlement proves the sender by pane identity, not the handle string.
        live = LiveOrchestrationStore(
            store: store,
            context: OrchestrationRuntimeContext(paneKey: { handle in
                await MainActor.run {
                    OrchardRuntimeHost.resolvePaneKey(harness.service, handle: handle)
                }
            }))
        let context = WorkerRuntimeContext(
            cliCommand: "orchard",
            createWorktree: { spec in
                await harness.createWorktree(spec)
            },
            resolveWorktree: { selector, _ in
                guard let receipt = await harness.workspaces[selector] else {
                    throw WorkspaceError("unknown_worktree", "no worktree matching '\(selector)'")
                }
                return receipt
            },
            createAgentTerminal: { engine, worktreeID, cwd, title in
                try await harness.service.create(worktreeId: worktreeID, cwd: cwd,
                                                 engineID: engine, prompt: "", title: title)
            },
            lookupTerminal: { handle in
                await WorkerRuntimeContext.resolveSummary(harness.service, handle: handle)
            },
            waitForAgentIdle: { handle, timeout in
                try await harness.service.wait(handle: handle, for: .tuiIdle, timeout: timeout)
            },
            injectPrompt: { handle, text in
                try await harness.service.send(handle: handle, text: text, enter: true)
            },
            readTerminal: { handle, cursor, limit in
                try await harness.service.read(handle: handle, cursor: cursor, limit: limit)
            },
            closeTerminal: { handle in
                try await harness.service.close(handle: handle)
            })
        handler = WorkerCommandHandler(store: live, runtime: context)
    }

    override func tearDown() async throws {
        store?.close()
        store = nil
        live = nil
        handler = nil
        terminalHarness = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await handler.handle(RPCRequest(method: method, params: .object(params)))
    }

    /// run-create (once) + task-create, returning the taskId (single-run inference).
    @discardableResult
    private func makeTask(spec: String = "do the work") async throws -> String {
        let runs = try await live.runList([:])
        if runs.field("count")?.numberValue == 0 {
            _ = try await live.runCreate(["objective": .string("worker tests")])
        }
        let task = try await live.taskCreate(["spec": .string(spec)])
        return try XCTUnwrap(task.field("taskId")?.stringValue)
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

    /// Start a worker against a fresh worktree and drive the scripted agent through
    /// readiness + injection: idle when spawned, working once the TASK block lands.
    private func startReadyWorker(taskID: String,
                                  extra: [String: JSONValue] = [:]) async throws -> RPCResponse {
        var params: [String: JSONValue] = [
            "task": .string(taskID),
            "agent": .string("claude-code"),
            "worktree": .string("new-top-level"),
            "repo": .string("demo"),
        ]
        for (key, value) in extra { params[key] = value }
        let known = await MainActor.run { [terminalHarness] in
            Set(terminalHarness!.sessions.keys)
        }
        let handler = handler!
        let request = RPCRequest(method: "worker-start", params: .object(params))
        let pending = Task { await handler.handle(request) }
        try await driveAgentThroughStart(previouslyKnown: known)
        return await pending.value
    }

    private func driveAgentThroughStart(previouslyKnown: Set<String>) async throws {
        try await waitUntil("agent terminal spawn") { [terminalHarness] in
            terminalHarness!.sessions.keys.contains { !previouslyKnown.contains($0) }
        }
        let session = await MainActor.run { [terminalHarness] () -> ScriptedTerminalSession in
            let handle = terminalHarness!.sessions.keys.first { !previouslyKnown.contains($0) }!
            return terminalHarness!.sessions[handle]!
        }
        await MainActor.run { session.emitOSC(["9999", "idle"]) }
        try await waitUntil("preamble injection") {
            session.writtenText.contains("=== TASK ===")
        }
        await MainActor.run { session.emitOSC(["9999", "working"]) }
    }

    /// The scripted session behind a live terminal handle.
    private func session(_ handle: String) async throws -> ScriptedTerminalSession {
        let session = await MainActor.run { [terminalHarness] in
            terminalHarness!.sessions[handle]
        }
        return try XCTUnwrap(session, "no scripted session for \(handle)")
    }

    private func terminalExists(_ handle: String) async -> Bool {
        await MainActor.run { [terminalHarness] in
            (try? terminalHarness!.service.summary(handle: handle)) != nil
        }
    }

    private func agentHandle(_ receipt: RPCResponse) throws -> String {
        let effects = try XCTUnwrap(receipt.result?.field("effects")?.arrayValue)
        let terminal = try XCTUnwrap(effects.first { $0.field("kind")?.stringValue == "terminal" })
        return try XCTUnwrap(terminal.field("id")?.stringValue)
    }

    private func reportDone(taskID: String, dispatchID: String, handle: String,
                            outcome: String = "succeeded") async throws {
        _ = try await live.send([
            "from": .string(handle),
            "type": .string("worker_done"),
            "subject": .string("done"),
            "body": .string("Did the thing. Found nothing odd. Nothing left."),
            "task-id": .string(taskID),
            "dispatch-id": .string(dispatchID),
            "outcome": .string(outcome),
        ])
    }

    // MARK: - worker-start

    func testWorkerStartHappyPathIsReadyWithStagedReceipt() async throws {
        let taskID = try await makeTask()
        let response = try await startReadyWorker(taskID: taskID)
        XCTAssertTrue(response.ok, String(describing: response.error))

        let receipt = try XCTUnwrap(response.result)
        XCTAssertEqual(receipt.field("state")?.stringValue, "ready")
        XCTAssertEqual(receipt.field("stage")?.stringValue, "input_accepted")
        XCTAssertEqual(receipt.field("residualResources")?.arrayValue?.count, 0)
        let dispatchID = try XCTUnwrap(receipt.field("dispatchId")?.stringValue)

        let kinds = receipt.field("effects")?.arrayValue?
            .compactMap { $0.field("kind")?.stringValue } ?? []
        XCTAssertEqual(kinds, ["worktree", "setup", "terminal", "dispatch_input"])
        let actions = receipt.field("effects")?.arrayValue?
            .compactMap { $0.field("action")?.stringValue }
        XCTAssertEqual(actions?.first, "created")
        XCTAssertEqual(receipt.field("setup")?.field("state")?.stringValue, "completed")

        // The staged rows: dispatch live with bound authority, worker ready, an owned
        // terminal resource, task dispatched.
        let handle = try agentHandle(response)
        let dispatch = try XCTUnwrap(try store.dispatchContext(dispatchID))
        XCTAssertEqual(dispatch.status, .dispatched)
        XCTAssertEqual(dispatch.assigneeHandle, handle)
        XCTAssertNotNil(dispatch.assigneePaneKey)
        XCTAssertEqual(dispatch.processIncarnation, "1")
        XCTAssertNotNil(dispatch.capabilityHash)
        let worker = try XCTUnwrap(try store.workerDispatch(dispatchID))
        XCTAssertEqual(worker.state, .ready)
        XCTAssertEqual(worker.agentTerminalHandle, handle)
        let resource = try XCTUnwrap(try store.workerTerminalResource(ownerDispatchID: dispatchID))
        XCTAssertEqual(resource.ownershipState, .owned)
        XCTAssertEqual(resource.releaseState, .notRequested)
        XCTAssertEqual(try store.task(taskID)?.status, .dispatched)

        // The injected preamble carried the real ids and the capability secret.
        let typed = try await session(handle).writtenText
        XCTAssertTrue(typed.contains("--task-id \(taskID)"))
        XCTAssertTrue(typed.contains("--dispatch-id \(dispatchID)"))
        XCTAssertTrue(typed.contains("--dispatch-capability dcap_"))
        XCTAssertTrue(typed.contains("worker_done"))
    }

    func testWorkerStartReadinessTimeoutFailsWithStagedReceipt() async throws {
        let taskID = try await makeTask()
        // Never drive the agent to idle; a short timeout forces the readiness stage
        // to fail with the worktree and terminal left as residuals.
        let response = await call("worker-start", [
            "task": .string(taskID),
            "agent": .string("claude-code"),
            "worktree": .string("new-top-level"),
            "repo": .string("demo"),
            "timeout-ms": .number(300),
        ])
        XCTAssertFalse(response.ok)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, "worker_start_failed")
        let receipt = try XCTUnwrap(error.data)
        XCTAssertEqual(receipt.field("state")?.stringValue, "failed")
        XCTAssertEqual(receipt.field("failedStage")?.stringValue, "agent_readiness")
        let residualKinds = receipt.field("residualResources")?.arrayValue?
            .compactMap { $0.field("kind")?.stringValue }
        XCTAssertEqual(residualKinds, ["worktree", "terminal"])

        let dispatchID = try XCTUnwrap(receipt.field("dispatchId")?.stringValue)
        let worker = try XCTUnwrap(try store.workerDispatch(dispatchID))
        XCTAssertEqual(worker.state, .failed)
        XCTAssertEqual(worker.stage, "agent_readiness")
        XCTAssertEqual(try store.dispatchContext(dispatchID)?.status, .failed)
        XCTAssertEqual(try store.task(taskID)?.status, .failed)
    }

    func testWorkerStartRequiresExactlyOneOfAgentOrTerminal() async throws {
        let taskID = try await makeTask()
        let neither = await call("worker-start", ["task": .string(taskID)])
        XCTAssertEqual(neither.error?.code, "invalid_argument")
        let both = await call("worker-start", [
            "task": .string(taskID), "agent": .string("claude-code"),
            "terminal": .string("term_x"),
        ])
        XCTAssertEqual(both.error?.code, "invalid_argument")
    }

    func testWorkerStartRetryRequestReplaysTheReceipt() async throws {
        let taskID = try await makeTask()
        let first = try await startReadyWorker(
            taskID: taskID, extra: ["retry-request": .string("req-1")])
        XCTAssertTrue(first.ok, String(describing: first.error))
        let dispatchID = first.result?.field("dispatchId")?.stringValue

        // Exact retry: no second dispatch is created; the stored receipt replays.
        let replay = await call("worker-start", [
            "task": .string(taskID),
            "agent": .string("claude-code"),
            "worktree": .string("new-top-level"),
            "repo": .string("demo"),
            "retry-request": .string("req-1"),
        ])
        XCTAssertTrue(replay.ok, String(describing: replay.error))
        XCTAssertEqual(replay.result?.field("dispatchId")?.stringValue, dispatchID)
        XCTAssertEqual(try store.listWorkerDispatches().count, 1)
    }

    func testWorkerStartWithReusedTerminalIsExternal() async throws {
        // A pre-existing agent terminal in a known worktree, already idle.
        let worktreeID = "repo::/wt/reuse"
        let existing = try await MainActor.run { [terminalHarness] () -> TerminalSummary in
            terminalHarness!.workspaces[worktreeID] = WorkerWorktreeReceipt(
                id: worktreeID, instanceId: UUID().uuidString,
                path: "/wt/reuse", displayName: "reuse")
            return try terminalHarness!.service.create(
                worktreeId: worktreeID, engineID: "claude-code", title: "existing")
        }
        let fake = try await session(existing.handle)
        await MainActor.run { fake.emitOSC(["9999", "idle"]) }

        let taskID = try await makeTask()
        let handler = handler!
        let pending = Task {
            await handler.handle(RPCRequest(method: "worker-start", params: .object([
                "task": .string(taskID),
                "terminal": .string(existing.handle),
            ])))
        }
        try await waitUntil("preamble injection") { fake.writtenText.contains("=== TASK ===") }
        await MainActor.run { fake.emitOSC(["9999", "working"]) }
        let response = await pending.value
        XCTAssertTrue(response.ok, String(describing: response.error))
        let dispatchID = try XCTUnwrap(response.result?.field("dispatchId")?.stringValue)

        let terminalEffect = response.result?.field("effects")?.arrayValue?
            .first { $0.field("kind")?.stringValue == "terminal" }
        XCTAssertEqual(terminalEffect?.field("action")?.stringValue, "reused")
        let resource = try XCTUnwrap(try store.workerTerminalResource(ownerDispatchID: dispatchID))
        XCTAssertEqual(resource.ownershipState, .external)

        // Release must refuse a reused/pre-existing terminal — and leave it open.
        try await reportDone(taskID: taskID, dispatchID: dispatchID, handle: existing.handle)
        let release = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(release.ok, String(describing: release.error))
        XCTAssertEqual(release.result?.field("state")?.stringValue, "retained")
        XCTAssertEqual(release.result?.field("reason")?.stringValue, "external_terminal")
        let stillLive = await terminalExists(existing.handle)
        XCTAssertTrue(stillLive)
    }

    // MARK: - worker-release / worker-read

    func testReleaseArchivesBeforeCloseAndIsIdempotent() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let handle = try agentHandle(started)
        let fake = try await session(handle)
        await MainActor.run {
            fake.emitOutput("building the thing\nall tests passed\n")
        }
        try await reportDone(taskID: taskID, dispatchID: dispatchID, handle: handle)
        XCTAssertEqual(try store.workerDispatch(dispatchID)?.state, .succeeded)

        let release = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(release.ok, String(describing: release.error))
        XCTAssertEqual(release.result?.field("state")?.stringValue, "released")
        XCTAssertEqual(release.result?.field("processAction")?.stringValue, "closed_agent_terminal")
        XCTAssertEqual(release.result?.field("archive")?.field("source")?.stringValue, "terminal")
        XCTAssertEqual(release.result?.field("archive")?.field("status")?.stringValue, "captured")

        // The archive row was written BEFORE the close, so worker-read still answers.
        let archive = try XCTUnwrap(try store.workerTerminalArchive(dispatchID: dispatchID))
        XCTAssertEqual(archive.kind, .terminalTail)
        XCTAssertTrue(archive.content.contains("all tests passed"))
        let closed = await terminalExists(handle)
        XCTAssertFalse(closed, "release must close the owned agent terminal")

        let read = await call("worker-read", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(read.ok, String(describing: read.error))
        XCTAssertEqual(read.result?.field("archived")?.boolValue, true)
        XCTAssertEqual(read.result?.field("source")?.stringValue, "terminal")
        let lines = read.result?.field("lines")?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(lines.contains("all tests passed"))
        XCTAssertEqual(read.result?.field("status")?.field("terminal")?.stringValue, "archived")

        // Idempotent: a second release reports already_released, changing nothing.
        let again = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(again.ok)
        XCTAssertEqual(again.result?.field("state")?.stringValue, "already_released")
    }

    func testReleaseRefusesUnsettledWorker() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let release = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertFalse(release.ok)
        XCTAssertEqual(release.error?.code, "dispatch_inactive")
    }

    func testRetainHoldsThenReleaseSupersedes() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let handle = try agentHandle(started)
        try await reportDone(taskID: taskID, dispatchID: dispatchID, handle: handle)

        let retain = await call("worker-retain", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(retain.ok, String(describing: retain.error))
        XCTAssertEqual(retain.result?.field("state")?.stringValue, "retained")
        XCTAssertEqual(retain.result?.field("reason")?.stringValue, "user_requested")
        XCTAssertEqual(
            try store.workerTerminalResource(ownerDispatchID: dispatchID)?.releaseState,
            .retained)

        // An explicit release supersedes the user hold.
        let release = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(release.ok, String(describing: release.error))
        XCTAssertEqual(release.result?.field("state")?.stringValue, "released")
    }

    func testWorkerReadLiveOutputIsBoundedWithSource() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let handle = try agentHandle(started)
        let fake = try await session(handle)
        await MainActor.run {
            for index in 1...10 { fake.emitOutput("line \(index)\n") }
        }
        let read = await call("worker-read", [
            "dispatch": .string(dispatchID), "limit": .number(3),
        ])
        XCTAssertTrue(read.ok, String(describing: read.error))
        XCTAssertEqual(read.result?.field("archived")?.boolValue, false)
        XCTAssertEqual(read.result?.field("source")?.stringValue, "terminal")
        XCTAssertEqual(read.result?.field("fallbackReason")?.stringValue, "transcript_unavailable")
        let lines = read.result?.field("lines")?.arrayValue ?? []
        XCTAssertLessThanOrEqual(lines.count, 3)
        XCTAssertNotNil(read.result?.field("latestCursor"))

        let transcript = await call("worker-read", [
            "dispatch": .string(dispatchID), "source": .string("transcript"),
        ])
        XCTAssertEqual(transcript.error?.code, "transcript_required")
    }

    // MARK: - worker-show

    func testWorkerShowAgentWaitThreeStateConvention() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let handle = try agentHandle(started)
        let fake = try await session(handle)

        // Live agent, not waiting on a human: agentWait key PRESENT with null —
        // "looked, found nothing".
        await MainActor.run { fake.emitOSC(["9999", "idle"]) }
        let idleShow = await call("worker-show", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(idleShow.ok, String(describing: idleShow.error))
        let idleObservation = try XCTUnwrap(idleShow.result?.field("observation")?.objectValue)
        XCTAssertEqual(idleObservation["status"]?.stringValue, "live")
        XCTAssertEqual(idleObservation["exactWorker"]?.boolValue, true)
        XCTAssertEqual(idleObservation["agentWait"], JSONValue.null,
                       "a proven-exact live worker with nothing waiting must report agentWait: null")

        // Permission prompt: a proven human-only wait — agentWait is an object.
        await MainActor.run { fake.emitOSC(["9999", "blocked"]) }
        let blockedShow = await call("worker-show", ["dispatch": .string(dispatchID)])
        let blockedObservation = try XCTUnwrap(blockedShow.result?.field("observation")?.objectValue)
        XCTAssertEqual(blockedObservation["agentWait"]?.field("state")?.stringValue, "blocked")
        XCTAssertNotNil(blockedObservation["agentWait"]?.field("evidence")?.stringValue)
    }

    func testWorkerShowOmitsAgentWaitWhenItNeverLooked() async throws {
        // A context-only dispatch to a handle no registry knows: observation is
        // `missing` and agentWait is ABSENT — absent must never read as "not waiting".
        let taskID = try await makeTask()
        let dispatched = try await live.dispatchTask([
            "task": .string(taskID), "to": .string("term_ghost")])
        let dispatchID = try XCTUnwrap(dispatched.field("dispatchId")?.stringValue)

        let show = await call("worker-show", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(show.ok, String(describing: show.error))
        XCTAssertEqual(show.result?.field("worker")?.field("state")?.stringValue, "unsupervised")
        let observation = try XCTUnwrap(show.result?.field("observation")?.objectValue)
        XCTAssertEqual(observation["status"]?.stringValue, "missing")
        XCTAssertNil(observation["agentWait"],
                     "an unobserved worker must omit agentWait entirely (never looked)")

        // Unattached: a starting dispatch with no terminal bound yet.
        let unattachedTask = try await makeTask(spec: "unattached")
        let starting = try store.createStartingWorkerDispatch(taskID: unattachedTask)
        let unattached = await call("worker-show", ["dispatch": .string(starting.dispatch.id)])
        let unattachedObservation = try XCTUnwrap(unattached.result?.field("observation")?.objectValue)
        XCTAssertEqual(unattachedObservation["status"]?.stringValue, "unattached")
        XCTAssertNil(unattachedObservation["agentWait"])
    }

    // MARK: - worker-stop / worker-abandon

    func testWorkerStopClosesOwnedTerminalAndBlocksTask() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let handle = try agentHandle(started)

        let stop = await call("worker-stop", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(stop.ok, String(describing: stop.error))
        XCTAssertEqual(stop.result?.field("state")?.stringValue, "stopped")
        XCTAssertEqual(stop.result?.field("processAction")?.stringValue, "closed_agent_terminal")

        let closed = await terminalExists(handle)
        XCTAssertFalse(closed)
        XCTAssertEqual(try store.dispatchContext(dispatchID)?.status, .failed)
        XCTAssertEqual(try store.task(taskID)?.status, .blocked)

        let again = await call("worker-stop", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(again.ok)
        XCTAssertEqual(again.result?.field("alreadySettled")?.boolValue, true)
        XCTAssertEqual(again.result?.field("state")?.stringValue, "stopped")
    }

    func testWorkerAbandonRetainsProcessesAndParksTask() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let handle = try agentHandle(started)

        let abandon = await call("worker-abandon", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(abandon.ok, String(describing: abandon.error))
        XCTAssertEqual(abandon.result?.field("state")?.stringValue, "abandoned")
        XCTAssertEqual(abandon.result?.field("processAction")?.stringValue, "none")

        // No process was touched: the terminal is still live; the task is parked.
        let stillLive = await terminalExists(handle)
        XCTAssertTrue(stillLive)
        XCTAssertEqual(try store.task(taskID)?.status, .blocked)

        // Release after abandon: identity can no longer be proven — refuse to close.
        let release = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(release.ok)
        XCTAssertEqual(release.result?.field("state")?.stringValue, "retained")
        XCTAssertEqual(release.result?.field("reason")?.stringValue, "identity_unproven")
    }

    // MARK: - worker-list

    func testWorkerListDerivesTerminalStatesAndFilters() async throws {
        let readyTask = try await makeTask(spec: "stays active")
        let active = try await startReadyWorker(taskID: readyTask)
        XCTAssertTrue(active.ok, String(describing: active.error))

        let doneTask = try await makeTask(spec: "gets released")
        let released = try await startReadyWorker(taskID: doneTask)
        let releasedDispatch = try XCTUnwrap(released.result?.field("dispatchId")?.stringValue)
        try await reportDone(taskID: doneTask, dispatchID: releasedDispatch,
                             handle: try agentHandle(released))
        _ = await call("worker-release", ["dispatch": .string(releasedDispatch)])

        let list = await call("worker-list")
        XCTAssertTrue(list.ok, String(describing: list.error))
        let counts = try XCTUnwrap(list.result?.field("counts")?.objectValue)
        XCTAssertEqual(counts["active"]?.numberValue, 1)
        XCTAssertEqual(counts["released"]?.numberValue, 1)

        let filtered = await call("worker-list", ["terminal-state": .string("released")])
        let workers = try XCTUnwrap(filtered.result?.field("workers")?.arrayValue)
        XCTAssertEqual(workers.count, 1)
        XCTAssertEqual(workers.first?.field("dispatchId")?.stringValue, releasedDispatch)
        XCTAssertEqual(workers.first?.field("terminalState")?.stringValue, "released")
    }

    // MARK: - end-to-end wiring

    func testRuntimeHostRoutesWorkerVerbs() async throws {
        // The assembly registers the worker verbs on the same registry the socket
        // serves; worker-list is the cheapest proof of wiring (no PTY needed).
        let root = URL(fileURLWithPath: "/tmp/o-wkr-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try await MainActor.run {
            try OrchardRuntimeHost(fileManager: ScopedFileManager(root: root),
                                   terminalFactory: { _, _ in ScriptedTerminalSession() })
        }
        let list = await host.inMemory.perform(RPCRequest(method: "worker-list"))
        XCTAssertTrue(list.ok, String(describing: list.error))
        XCTAssertEqual(list.result?.field("workers")?.arrayValue?.count, 0)

        let show = await host.inMemory.perform(RPCRequest(
            method: "worker-show", params: .object(["dispatch": .string("ctx_missing")])))
        XCTAssertFalse(show.ok)
        XCTAssertEqual(show.error?.code, "dispatch_not_found")
        await MainActor.run { host.shutdown() }
    }
}
