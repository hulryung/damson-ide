import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// A scripted `ssh` that hands back queued results in order and records every argv it
/// was given, so a test can pin *what would have run* as precisely as what came back.
private final class ScriptedRunner: HostCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [HostCommandResult]
    private var fallback: HostCommandResult
    private(set) var argvs: [[String]] = []

    init(_ queue: [HostCommandResult] = [],
         fallback: HostCommandResult = HostCommandResult(exitCode: 0)) {
        self.queue = queue
        self.fallback = fallback
    }

    func enqueue(_ result: HostCommandResult) {
        lock.lock(); queue.append(result); lock.unlock()
    }

    func run(_ argv: [String], timeout: TimeInterval) async -> HostCommandResult {
        lock.lock()
        argvs.append(argv)
        let next = queue.isEmpty ? fallback : queue.removeFirst()
        lock.unlock()
        // A real `ssh -M` leaves its control socket on disk, and its absence is how a
        // dead master is detected. A fake that skipped it would make every generation
        // look lost the moment it was opened.
        if next.exitCode == 0, argv.contains("ControlMaster=yes"),
           let option = argv.first(where: { $0.hasPrefix("ControlPath=") }) {
            let path = String(option.dropFirst("ControlPath=".count))
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        return next
    }

    var lastArgv: [String] { lock.lock(); defer { lock.unlock() }; return argvs.last ?? [] }
}

private func ok(_ text: String = "") -> HostCommandResult {
    HostCommandResult(exitCode: 0, stdout: text)
}

/// T89 — the durable, generation-counted, multiplexed connection.
///
/// The property under test throughout is not "commands are faster". It is that two
/// spans of contact can never be confused for one: a generation is minted on every
/// open, it is in the control socket path so a stale master cannot serve a new
/// generation, and a question naming an ended generation is refused rather than
/// answered from the current connection.
final class RemoteConnectionTests: XCTestCase {
    private let host = HostRecord(name: "orchard-loopback", hostname: "127.0.0.1",
                                  user: "dkkang", port: 2222, source: .manual)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-mux-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func connection(_ runner: ScriptedRunner) -> RemoteConnection {
        RemoteConnection(host: host, runner: runner, controlDirectory: directory,
                         openTimeout: 1, epoch: "abc12345")
    }

    // MARK: - Generation identity

    func testGenerationLabelRoundTripsAndRejectsGarbage() {
        let generation = RemoteConnectionGeneration(host: "build", sequence: 3, epoch: "7a1c9f02")
        XCTAssertEqual(generation.label, "build#3.7a1c9f02")
        XCTAssertEqual(RemoteConnectionGeneration.parse(generation.label), generation)
        for bad in ["", "build", "build#", "build#0.abc", "#1.abc", "build#x.abc", "build#1."] {
            XCTAssertNil(RemoteConnectionGeneration.parse(bad), bad)
        }
    }

    func testEpochMakesTwoRuntimesFirstGenerationsDistinct() {
        // Two runtimes both start at sequence 1. Without the epoch their labels would
        // compare equal, and a record from the first would claim continuity with the
        // second — the exact confusion the counter exists to prevent.
        let first = RemoteConnectionGeneration(host: "build", sequence: 1, epoch: "aaaaaaaa")
        let second = RemoteConnectionGeneration(host: "build", sequence: 1, epoch: "bbbbbbbb")
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Opening

    func testOpenMintsGenerationOneAndBuildsAControlMaster() async {
        let runner = ScriptedRunner()
        let connection = connection(runner)
        guard case .ready(let generation, let options) = await connection.open() else {
            return XCTFail("expected the master to open")
        }
        XCTAssertEqual(generation?.sequence, 1)
        XCTAssertEqual(generation?.label, "orchard-loopback#1.abc12345")
        // A client rides the master; it never becomes one. Creating a master here would
        // mint a transport nothing counted.
        XCTAssertTrue(options.contains("ControlMaster=no"))
        let argv = runner.lastArgv
        XCTAssertTrue(argv.contains("ControlMaster=yes"))
        XCTAssertTrue(argv.contains("BatchMode=yes"))
        XCTAssertTrue(argv.contains("-N"))
        XCTAssertTrue(argv.contains("-f"))
        XCTAssertTrue(argv.contains(where: { $0.hasPrefix("ControlPersist=") }))
        let status = await connection.status()
        XCTAssertEqual(status.state, "open")
        XCTAssertTrue(status.multiplexed)
        XCTAssertEqual(status.generation, "orchard-loopback#1.abc12345")
    }

    func testControlPathCarriesTheSequenceSoAStaleMasterCannotServeANewGeneration() async {
        let runner = ScriptedRunner()
        let connection = connection(runner)
        _ = await connection.open()
        let first = await connection.status().controlPath
        _ = await connection.open()
        let second = await connection.status().controlPath
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first?.hasSuffix("-1") == true, first ?? "nil")
        XCTAssertTrue(second?.hasSuffix("-2") == true, second ?? "nil")
    }

    func testReopeningIsAlwaysANewGenerationNeverAContinuation() async {
        let connection = connection(ScriptedRunner())
        _ = await connection.open()
        let first = await connection.currentGeneration()
        _ = await connection.open()
        let second = await connection.currentGeneration()
        XCTAssertEqual(first?.sequence, 1)
        XCTAssertEqual(second?.sequence, 2)
        XCTAssertNotEqual(first, second)
    }

    func testAnOpenThatCannotReachTheHostIsUnverifiableNotAClaimAboutTheFarSide() async {
        let runner = ScriptedRunner([HostCommandResult(
            exitCode: 255,
            stderr: "ssh: connect to host 127.0.0.1 port 2222: Connection refused\n")])
        let connection = connection(runner)
        guard case .refused(let error) = await connection.open() else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(error.code, "host_unverifiable")
        XCTAssertTrue(error.message.contains("Loss of contact is not evidence"))
        let status = await connection.status()
        XCTAssertEqual(status.state, "never")
        XCTAssertNil(status.generation)
    }

    // MARK: - The fence

    func testAFencedCallOnAnEndedGenerationIsRefusedNotServedFromTheNewOne() async {
        let connection = connection(ScriptedRunner())
        guard case .ready(let first?, _) = await connection.open() else {
            return XCTFail("expected an open")
        }
        _ = await connection.open()   // generation 2
        guard case .refused(let error) = await connection.acquire(fencedTo: first) else {
            return XCTFail("expected the fence to refuse")
        }
        XCTAssertEqual(error.code, "connection_generation_ended")
        XCTAssertTrue(error.message.contains(first.label))
        XCTAssertTrue(error.message.contains("#2."))
        XCTAssertTrue(error.message.contains("reconnect as continuity"))
        XCTAssertTrue(error.message.contains(HostLiveness.generationRefusalReminder))
    }

    func testAnUnfencedCallOpensOnDemandAndSaysWhichGenerationAnswered() async {
        let connection = connection(ScriptedRunner())
        guard case .ready(let generation, let options) = await connection.acquire() else {
            return XCTFail("expected an acquisition")
        }
        XCTAssertEqual(generation?.sequence, 1)
        XCTAssertTrue(options.contains("ControlMaster=no"))
    }

    func testATransportFailureEndsTheGenerationAndLaterFencedCallsAreRefused() async {
        let connection = connection(ScriptedRunner())
        guard case .ready(let generation?, _) = await connection.open() else {
            return XCTFail("expected an open")
        }
        let result = HostCommandResult(exitCode: 255, stderr: "client_loop: send disconnect\n")
        let settled = await connection.settle(
            generation: generation, result: result,
            outcome: SSHRunner.classify(result, host: host), fenced: false)
        XCTAssertTrue(settled.outcome.isUnverifiable)
        let status = await connection.status()
        XCTAssertEqual(status.state, "lost")
        XCTAssertEqual(status.generation, generation.label)
        XCTAssertTrue(status.note.contains("Loss of contact is not evidence"))
        guard case .refused(let error) = await connection.acquire(fencedTo: generation) else {
            return XCTFail("a lost generation must refuse")
        }
        XCTAssertEqual(error.code, "connection_generation_ended")
    }

    private func strayed() -> HostCommandResult {
        // OpenSSH's own admission that the control socket was not there and it connected
        // directly instead.
        HostCommandResult(
            exitCode: 0, stdout: "definitely-fine\n",
            stderr: "Control socket connect(/tmp/orchard-mux/abc-1): No such file or directory\n")
    }

    func testAFencedAnswerThatBypassedTheMasterIsDiscardedEvenThoughItExitedZero() async {
        // The subtle case: the command succeeded, but not on the connection the caller
        // asked about. Accepting it would be a reconnect passing for continuity with a
        // clean exit status on top to make it convincing.
        let connection = connection(ScriptedRunner())
        guard case .ready(let generation?, _) = await connection.open() else {
            return XCTFail("expected an open")
        }
        let result = strayed()
        let settled = await connection.settle(
            generation: generation, result: result,
            outcome: SSHRunner.classify(result, host: host), fenced: true)
        XCTAssertTrue(settled.outcome.isUnverifiable)
        XCTAssertNil(settled.generation)
        let state = await connection.status().state
        XCTAssertEqual(state, "lost")
    }

    func testAnUnfencedAnswerThatBypassedTheMasterIsKeptButNotAttributed() async {
        // An unfenced caller asked about the *machine* — a file, a process, a git tree.
        // A direct connection answers that exactly as well, and discarding it would
        // invent a failure. What must not happen is recording it as having come from a
        // span of contact it did not.
        let connection = connection(ScriptedRunner())
        guard case .ready(let generation?, _) = await connection.open() else {
            return XCTFail("expected an open")
        }
        let result = strayed()
        let settled = await connection.settle(
            generation: generation, result: result,
            outcome: SSHRunner.classify(result, host: host), fenced: false)
        XCTAssertEqual(settled.outcome.successOutput, "definitely-fine\n")
        XCTAssertNil(settled.generation)
        let state = await connection.status().state
        XCTAssertEqual(state, "lost")
    }

    func testAMasterThatCannotBeOpenedDegradesToADirectConnectionRatherThanFailing() async {
        // A connection Orchard could not establish must never become a verdict about the
        // work. The command runs on its own `ssh` — the pre-T89 behaviour — and whatever
        // *it* answers is the honest answer.
        let runner = ScriptedRunner([HostCommandResult(
            exitCode: 255, stderr: "ssh: connect to host 127.0.0.1 port 2222: Connection refused\n")])
        let connection = connection(runner)
        guard case .ready(let generation, let options) = await connection.acquire() else {
            return XCTFail("an unfenced acquire must degrade, not refuse")
        }
        XCTAssertNil(generation)
        XCTAssertTrue(options.isEmpty)

        // And it does not retry the master in front of every command afterwards.
        let attempts = runner.argvs.count
        _ = await connection.acquire()
        XCTAssertEqual(runner.argvs.count, attempts)
    }

    func testAVanishedControlSocketEndsTheGenerationBeforeTheNextCommandRuns() async {
        // Verified against a real sshd: when the socket file is simply gone — what a
        // master's own exit leaves behind — OpenSSH says nothing and connects directly
        // with a clean status. Waiting for it to confess would leave the state reading
        // `open` while a fenced caller was served from a connection that no longer
        // existed.
        let connection = connection(ScriptedRunner())
        guard case .ready(let generation?, _) = await connection.open() else {
            return XCTFail("expected an open")
        }
        let openStatus = await connection.status()
        let path = openStatus.controlPath ?? ""
        XCTAssertFalse(path.isEmpty)
        try? FileManager.default.removeItem(atPath: path)

        guard case .refused(let error) = await connection.acquire(fencedTo: generation) else {
            return XCTFail("a generation whose socket is gone must refuse")
        }
        XCTAssertEqual(error.code, "connection_generation_ended")
        let status = await connection.status()
        XCTAssertEqual(status.state, "lost")
        XCTAssertTrue((status.reason ?? "").contains("control socket is gone"), status.note)
    }

    func testCloseIsADeliberateEndingAndReadsDifferentlyFromLoss() async {
        let connection = connection(ScriptedRunner())
        guard case .ready(let generation?, _) = await connection.open() else {
            return XCTFail("expected an open")
        }
        let status = await connection.close()
        XCTAssertEqual(status.state, "closed")
        XCTAssertEqual(status.generation, generation.label)
        XCTAssertFalse(status.note.contains("Loss of contact"))
        XCTAssertTrue(status.note.contains("closed here"))
        guard case .refused = await connection.acquire(fencedTo: generation) else {
            return XCTFail("a closed generation must refuse")
        }
    }

    func testAFailedReopenStillSaysWhichGenerationEnded() async {
        // Overwriting the state with `never` would erase which span of contact ended —
        // and that is precisely the fact a caller still holding the old generation is
        // asking about.
        let runner = ScriptedRunner()
        let connection = connection(runner)
        guard case .ready(let first?, _) = await connection.open() else {
            return XCTFail("expected an open")
        }
        runner.enqueue(ok())     // the `ssh -O exit` that retires the old master
        runner.enqueue(HostCommandResult(
            exitCode: 255, stderr: "ssh: connect to host 127.0.0.1 port 2222: Connection refused\n"))
        guard case .refused = await connection.open() else {
            return XCTFail("expected the reopen to be refused")
        }
        let status = await connection.status()
        XCTAssertEqual(status.state, "closed")
        XCTAssertEqual(status.generation, first.label)
        guard case .refused(let error) = await connection.acquire(fencedTo: first) else {
            return XCTFail("the torn-down generation must still refuse")
        }
        XCTAssertEqual(error.code, "connection_generation_ended")
        XCTAssertTrue(error.message.contains(first.label))
    }

    func testShortNameKeepsTheControlPathInsideAUnixSocketAddress() {
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(RemoteConnection.shortName(long).count, 8)
        XCTAssertNotEqual(RemoteConnection.shortName("a"), RemoteConnection.shortName("b"))
        XCTAssertEqual(RemoteConnection.shortName("build"), RemoteConnection.shortName("build"))
    }

    // MARK: - SSHRunner integration

    func testARunnerWithNoConnectionIsExactlyTheHistoricalOneSshPerCall() async {
        let runner = ScriptedRunner([ok("hi\n")])
        let ssh = SSHRunner(host: host, runner: runner)
        _ = await ssh.run("true")
        XCTAssertFalse(runner.lastArgv.contains("ControlMaster=no"))
        XCTAssertFalse(runner.lastArgv.contains(where: { $0.hasPrefix("ControlPath=") }))
    }

    func testARunnerWithAConnectionRidesTheSharedTransport() async {
        let runner = ScriptedRunner()
        let connection = connection(runner)
        _ = await connection.open()
        let ssh = SSHRunner(host: host, runner: runner, connection: connection)
        runner.enqueue(ok("hi\n"))
        let (outcome, generation) = await ssh.runReporting("true")
        XCTAssertEqual(outcome.successOutput, "hi\n")
        XCTAssertEqual(generation?.sequence, 1)
        XCTAssertTrue(runner.lastArgv.contains("ControlMaster=no"))
        XCTAssertTrue(runner.lastArgv.contains(where: { $0.hasPrefix("ControlPath=") }))
    }

    func testAFencedRunnerCallRefusesRatherThanRetryingOnTheNewConnection() async {
        let runner = ScriptedRunner()
        let connection = connection(runner)
        guard case .ready(let first?, _) = await connection.open() else {
            return XCTFail("expected an open")
        }
        _ = await connection.open()
        let ssh = SSHRunner(host: host, runner: runner, connection: connection)
        let before = runner.argvs.count
        let outcome = await ssh.runFenced("true", generation: first)
        XCTAssertTrue(outcome.isUnverifiable)
        // The refusal is the answer: nothing was run at all.
        XCTAssertEqual(runner.argvs.count, before)
    }

    func testTheTunnelPortWalkStaysOffTheSharedMaster() async {
        // A `-R` asked for over a shared master belongs to the master's lifetime, not
        // to the pane that asked. Probing a port that way would answer about a forward
        // the pane will never own.
        let runner = ScriptedRunner()
        let connection = connection(runner)
        _ = await connection.open()
        let ssh = SSHRunner(host: host, runner: runner, connection: connection)
        runner.enqueue(ok())
        _ = await ssh.runRaw("true", options: ["-R", "40000:127.0.0.1:9000"])
        XCTAssertFalse(runner.lastArgv.contains("ControlMaster=no"))
    }
}

/// T89 over the RPC seam: `host connect|disconnect|connection` and `terminal liveness`.
@MainActor
final class RemoteDurabilityHandlerTests: XCTestCase {
    private var tmp: URL!
    private var store: OrchardDataStore!
    private var hosts: HostRegistry!
    private var terminals: TerminalService!
    private var pool: RemoteConnectionPool!
    private var runner: ScriptedSSHRunner!
    private var server: InMemoryRuntimeServer!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-t89-rpc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
        hosts = HostRegistry(store: store, sshConfig: { [] })
        try hosts.add(name: "build", hostname: "build.internal", user: "ci", port: nil)
        runner = ScriptedSSHRunner()
        pool = RemoteConnectionPool(controlDirectory: tmp.appendingPathComponent("mux"),
                                    runner: runner)
        terminals = TerminalService(factory: { _, _ in ScriptedTerminalSession() })
        let workspaces = WorkspaceService(store: store,
                                          worktreesRoot: tmp.appendingPathComponent("wt"))
        workspaces.hostCommandRunner = runner
        var registry = CommandRegistry()
        registry.register(HostCommandHandler(registry: hosts, runner: runner,
                                             probeTimeout: 1, connections: pool))
        registry.register(RemotePaneLivenessHandler(service: terminals, hosts: hosts,
                                                    runner: runner, connections: pool,
                                                    timeout: 1))
        registry.register(TerminalCommandHandler(service: terminals, workspaces: workspaces,
                                                 hosts: hosts, hostRunner: runner))
        server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_t89")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    func testConnectOpensAGenerationAndDisconnectEndsIt() async throws {
        let opened = await call("host-connect", ["name": .string("build")])
        XCTAssertTrue(opened.ok, String(describing: opened.error))
        let first = try XCTUnwrap(opened.result?.objectValue)
        XCTAssertEqual(first["state"]?.stringValue, "open")
        XCTAssertEqual(first["multiplexed"]?.boolValue, true)
        let generation = try XCTUnwrap(first["generation"]?.stringValue)
        XCTAssertTrue(generation.hasPrefix("build#1."), generation)

        let listedResponse = await call("host-connection")
        let listed = try XCTUnwrap(listedResponse.result?.objectValue)
        XCTAssertEqual(listed["totalCount"]?.numberValue, 1)
        XCTAssertTrue(try XCTUnwrap(listed["note"]?.stringValue).contains("refused"))

        let closedResponse = await call("host-disconnect", ["name": .string("build")])
        let closed = try XCTUnwrap(closedResponse.result?.objectValue)
        XCTAssertEqual(closed["state"]?.stringValue, "closed")
        XCTAssertEqual(closed["generation"]?.stringValue, generation)

        // Reopening is a second span, never a resumption of the first.
        let reopenedResponse = await call("host-connect", ["name": .string("build")])
        let reopened = try XCTUnwrap(reopenedResponse.result?.objectValue)
        XCTAssertTrue(try XCTUnwrap(reopened["generation"]?.stringValue).hasPrefix("build#2."))
    }

    func testConnectingToAnUnregisteredHostIsTypedNotAttempted() async {
        let response = await call("host-connect", ["name": .string("nowhere")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unknown_host")
        XCTAssertTrue(runner.commandLines.isEmpty)
    }

    func testAnOpenThatCannotReachTheHostRefusesWithTheRuleTwoReminder() async {
        runner.fallback = HostCommandResult(
            exitCode: 255,
            stderr: "ssh: connect to host build.internal port 22: Connection refused\n")
        let response = await call("host-connect", ["name": .string("build")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "host_unverifiable")
        XCTAssertTrue(response.error?.message.contains("Loss of contact is not evidence") == true)
    }

    func testLivenessRefusesALocalPaneRatherThanAnsweringADifferentQuestion() async throws {
        let createdResponse = await call("terminal-create")
        let created = try XCTUnwrap(createdResponse.result?.objectValue)
        let handle = try XCTUnwrap(created["handle"]?.stringValue)
        let response = await call("terminal-liveness", ["terminal": .string(handle)])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
        XCTAssertTrue(response.error?.message.contains("runs on this machine") == true)
    }

    func testLivenessOnAConnectionOnlyPaneIsUnverifiableBecauseNothingWasRecorded() async throws {
        // `--host ssh:<name>` with no worktree names a connection, not a workspace: there
        // is no far-side directory and no process Orchard asked the host to remember. The
        // honest answer is unverifiable — never a guess, and never `exited`.
        let createdResponse = await call("terminal-create", ["host": .string("ssh:build")])
        let created = try XCTUnwrap(createdResponse.result?.objectValue)
        let pane = try XCTUnwrap(created["paneKey"]?.stringValue)
        let livenessResponse = await call("terminal-liveness", ["pane": .string(pane)])
        let result = try XCTUnwrap(livenessResponse.result?.objectValue)
        XCTAssertEqual(result["status"]?.stringValue, "unverifiable")
        XCTAssertEqual(result["answer"]?.stringValue, "no-record")
        XCTAssertEqual(result["executionHostId"]?.stringValue, "ssh:build")
        XCTAssertTrue(try XCTUnwrap(result["note"]?.stringValue)
            .contains("Loss of contact is not evidence"))
        XCTAssertTrue(runner.commandLines.isEmpty)
    }

    func testATranscriptForARemotePaneWithNoFarSideDirectoryIsRefusedTyped() async throws {
        // T89 replaced the blanket `remote_provider_transcript_unsupported`, but not with
        // a guess: a remote pane whose far-side directory was never recorded still gets a
        // typed refusal, because the local cwd is only where `ssh` was launched from.
        let createdResponse = await call("terminal-create", ["host": .string("ssh:build")])
        let handle = try XCTUnwrap(createdResponse.result?.objectValue?["handle"]?.stringValue)
        XCTAssertEqual(WorkerRuntimeContext.transcriptPlacement(terminals, handle: handle),
                       .unavailable(reason: "remote_working_directory_unavailable"))
    }

    func testALocalPanesTranscriptStillResolvesOnThisMachine() async throws {
        let createdResponse = await call("terminal-create")
        let handle = try XCTUnwrap(createdResponse.result?.objectValue?["handle"]?.stringValue)
        XCTAssertEqual(WorkerRuntimeContext.transcriptPlacement(terminals, handle: handle),
                       .local)
    }

    func testLivenessNeedsAnIdentityToAddress() async {
        let response = await call("terminal-liveness")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }
}
