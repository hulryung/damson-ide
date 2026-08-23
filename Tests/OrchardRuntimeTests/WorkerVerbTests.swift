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
        var transcriptResolution: WorkerRuntimeContext.ProviderTranscriptResolution =
            .unavailable(reason: "provider_session_unavailable")
        /// Worktree ids the rollback seam was asked to delete, in order.
        var rollbackRequests: [String] = []
        /// What the stub workspace layer's unforced delete reports. `nil` = a clean
        /// worktree that removes; a value = the preflight refusal it reports instead.
        var rollbackRefusal: String?

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
    /// The context `setUp` wired; kept so a test can rebuild the handler with one
    /// field changed (e.g. a different injected CLI command).
    private var runtimeContext: WorkerRuntimeContext!

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
            resolveProviderTranscript: { _, _ in
                await harness.transcriptResolution
            },
            closeTerminal: { handle in
                try await harness.service.close(handle: handle)
            },
            rollbackWorktree: { worktreeID in
                await MainActor.run {
                    harness.rollbackRequests.append(worktreeID)
                    if let refusal = harness.rollbackRefusal {
                        return .retained(reason: refusal)
                    }
                    harness.workspaces.removeValue(forKey: worktreeID)
                    return .removed
                }
            })
        runtimeContext = context
        handler = WorkerCommandHandler(store: live, runtime: context)
    }

    override func tearDown() async throws {
        store?.close()
        store = nil
        live = nil
        handler = nil
        runtimeContext = nil
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

    /// The capability secret worker-start injected into this terminal's preamble —
    /// exactly what a real worker reads back out of its TASK block (T11: lifecycle
    /// sends without it are rejected).
    private func injectedCapability(handle: String) async throws -> String {
        let text = try await session(handle).writtenText
        let marker = "--dispatch-capability "
        let markerRange = try XCTUnwrap(text.range(of: marker),
                                        "no --dispatch-capability in the injected preamble")
        let secret = text[markerRange.upperBound...]
            .prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        XCTAssertTrue(secret.hasPrefix("dcap_"), "unexpected capability shape: \(secret)")
        return String(secret)
    }

    private func reportDone(taskID: String, dispatchID: String, handle: String,
                            outcome: String = "succeeded") async throws {
        _ = try await live.send([
            "from": .string(handle),
            "dispatch-capability": .string(try await injectedCapability(handle: handle)),
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

    // MARK: - T35: engine alias, rollback, injected CLI command

    /// dogfood-1 finding 1: `--agent claude` is the spelling every surface advertises
    /// and the one a coordinator reaches for. It must launch the `claude-code` engine
    /// rather than dying at terminal_create, and the terminal must record the
    /// canonical id.
    func testWorkerStartAcceptsTheClaudeEngineAlias() async throws {
        let taskID = try await makeTask()
        let response = try await startReadyWorker(
            taskID: taskID, extra: ["agent": .string("claude")])
        XCTAssertTrue(response.ok, String(describing: response.error))
        XCTAssertEqual(response.result?.field("state")?.stringValue, "ready")

        let handle = try agentHandle(response)
        let engineID = await MainActor.run { [terminalHarness] in
            try? terminalHarness!.service.summary(handle: handle).engine
        }
        XCTAssertEqual(engineID, "claude-code",
                       "the alias must be canonicalized before it is persisted")
        // The receipt still echoes what the caller asked for.
        XCTAssertEqual(response.result?.field("launch")?.field("agent")?.stringValue, "claude")
    }

    // MARK: - T39: supervised dispatch stops at the host boundary

    /// A remote workspace has no `orchard` binary, so a worker there could not send
    /// `worker_done`, heartbeat, or answer a blocking question — the duties a dispatch
    /// *is*. The refusal is typed and lands before a dispatch row exists, so a
    /// coordinator gets a clean "no", not a half-open dispatch it must abandon.
    func testWorkerStartRefusesARemoteWorkspaceTypedAndCreatesNothing() async throws {
        let taskID = try await makeTask()
        await MainActor.run { [terminalHarness] in
            terminalHarness!.workspaces["repo::/srv/wt/apricot"] = WorkerWorktreeReceipt(
                id: "repo::/srv/wt/apricot", instanceId: UUID().uuidString,
                path: "/srv/wt/apricot", displayName: "apricot", hostId: "ssh:build")
        }
        let response = await call("worker-start", [
            "task": .string(taskID),
            "agent": .string("claude-code"),
            "worktree": .string("repo::/srv/wt/apricot"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "remote_unsupported")
        let message = try XCTUnwrap(response.error?.message)
        // It names what is missing and what does work instead: a handoff-style remote
        // agent pane, which is a real thing a coordinator can still use.
        XCTAssertTrue(message.contains("build"), message)
        XCTAssertTrue(message.contains("orchard CLI"), message)
        XCTAssertTrue(message.contains("terminal create --worktree repo::/srv/wt/apricot"), message)
        // Nothing was created — no worker dispatch row, no pane.
        let workers = try await live.workerList([:])
        XCTAssertEqual(workers.field("workers")?.arrayValue?.count ?? 0, 0)
        let panes = await MainActor.run { [terminalHarness] in terminalHarness!.service.list() }
        XCTAssertTrue(panes.isEmpty)
    }

    /// The same rule by the other door: adopting a remote agent pane as a supervised
    /// worker would bind lifecycle authority to a process that cannot discharge it.
    func testWorkerStartRefusesAnExistingRemoteAgentPane() async throws {
        let taskID = try await makeTask()
        let handle = try await MainActor.run { [terminalHarness] in
            try terminalHarness!.service.create(
                worktreeId: "repo::/srv/wt/apricot", cwd: nil, engineID: "claude-code",
                prompt: "", title: "apricot", executionHostId: "ssh:build",
                statusDetection: .hooks(tunnelPort: 47110)).handle
        }
        let response = await call("worker-start", [
            "task": .string(taskID),
            "terminal": .string(handle),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "remote_unsupported")
        XCTAssertTrue(response.error?.message.contains("build") ?? false,
                      response.error?.message ?? "")
    }

    /// The guard must not catch local work: a local workspace with the same shape
    /// starts normally.
    func testWorkerStartStillAcceptsALocalWorkspace() async throws {
        let taskID = try await makeTask()
        await MainActor.run { [terminalHarness] in
            terminalHarness!.workspaces["repo::/wt/local"] = WorkerWorktreeReceipt(
                id: "repo::/wt/local", instanceId: UUID().uuidString,
                path: "/wt/local", displayName: "local", hostId: "local")
        }
        let response = try await startReadyWorker(
            taskID: taskID, extra: ["worktree": .string("repo::/wt/local")])
        XCTAssertTrue(response.ok, String(describing: response.error))
    }

    func testUnknownEngineStillFailsTypedAtTerminalCreate() async throws {
        let taskID = try await makeTask()
        let response = await call("worker-start", [
            "task": .string(taskID),
            "agent": .string("clod"),
            "worktree": .string("new-top-level"),
            "repo": .string("demo"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "worker_start_failed")
        XCTAssertEqual(response.error?.data?.field("failedStage")?.stringValue, "terminal_create")
    }

    /// dogfood-1 finding 1 (second half): the launch that died at terminal_create left
    /// a worktree behind and a cleanup chore. A definitively-failed start now removes
    /// the fresh worktree it created, reports the rollback, and lists no residual.
    func testFailedWorkerStartRollsBackItsFreshWorktree() async throws {
        let taskID = try await makeTask()
        let response = await call("worker-start", [
            "task": .string(taskID),
            "agent": .string("clod"),
            "worktree": .string("new-top-level"),
            "repo": .string("demo"),
        ])
        XCTAssertFalse(response.ok)
        let receipt = try XCTUnwrap(response.error?.data)
        XCTAssertEqual(receipt.field("state")?.stringValue, "failed")

        let rollback = try XCTUnwrap(receipt.field("rollback")?.arrayValue)
        XCTAssertEqual(rollback.count, 1)
        XCTAssertEqual(rollback.first?.field("kind")?.stringValue, "worktree")
        XCTAssertEqual(rollback.first?.field("action")?.stringValue, "removed")
        XCTAssertEqual(receipt.field("residualResources")?.arrayValue?.count, 0,
                       "a removed worktree is not a residual")

        let created = try XCTUnwrap(receipt.field("effects")?.arrayValue?
            .first { $0.field("kind")?.stringValue == "worktree" }?
            .field("id")?.stringValue)
        let requested = await MainActor.run { [terminalHarness] in terminalHarness!.rollbackRequests }
        XCTAssertEqual(requested, [created])

        // The dispatch row is settled with the reason, not left starting.
        let dispatchID = try XCTUnwrap(receipt.field("dispatchId")?.stringValue)
        let worker = try XCTUnwrap(try store.workerDispatch(dispatchID))
        XCTAssertEqual(worker.state, .failed)
        XCTAssertTrue((worker.lastError ?? "").contains("unknown engine"),
                      "the dispatch must record why it failed: \(worker.lastError ?? "nil")")
        XCTAssertEqual(try store.dispatchContext(dispatchID)?.status, .failed)
        XCTAssertEqual(Self.residualKinds(worker.residualResources), [])
    }

    /// Rollback is never forced. A worktree the workspace preflight refuses to delete
    /// stays a residual — with the refusal reason and the exact cleanup command.
    func testFailedWorkerStartRetainsAWorktreeItCannotSafelyRemove() async throws {
        await MainActor.run { terminalHarness.rollbackRefusal = "worktree_dirty: 1 uncommitted file" }
        let taskID = try await makeTask()
        let response = await call("worker-start", [
            "task": .string(taskID),
            "agent": .string("clod"),
            "worktree": .string("new-top-level"),
            "repo": .string("demo"),
        ])
        let receipt = try XCTUnwrap(response.error?.data)
        XCTAssertEqual(receipt.field("rollback")?.arrayValue?.first?.field("action")?.stringValue,
                       "retained")
        let residuals = try XCTUnwrap(receipt.field("residualResources")?.arrayValue)
        XCTAssertEqual(residuals.count, 1)
        let residual = try XCTUnwrap(residuals.first)
        XCTAssertEqual(residual.field("kind")?.stringValue, "worktree")
        XCTAssertEqual(residual.field("retainedReason")?.stringValue,
                       "worktree_dirty: 1 uncommitted file")
        let id = try XCTUnwrap(residual.field("id")?.stringValue)
        XCTAssertEqual(residual.field("cleanupCommand")?.stringValue,
                       "orchard worktree rm --worktree '\(id)' --json")
    }

    /// A worktree that already has an agent pane inside it is never auto-deleted: the
    /// process's cwd lives there. It is retained with that as the reason.
    func testRollbackSkipsAWorktreeThatAlreadyHasAnAgentTerminal() async throws {
        let taskID = try await makeTask()
        let response = await call("worker-start", [
            "task": .string(taskID),
            "agent": .string("claude-code"),
            "worktree": .string("new-top-level"),
            "repo": .string("demo"),
            "timeout-ms": .number(300),      // readiness never satisfied
        ])
        XCTAssertFalse(response.ok)
        let receipt = try XCTUnwrap(response.error?.data)
        XCTAssertEqual(receipt.field("failedStage")?.stringValue, "agent_readiness")
        let requested = await MainActor.run { [terminalHarness] in terminalHarness!.rollbackRequests }
        XCTAssertEqual(requested, [], "a worktree with a live pane must not be deleted")
        XCTAssertEqual(receipt.field("rollback")?.arrayValue?.first?.field("reason")?.stringValue,
                       "agent_terminal_created_in_worktree")
        let residualKinds = receipt.field("residualResources")?.arrayValue?
            .compactMap { $0.field("kind")?.stringValue }
        XCTAssertEqual(residualKinds, ["worktree", "terminal"])
    }

    /// dogfood-1 finding 2: the worker followed the preamble literally, ran a bare
    /// `orchard`, and got `command not found`. Every lifecycle example must carry the
    /// runtime's resolved command string.
    func testInjectedPreambleUsesTheRuntimeCLICommandNotBareOrchard() async throws {
        let absolute = "/Users/dkkang/dev/damson-ide/.build/release/orchard"
        var runtime = runtimeContext!
        runtime.cliCommand = absolute
        handler = WorkerCommandHandler(store: live, runtime: runtime)

        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let handle = try agentHandle(started)
        let typed = try await session(handle).writtenText

        XCTAssertTrue(typed.contains("\(absolute) send --from "),
                      "worker_done must be shown as the absolute command")
        XCTAssertTrue(typed.contains("\(absolute) ask --from "))
        XCTAssertTrue(typed.contains("$ORCHARD_CLI_COMMAND"),
                      "the preamble must point at the env var carrying the same path")
        for line in typed.split(separator: "\n") {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).hasPrefix("orchard "),
                           "a lifecycle example still starts with a bare orchard: \(line)")
        }
    }

    static func residualKinds(_ encoded: String?) -> [String] {
        guard let encoded, let data = encoded.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let rows = value.arrayValue else { return [] }
        return rows.compactMap { $0.field("kind")?.stringValue }
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
        XCTAssertEqual(read.result?.field("fallbackReason")?.stringValue,
                       "provider_session_unavailable")
        let lines = read.result?.field("lines")?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(lines.contains("all tests passed"))
        XCTAssertEqual(read.result?.field("status")?.field("terminal")?.stringValue, "archived")

        // T35: a transcript request against a terminal-tail archive fails typed. The
        // archive is real output, but it is not the thing the caller asked for.
        let requestedTranscript = await call("worker-read", [
            "dispatch": .string(dispatchID), "source": .string("transcript"),
        ])
        XCTAssertFalse(requestedTranscript.ok)
        let refusal = try XCTUnwrap(requestedTranscript.error)
        XCTAssertEqual(refusal.code, "transcript_unavailable")
        XCTAssertEqual(refusal.data?.field("reason")?.stringValue, "provider_session_unavailable")
        XCTAssertEqual(refusal.data?.field("archived")?.boolValue, true)
        XCTAssertEqual(refusal.data?.field("availableSource")?.stringValue, "terminal")
        let recovery = refusal.data?.field("nextCommands")?.arrayValue?
            .compactMap(\.stringValue) ?? []
        XCTAssertTrue(recovery.contains { $0.contains("--source terminal") },
                      "the refusal must name the read that would answer: \(recovery)")

        // Idempotent: a second release reports already_released, changing nothing.
        let again = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(again.ok)
        XCTAssertEqual(again.result?.field("state")?.stringValue, "already_released")
    }

    func testReleasePinsProviderTranscriptAndReadPrefersIt() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let handle = try agentHandle(started)
        await MainActor.run {
            terminalHarness.transcriptResolution = .resolved(
                content: #"{"type":"assistant","message":"pinned answer"}"#,
                path: "/tmp/claude/session.jsonl", truncated: false)
        }
        try await reportDone(taskID: taskID, dispatchID: dispatchID, handle: handle)

        let release = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(release.ok, String(describing: release.error))
        XCTAssertEqual(release.result?.field("archive")?.field("source")?.stringValue,
                       "transcript")
        XCTAssertEqual(try store.workerTerminalArchive(dispatchID: dispatchID)?.kind,
                       .transcriptPin)

        let read = await call("worker-read", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(read.ok, String(describing: read.error))
        XCTAssertEqual(read.result?.field("source")?.stringValue, "transcript")
        XCTAssertEqual(read.result?.field("content")?.stringValue,
                       #"{"type":"assistant","message":"pinned answer"}"#)
        XCTAssertEqual(read.result?.field("transcriptPath")?.stringValue,
                       "/tmp/claude/session.jsonl")
    }

    func testClaudeTranscriptResolverUsesHookSessionAndEncodedCWD() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-transcript-\(UUID().uuidString)", isDirectory: true)
        let summary = try await terminalHarness.service.create(
            worktreeId: "repo::/tmp/project", cwd: "/tmp/my project",
            engineID: "claude-code", prompt: "", title: "Claude")
        try await terminalHarness.service.applyHookStatus(
            handle: summary.handle,
            fields: HookStatusFields(providerSessionID: "session-123"))
        let directory = home.appendingPathComponent(
            ".claude/projects/-tmp-my project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("session-123.jsonl")
        try Data("one\ntwo\nthree\n".utf8).write(to: transcript)

        let resolution = await WorkerRuntimeContext.resolveClaudeTranscript(
            terminalHarness.service, handle: summary.handle,
            maximumBytes: 8, homeDirectory: home)
        XCTAssertEqual(resolution, .resolved(
            content: "three\n", path: transcript.path, truncated: true))
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
        // `auto` on a live worker keeps the bounded, cursor-paged terminal shape and
        // names why it is not a transcript (T35): nothing is pinned before release.
        XCTAssertEqual(read.result?.field("fallbackReason")?.stringValue,
                       "provider_transcript_not_pinned")
        let lines = read.result?.field("lines")?.arrayValue ?? []
        XCTAssertLessThanOrEqual(lines.count, 3)
        XCTAssertNotNil(read.result?.field("latestCursor"))

        let transcript = await call("worker-read", [
            "dispatch": .string(dispatchID), "source": .string("transcript"),
        ])
        XCTAssertFalse(transcript.ok, "an unpinnable transcript must not answer as terminal output")
        XCTAssertEqual(transcript.error?.code, "transcript_unavailable")
        XCTAssertEqual(transcript.error?.data?.field("reason")?.stringValue,
                       "provider_session_unavailable")
        XCTAssertEqual(transcript.error?.data?.field("archived")?.boolValue, false)

        // …and `--source terminal` is never second-guessed.
        let terminalOnly = await call("worker-read", [
            "dispatch": .string(dispatchID), "source": .string("terminal"),
        ])
        XCTAssertTrue(terminalOnly.ok, String(describing: terminalOnly.error))
        XCTAssertEqual(terminalOnly.result?.field("source")?.stringValue, "terminal")
        XCTAssertNil(terminalOnly.result?.field("fallbackReason"))
    }

    /// T35: a live worker whose provider session IS resolvable answers a transcript
    /// request with the transcript — no release required.
    func testWorkerReadLiveTranscriptIsServedWhenResolvable() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        await MainActor.run {
            terminalHarness.transcriptResolution = .resolved(
                content: #"{"type":"assistant","message":"live answer"}"#,
                path: "/tmp/claude/live.jsonl", truncated: false)
        }
        let read = await call("worker-read", [
            "dispatch": .string(dispatchID), "source": .string("transcript"),
        ])
        XCTAssertTrue(read.ok, String(describing: read.error))
        XCTAssertEqual(read.result?.field("source")?.stringValue, "transcript")
        XCTAssertEqual(read.result?.field("archived")?.boolValue, false)
        XCTAssertEqual(read.result?.field("content")?.stringValue,
                       #"{"type":"assistant","message":"live answer"}"#)
        XCTAssertEqual(read.result?.field("transcriptPath")?.stringValue, "/tmp/claude/live.jsonl")

        // `auto` keeps the paged terminal shape even now that a transcript could be
        // resolved: the same command must not sometimes return a whole document.
        let auto = await call("worker-read", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(auto.ok, String(describing: auto.error))
        XCTAssertEqual(auto.result?.field("source")?.stringValue, "terminal")
        XCTAssertNotNil(auto.result?.field("lines"))
        XCTAssertEqual(auto.result?.field("fallbackReason")?.stringValue,
                       "provider_transcript_not_pinned")
    }

    /// T35 (dogfood-1 finding 4): the released archive keeps two faces — readable
    /// text for humans and the untouched capture for evidence.
    func testReleaseArchivesReadableTextAlongsideTheRawCapture() async throws {
        let taskID = try await makeTask()
        let started = try await startReadyWorker(taskID: taskID)
        let dispatchID = try XCTUnwrap(started.result?.field("dispatchId")?.stringValue)
        let handle = try agentHandle(started)
        let fake = try await session(handle)

        // A miniature repaint stream: box frame, separator rules, spinner frames, the
        // same status bar redrawn with a ticking counter, and one real result line.
        let noise = [
            "╭──────────────────────────────╮",
            "│ ✻ Levitating… (3s · ↓ 12 tokens)",
            "╰──────────────────────────────╯",
            "──────────────────────────────",
            "⏵⏵ bypass permissions on · ⎇ main · $0.01",
            "✢ 41",
            "all tests passed",
            "──────────────────────────────",
            "⏵⏵ bypass permissions on · ⎇ main · $0.02",
            "✳ Levitating… (4s · ↓ 30 tokens)",
        ]
        await MainActor.run { fake.emitOutput(noise.joined(separator: "\n") + "\n") }
        try await reportDone(taskID: taskID, dispatchID: dispatchID, handle: handle)
        let release = await call("worker-release", ["dispatch": .string(dispatchID)])
        XCTAssertTrue(release.ok, String(describing: release.error))
        let archiveSummary = try XCTUnwrap(release.result?.field("archive"))
        XCTAssertEqual(archiveSummary.field("status")?.stringValue, "captured")
        let rawCount = try XCTUnwrap(archiveSummary.field("rawLineCount")?.numberValue)
        let readableCount = try XCTUnwrap(archiveSummary.field("readableLineCount")?.numberValue)
        XCTAssertLessThan(readableCount, rawCount)

        // The default read is the readable face.
        let read = await call("worker-read", ["dispatch": .string(dispatchID),
                                              "limit": .number(500)])
        XCTAssertTrue(read.ok, String(describing: read.error))
        XCTAssertEqual(read.result?.field("raw")?.boolValue, false)
        let clean = read.result?.field("lines")?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(clean.contains("all tests passed"))
        XCTAssertFalse(clean.contains { $0.contains("✻") || $0.contains("✳") },
                       "spinner chrome reached the readable archive: \(clean)")
        XCTAssertFalse(clean.contains { $0.hasPrefix("──") })
        XCTAssertEqual(clean.filter { $0.contains("bypass permissions") }.count, 1,
                       "the redrawn status bar was not collapsed: \(clean)")
        let chrome = try XCTUnwrap(read.result?.field("chromeStripped"))
        XCTAssertGreaterThan(try XCTUnwrap(chrome.field("separatorLines")?.numberValue), 0)
        XCTAssertGreaterThan(try XCTUnwrap(chrome.field("spinnerLines")?.numberValue), 0)

        // …and --raw still serves every captured byte.
        let raw = await call("worker-read", ["dispatch": .string(dispatchID),
                                             "raw": .bool(true), "limit": .number(500)])
        XCTAssertTrue(raw.ok, String(describing: raw.error))
        XCTAssertEqual(raw.result?.field("raw")?.boolValue, true)
        let rawLines = raw.result?.field("lines")?.arrayValue?.compactMap(\.stringValue) ?? []
        for line in noise {
            XCTAssertTrue(rawLines.contains(line), "the raw capture lost: \(line)")
        }
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
