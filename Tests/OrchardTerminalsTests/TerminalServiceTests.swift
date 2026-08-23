import XCTest
import OrchardCore
@testable import OrchardTerminals

/// Exercises the T3 terminal service end to end against scripted sessions: the
/// two-identity registry, two-source reads, the verified injection pipeline with its
/// typed refusals, the tui-idle/exit wait rules, and the agent-status stream.
@MainActor
final class TerminalServiceTests: XCTestCase {

    /// Service + captured sessions, with detector/pipeline timing shrunk so the
    /// verified pipeline and debounces run in milliseconds.
    private final class Harness {
        var sessions: [String: ScriptedTerminalSession] = [:]   // by handle
        private(set) var service: TerminalService!

        @MainActor
        init() {
            var detector = ReadinessDetector.Config()
            detector.idleDebounce = 1
            detector.spawnFloor = 0
            var pipeline = SendPipelineConfig()
            pipeline.submitDelay = 0.05
            pipeline.verifyTimeout = 0.5
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
    }

    private var harness: Harness!
    private var service: TerminalService { harness.service }

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    private func session(_ handle: String) -> ScriptedTerminalSession {
        harness.sessions[handle]!
    }

    /// Poll the main actor until `condition` holds (async state changes hop through
    /// Tasks, so tests observe them with a bounded wait, never a bare sleep).
    private func waitUntil(_ what: String, timeout: TimeInterval = 2,
                           condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Registry & identity

    func testCreateListAndIdentityShape() throws {
        let summary = try service.create(worktreeId: "repo::wt1", engineID: "claude-code",
                                         title: "coordinator")
        XCTAssertTrue(summary.handle.hasPrefix("term_"))
        XCTAssertTrue(summary.paneKey.contains(":"), "paneKey is '<tabId>:<leafUUID>'")
        XCTAssertEqual(summary.incarnation, 1)
        XCTAssertEqual(summary.worktreeId, "repo::wt1")
        XCTAssertEqual(summary.engine, "claude-code")
        XCTAssertTrue(summary.connected)

        _ = try service.create(worktreeId: "repo::wt2", engineID: "shell")
        XCTAssertEqual(service.list().count, 2)
        XCTAssertEqual(service.list(worktreeId: "repo::wt1").map(\.handle), [summary.handle])
        XCTAssertEqual(service.list(worktreeId: "repo::none").count, 0)
    }

    func testUnknownEngineIsTyped() {
        XCTAssertThrowsError(try service.create(engineID: "hal9000")) { error in
            XCTAssertEqual((error as? TerminalServiceError)?.code, "unknown_engine")
        }
    }

    func testRemintMakesOldHandleStaleWithReplacement() throws {
        let created = try service.create(engineID: "shell")
        let reminted = try service.remintHandle(paneKey: created.paneKey)
        XCTAssertNotEqual(reminted.handle, created.handle)
        XCTAssertEqual(reminted.paneKey, created.paneKey, "paneKey is the durable identity")
        XCTAssertEqual(reminted.incarnation, 1, "remint does not touch the process")

        // The old handle answers stale — with the replacement, so a caller can re-list
        // and continue. It must NOT answer not-found.
        XCTAssertThrowsError(try service.read(handle: created.handle)) { error in
            guard case .handleStale(_, let replacement)? = error as? TerminalServiceError else {
                return XCTFail("expected handleStale, got \(error)")
            }
            XCTAssertEqual(replacement, reminted.handle)
        }
        XCTAssertNoThrow(try service.read(handle: reminted.handle))
    }

    func testRespawnIncrementsIncarnationAndKeepsStream() throws {
        let created = try service.create(engineID: "shell")
        session(created.handle).emitOutput("first incarnation\n")
        let respawned = try service.respawn(paneKey: created.paneKey)
        XCTAssertEqual(respawned.incarnation, 2)
        XCTAssertNotEqual(respawned.handle, created.handle)

        harness.sessions[respawned.handle]!.emitOutput("second incarnation\n")
        let read = try service.read(handle: respawned.handle)
        XCTAssertTrue(read.lines.contains("first incarnation"),
                      "the pane's stream survives the respawn")
        XCTAssertTrue(read.lines.contains("second incarnation"))
        XCTAssertThrowsError(try service.read(handle: created.handle)) { error in
            XCTAssertEqual((error as? TerminalServiceError)?.code, "terminal_handle_stale")
        }
    }

    func testCloseTerminatesAndForgets() throws {
        let created = try service.create(engineID: "shell")
        let fake = session(created.handle)
        try service.close(handle: created.handle)
        XCTAssertTrue(fake.processExited)
        XCTAssertThrowsError(try service.read(handle: created.handle)) { error in
            XCTAssertEqual((error as? TerminalServiceError)?.code, "terminal_not_found")
        }
        XCTAssertEqual(service.list().count, 0)
    }

    func testRenameUpdatesTitle() throws {
        let created = try service.create(engineID: "shell", title: "old")
        let renamed = try service.rename(handle: created.handle, title: "new")
        XCTAssertEqual(renamed.title, "new")
    }

    // MARK: - Read (two sources)

    func testReadStreamAndScreenCarrySource() throws {
        let created = try service.create(engineID: "shell")
        let fake = session(created.handle)
        fake.emitOutput("build ok\n")
        fake.showScreen(["$ make", "build ok", "$ "])

        let stream = try service.read(handle: created.handle)
        XCTAssertEqual(stream.source, .stream)
        XCTAssertTrue(stream.lines.contains("build ok"))
        XCTAssertNotNil(stream.nextCursor)

        let screen = try service.read(handle: created.handle, screen: true)
        XCTAssertEqual(screen.source, .screen)
        XCTAssertEqual(screen.lines, ["$ make", "build ok", "$ "])
        XCTAssertNil(screen.nextCursor, "a rendered frame has no cursor")
    }

    func testReadStreamCursorFollowsNewOutput() throws {
        let created = try service.create(engineID: "shell")
        let fake = session(created.handle)
        fake.emitOutput("one\n")
        let first = try service.read(handle: created.handle, cursor: 0)
        fake.emitOutput("two\n")
        let second = try service.read(handle: created.handle, cursor: first.nextCursor)
        XCTAssertEqual(second.lines.filter { !$0.isEmpty }, ["two"])
    }

    func testListPreviewIsStreamTail() throws {
        let created = try service.create(engineID: "shell")
        session(created.handle).emitOutput("hello world\n")
        XCTAssertEqual(service.list().first?.preview, "hello world")
        XCTAssertNotNil(service.list().first?.lastOutputAt)
    }

    // MARK: - Send: guard refusals

    func testSendToShellWithGuardRefusesNoAgent() async throws {
        let created = try service.create(engineID: "shell")
        let result = try await service.send(handle: created.handle, text: "rm -rf /",
                                            enter: true, requireAgent: true)
        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.refusedReason, .noAgent)
        XCTAssertEqual(session(created.handle).written.count, 0, "a refusal writes nothing")
    }

    func testSendIntoPermissionPromptRefuses() async throws {
        let created = try service.create(engineID: "claude-code")
        session(created.handle).emitOSC(["9999", "blocked"])   // Tier-2: approval gate
        let result = try await service.send(handle: created.handle, text: "yes do it",
                                            enter: true)
        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.refusedReason, .permission,
                       "typing into a pending approval must be refused, not delivered")
    }

    func testSendToExitedTerminalThrowsTyped() async throws {
        let created = try service.create(engineID: "shell")
        session(created.handle).exit(code: 0)
        do {
            _ = try await service.send(handle: created.handle, text: "hi")
            XCTFail("expected terminal_exited")
        } catch let error as TerminalServiceError {
            XCTAssertEqual(error.code, "terminal_exited")
        }
    }

    // MARK: - Send: the verified injection pipeline

    func testVerifiedSendSanitizesFramesAndSubmits() async throws {
        let created = try service.create(engineID: "claude-code")
        let fake = session(created.handle)
        fake.emitOSC(["9999", "idle"])
        XCTAssertEqual(try service.agentStatus(handle: created.handle).projection, .idle)

        async let pending = service.send(handle: created.handle,
                                         text: "fix the \u{1B}[31mbug\u{1B}[0m",
                                         enter: true)
        // Let the pipeline type + submit, then report the turn started (Tier-2 hook).
        try await waitUntil("submit CR written") { fake.writtenText.contains("\r") }
        fake.emitOSC(["9999", "working"])
        let result = try await pending

        XCTAssertTrue(result.accepted)
        let typed = fake.writtenText
        XCTAssertFalse(typed.contains("\u{1B}[31m"), "raw ESC must never reach the PTY")
        XCTAssertTrue(typed.contains("fix the <ESC>[31mbug<ESC>[0m"), typed)
        XCTAssertTrue(typed.contains("\u{1B}[200~"), "bracketed-paste open frame")
        XCTAssertTrue(typed.contains("\u{1B}[201~"), "bracketed-paste close frame")
        let pasteClose = typed.range(of: "\u{1B}[201~")!
        XCTAssertTrue(typed[pasteClose.upperBound...].contains("\r"),
                      "the submit CR comes after the paste frame closes")
    }

    func testVerifiedSendStallsWhenAgentNeverLeavesIdle() async throws {
        let created = try service.create(engineID: "claude-code")
        session(created.handle).emitOSC(["9999", "idle"])
        do {
            _ = try await service.send(handle: created.handle, text: "hello", enter: true)
            XCTFail("expected agent_prompt_stalled")
        } catch let error as TerminalServiceError {
            XCTAssertEqual(error.code, "agent_prompt_stalled")
        }
    }

    func testConcurrentSendsSerializePerPTY() async throws {
        let created = try service.create(engineID: "claude-code")
        let fake = session(created.handle)
        let first = String(repeating: "a", count: 2000)   // forces multiple chunks
        let second = String(repeating: "b", count: 2000)
        async let sendA = service.send(handle: created.handle, text: first)
        async let sendB = service.send(handle: created.handle, text: second)
        _ = try await (sendA, sendB)
        let typed = fake.writtenText
        // Whichever send won the gate, its chunks must all land before the other's.
        let lastA = typed.range(of: "a", options: .backwards)!.lowerBound
        let firstA = typed.range(of: "a")!.lowerBound
        let lastB = typed.range(of: "b", options: .backwards)!.lowerBound
        let firstB = typed.range(of: "b")!.lowerBound
        XCTAssertTrue(lastA < firstB || lastB < firstA,
                      "chunked writes must not interleave across sends")
    }

    // MARK: - Initial prompt delivery

    func testTypeWhenIdleEngineGetsPromptExactlyOnce() async throws {
        let created = try service.create(engineID: "claude-code", prompt: "do the task")
        let fake = session(created.handle)
        fake.emitOSC(["9999", "idle"])
        try await waitUntil("prompt typed") { fake.writtenText.contains("do the task") }
        fake.emitOSC(["9999", "working"])

        // Every later return to idle must NOT re-type the prompt.
        fake.emitOSC(["9999", "idle"])
        try await Task.sleep(nanoseconds: 150_000_000)
        let occurrences = fake.writtenText.components(separatedBy: "do the task").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    // MARK: - Wait

    func testWaitTuiIdleFastPathsOnLastStatus() async throws {
        let created = try service.create(engineID: "claude-code")
        session(created.handle).emitOSC(["9999", "idle"])
        let result = try await service.wait(handle: created.handle, for: .tuiIdle,
                                            timeout: 1)
        XCTAssertTrue(result.satisfied)
        XCTAssertFalse(result.timedOut)
        // The fast path must consume without clearing: a second waiter fast-paths too.
        let again = try await service.wait(handle: created.handle, for: .tuiIdle, timeout: 1)
        XCTAssertTrue(again.satisfied)
    }

    func testWaitTuiIdleResolvesOnTransitionToIdle() async throws {
        let created = try service.create(engineID: "claude-code")
        let fake = session(created.handle)
        fake.emitOSC(["9999", "working"])
        async let pending = service.wait(handle: created.handle, for: .tuiIdle, timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.emitOSC(["9999", "idle"])
        let result = try await pending
        XCTAssertTrue(result.satisfied)
        XCTAssertEqual(result.agentState, .idle)
    }

    func testWaitTuiIdleIsNotSatisfiedByPermission() async throws {
        let created = try service.create(engineID: "claude-code")
        let fake = session(created.handle)
        fake.emitOSC(["9999", "working"])
        async let pending = service.wait(handle: created.handle, for: .tuiIdle,
                                         timeout: 0.3)
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.emitOSC(["9999", "blocked"])   // permission ≠ idle
        let result = try await pending
        XCTAssertFalse(result.satisfied)
        XCTAssertTrue(result.timedOut, "a permission prompt must time the waiter out, not satisfy it")
        XCTAssertEqual(result.agentState, .permission)
    }

    func testWaitTuiIdleRejectsOnProcessExit() async throws {
        let created = try service.create(engineID: "claude-code")
        let fake = session(created.handle)
        fake.emitOSC(["9999", "working"])
        async let pending = service.wait(handle: created.handle, for: .tuiIdle, timeout: 5)
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.exit(code: 1)
        do {
            _ = try await pending
            XCTFail("expected terminal_exited")
        } catch let error as TerminalServiceError {
            XCTAssertEqual(error.code, "terminal_exited")
        }
    }

    func testWaitForExitResolvesWithCode() async throws {
        let created = try service.create(engineID: "shell")
        let fake = session(created.handle)
        async let pending = service.wait(handle: created.handle, for: .exit, timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.exit(code: 3)
        let result = try await pending
        XCTAssertTrue(result.satisfied)
        XCTAssertEqual(result.exitCode, 3)

        // Fast path once already exited.
        let again = try await service.wait(handle: created.handle, for: .exit, timeout: 1)
        XCTAssertTrue(again.satisfied)
    }

    // MARK: - Agent status stream

    func testStatusStreamEmitsBaselineAndTransitions() async throws {
        let created = try service.create(worktreeId: "repo::wt", engineID: "claude-code")
        let fake = session(created.handle)
        let stream = try service.agentStatusUpdates(handle: created.handle)
        var iterator = stream.makeAsyncIterator()

        let baseline = await iterator.next()
        XCTAssertEqual(baseline?.state, .working, "starting projects as working")
        XCTAssertEqual(baseline?.paneKey, created.paneKey)
        XCTAssertEqual(baseline?.agentType, "claude")
        XCTAssertEqual(baseline?.worktreeId, "repo::wt")

        fake.emitOSC(["9999", "blocked"])
        let blocked = await iterator.next()
        XCTAssertEqual(blocked?.state, .blocked)
        XCTAssertEqual(blocked?.projection, .permission)

        fake.emitOSC(["9999", "idle"])
        var entry = await iterator.next()
        // Skip same-state confirmations; land on the done entry.
        while let current = entry, current.state == .blocked { entry = await iterator.next() }
        XCTAssertEqual(entry?.state, .done)
        XCTAssertEqual(entry?.projection, .idle)
        XCTAssertEqual(entry?.stateHistory.last?.state, .blocked,
                       "history records the previous state")
    }

    func testStatusRecordSurvivesConsumption() async throws {
        let created = try service.create(engineID: "claude-code")
        session(created.handle).emitOSC(["9999", "idle"])
        _ = try await service.wait(handle: created.handle, for: .tuiIdle, timeout: 1)
        // The waiter consumed the idle — the factual record must still say idle.
        let status = try service.agentStatus(handle: created.handle)
        XCTAssertEqual(status.projection, .idle)
        XCTAssertEqual(status.state, .done)
    }

    func testShellTerminalHasNilProjection() throws {
        let created = try service.create(engineID: "shell")
        let status = try service.agentStatus(handle: created.handle)
        XCTAssertFalse(status.isRunningAgent)
        XCTAssertNil(status.projection, "no agent → no state, not a fake idle")
        XCTAssertNil(service.list().first?.agentState)
    }

    func testHookFieldsPublishWithoutStateChangeAndCompleteOnIdle() async throws {
        let created = try service.create(engineID: "claude-code")
        let stream = try service.agentStatusUpdates(handle: created.handle)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        try service.applyHookStatus(
            handle: created.handle,
            fields: HookStatusFields(prompt: "explain it", lastAssistantMessage: "Working on it."))
        let mid = await iterator.next()
        XCTAssertEqual(mid?.prompt, "explain it")
        XCTAssertEqual(mid?.lastAssistantMessage, "Working on it.")
        XCTAssertNil(mid?.lastCompletedAssistantMessage,
                     "still working — completed copy waits for idle")
        XCTAssertEqual(mid?.state, .working)

        session(created.handle).emitOSC([
            "9999",
            #"{"status":"idle","lastAssistantMessage":"Here is the explanation."}"#,
        ])
        var entry = await iterator.next()
        while let current = entry, current.projection != .idle {
            entry = await iterator.next()
        }
        XCTAssertEqual(entry?.lastAssistantMessage, "Here is the explanation.")
        XCTAssertEqual(entry?.lastCompletedAssistantMessage, "Here is the explanation.")
        XCTAssertEqual(entry?.projection, .idle)
    }

    func testLiveHandleFollowsRemint() throws {
        let created = try service.create(engineID: "claude-code")
        XCTAssertEqual(service.liveHandle(forPaneKey: created.paneKey), created.handle)
        let reminted = try service.remintHandle(paneKey: created.paneKey)
        XCTAssertEqual(service.liveHandle(forPaneKey: created.paneKey), reminted.handle)
    }
}
