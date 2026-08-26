import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// T80 — the precondition that replaced a blanket `remote_unsupported` with a question
/// put to the host.
///
/// The classifier is where the whole feature's honesty lives: it decides whether a host
/// gets to carry a supervised worker, and the one answer that must never be produced by
/// accident is "yes". So every shape a real far side can answer with is pinned here —
/// including the two that look like success and are not (a different runtime, and a CLI
/// that ran but reached nothing).
@MainActor
final class RemoteDispatchProbeTests: XCTestCase {
    private var tmp: URL!
    private var store: OrchardDataStore!
    private var hosts: HostRegistry!
    private var runner: ScriptedSSHRunner!

    private let cli = "/Users/ci/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard"
    private let dataPath = "/Users/ci/Library/Application Support/Orchard"
    private let runtimeId = "rt_ours"

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-remote-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
        hosts = HostRegistry(store: store, sshConfig: { [] })
        try hosts.add(name: "build", hostname: "build.internal", user: "ci", port: nil)
        runner = ScriptedSSHRunner()
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func probe() -> RemoteDispatchProbe {
        RemoteDispatchProbe(hosts: hosts, runner: runner, cliCommand: cli,
                            dataPath: dataPath, runtimeId: runtimeId)
    }

    private func statusEnvelope(_ id: String) -> String {
        """
        {
          "_meta" : { "runtimeId" : "\(id)" },
          "id" : "1",
          "ok" : true,
          "result" : { "mode" : "app", "runtimeId" : "\(id)", "status" : "ready" }
        }
        """
    }

    // MARK: - The command that is actually run

    /// The probe must run the same binary, with the same two deciding variables, that
    /// the pane will carry — otherwise a green precondition proves nothing about the
    /// worker that follows it. `ORCHARD_DATA_PATH` is what points the far side at *this*
    /// runtime instead of whichever one the remote account's own HOME holds.
    func testProbeRunsThePanesOwnCLIWithThePanesOwnIdentityExports() async {
        _ = await probe().probe(hostId: "ssh:build")
        let line = runner.commandLines.joined(separator: "\n")
        XCTAssertTrue(line.contains("export ORCHARD_CLI_COMMAND="), line)
        XCTAssertTrue(line.contains("export ORCHARD_DATA_PATH="), line)
        XCTAssertTrue(line.contains("Application Support/Orchard"), line)
        XCTAssertTrue(line.contains("status --json"), line)
        // Bounded twice, like every other agent-facing remote call.
        XCTAssertTrue(line.contains("BatchMode=yes"), line)
        XCTAssertTrue(line.contains("ConnectTimeout="), line)
    }

    /// A path with a space in it must survive as one word on the far side.
    func testExportedValuesAreQuotedForTheRemoteShell() {
        let line = probe().remoteCommandLine
        XCTAssertTrue(line.contains("export ORCHARD_DATA_PATH='/Users/ci/Library/Application Support/Orchard'"),
                      line)
    }

    // MARK: - Classification

    func testAHostThatReachesThisRuntimeIsReady() async {
        runner.on("status --json", HostCommandResult(exitCode: 0,
                                                     stdout: statusEnvelope(runtimeId)))
        let readiness = await probe().probe(hostId: "ssh:build")
        XCTAssertEqual(readiness, .ready(runtimeId: runtimeId, cliCommand: cli))
    }

    /// The shape that looks like success and is the most dangerous of all: the far side
    /// really can call an Orchard, so nothing fails — it just settles somebody else's
    /// dispatch rows while this coordinator waits forever.
    func testAHostThatReachesADifferentRuntimeIsRefused() async {
        runner.on("status --json", HostCommandResult(exitCode: 0,
                                                     stdout: statusEnvelope("rt_somebody_else")))
        let readiness = await probe().probe(hostId: "ssh:build")
        guard case .refused(let code, let detail) = readiness else {
            return XCTFail("expected a refusal, got \(readiness)")
        }
        XCTAssertEqual(code, RemoteDispatchProbe.runtimeMismatch)
        XCTAssertTrue(detail.contains("rt_somebody_else"), detail)
        XCTAssertTrue(detail.contains(runtimeId), detail)
    }

    func testAHostWithNoOrchardBinaryIsRefusedAsCliMissing() async {
        runner.on("status --json", HostCommandResult(
            exitCode: 127, stderr: "bash: line 1: \(cli): No such file or directory\n"))
        let readiness = await probe().probe(hostId: "ssh:build")
        guard case .refused(let code, _) = readiness else {
            return XCTFail("expected a refusal, got \(readiness)")
        }
        XCTAssertEqual(code, RemoteDispatchProbe.cliMissing)
    }

    /// The other half of "no CLI": a login shell that reports it in words with a status
    /// that is not 127.
    func testCommandNotFoundWordingAlsoCountsAsCliMissing() async {
        runner.on("status --json", HostCommandResult(
            exitCode: 1, stderr: "zsh: command not found: orchard\n"))
        let readiness = await probe().probe(hostId: "ssh:build")
        guard case .refused(let code, _) = readiness else {
            return XCTFail("expected a refusal, got \(readiness)")
        }
        XCTAssertEqual(code, RemoteDispatchProbe.cliMissing)
    }

    /// The CLI is there and ran; there is simply no control plane it can reach from
    /// over there. Distinct from `cli_missing` because the fix is a different one.
    func testACLIThatCannotReachAnyRuntimeIsRefusedAsUnreachable() async {
        runner.on("status --json", HostCommandResult(
            exitCode: 1, stderr: "orchard: runtime_unavailable: No such file or directory\n"))
        let readiness = await probe().probe(hostId: "ssh:build")
        guard case .refused(let code, let detail) = readiness else {
            return XCTFail("expected a refusal, got \(readiness)")
        }
        XCTAssertEqual(code, RemoteDispatchProbe.runtimeUnreachable)
        XCTAssertTrue(detail.contains("runtime_unavailable"), detail)
    }

    /// Exit 0 with no envelope: the far side answered something, but not something a
    /// dispatch can be built on. Never read as ready.
    func testAnExitZeroWithNoStatusEnvelopeIsRefused() async {
        runner.on("status --json", HostCommandResult(exitCode: 0, stdout: "hello\n"))
        let readiness = await probe().probe(hostId: "ssh:build")
        guard case .refused(let code, _) = readiness else {
            return XCTFail("expected a refusal, got \(readiness)")
        }
        XCTAssertEqual(code, RemoteDispatchProbe.unintelligible)
    }

    /// A remote login shell is allowed to print its own noise before our JSON; that is
    /// not a reason to refuse a working host.
    func testAStatusEnvelopePrefixedByLoginNoiseStillParses() async {
        runner.on("status --json", HostCommandResult(
            exitCode: 0,
            stdout: "Welcome to build.internal\nLast login: Tue\n" + statusEnvelope(runtimeId)))
        let readiness = await probe().probe(hostId: "ssh:build")
        XCTAssertEqual(readiness, .ready(runtimeId: runtimeId, cliCommand: cli))
    }

    /// Rule 2 (docs/design/remote-hosts.md §1). Status 255 is OpenSSH reporting its own
    /// transport failure, so it says nothing about the far side — and a probe that could
    /// not look must never be folded in with a host that answered "no".
    func testATransportFailureIsUnverifiableNotARefusal() async {
        runner.on("status --json", HostCommandResult(
            exitCode: 255,
            stderr: "ssh: connect to host build.internal port 22: Connection refused\n"))
        let readiness = await probe().probe(hostId: "ssh:build")
        guard case .unverifiable(let reason) = readiness else {
            return XCTFail("expected unverifiable, got \(readiness)")
        }
        XCTAssertTrue(reason.lowercased().contains("refused"), reason)
    }

    func testADeadlineWithNoAnswerIsUnverifiable() async {
        runner.on("status --json", HostCommandResult(exitCode: nil, timedOut: true))
        let readiness = await probe().probe(hostId: "ssh:build")
        guard case .unverifiable = readiness else {
            return XCTFail("expected unverifiable, got \(readiness)")
        }
    }

    // MARK: - Hosts the runtime cannot even ask

    func testAnUnregisteredHostIsRefusedWithoutDialingAnything() async {
        let readiness = await probe().probe(hostId: "ssh:never-registered")
        guard case .refused(let code, _) = readiness else {
            return XCTFail("expected a refusal, got \(readiness)")
        }
        XCTAssertEqual(code, RemoteDispatchProbe.notWired)
        XCTAssertTrue(runner.commandLines.isEmpty,
                      "a name the user never registered is not one Orchard dials")
    }

    func testAnUnparseableHostIdIsRefused() async {
        let readiness = await probe().probe(hostId: "runtime:vm-1")
        guard case .refused(let code, _) = readiness else {
            return XCTFail("expected a refusal, got \(readiness)")
        }
        XCTAssertEqual(code, RemoteDispatchProbe.notWired)
    }

    // MARK: - The refusal a coordinator reads

    /// Each reason gets its own sentence, because each has a different fix — and all of
    /// them name the handoff-style pane that still works.
    func testRefusalWordingNamesTheCauseAndTheAlternative() {
        let missing = LiveOrchestrationStore.remoteDispatchRefusal(
            hostLabel: "build", code: RemoteDispatchProbe.cliMissing,
            detail: "no such file", worktreeID: "repo::/srv/wt/apricot", agent: "claude-code")
        XCTAssertTrue(missing.contains("worker_done"), missing)
        XCTAssertTrue(missing.contains("terminal create --worktree repo::/srv/wt/apricot --engine claude-code"),
                      missing)

        let mismatch = LiveOrchestrationStore.remoteDispatchRefusal(
            hostLabel: "build", code: RemoteDispatchProbe.runtimeMismatch,
            detail: "reached rt_other", worktreeID: "wt", agent: nil)
        XCTAssertTrue(mismatch.contains("settle somebody else's dispatch"), mismatch)
        XCTAssertTrue(mismatch.contains("--engine <agent>"), mismatch)

        let unreachable = LiveOrchestrationStore.remoteDispatchRefusal(
            hostLabel: "build", code: RemoteDispatchProbe.runtimeUnreachable,
            detail: "runtime_unavailable", worktreeID: "wt", agent: nil)
        XCTAssertTrue(unreachable.contains("lifecycle calls would go nowhere"), unreachable)
    }

    /// The gate maps the three verdicts onto the two wire codes, and an unverifiable
    /// host never gets worded as one that answered.
    func testGateMapsVerdictsOntoTypedCodes() throws {
        XCTAssertNil(LiveOrchestrationStore.remoteDispatchGate(
            hostId: "ssh:build", worktreeID: "wt", agent: nil,
            readiness: .ready(runtimeId: "rt_ours", cliCommand: "orchard")))

        let refused = try XCTUnwrap(LiveOrchestrationStore.remoteDispatchGate(
            hostId: "ssh:build", worktreeID: "wt", agent: nil,
            readiness: .refused(code: RemoteDispatchProbe.cliMissing, detail: "nope")))
        XCTAssertEqual(refused.rpcError.code, "remote_unsupported")
        XCTAssertEqual(refused.rpcError.data?.field("reason")?.stringValue,
                       RemoteDispatchProbe.cliMissing)

        let lost = try XCTUnwrap(LiveOrchestrationStore.remoteDispatchGate(
            hostId: "ssh:build", worktreeID: "wt", agent: nil,
            readiness: .unverifiable(reason: "the connection timed out")))
        XCTAssertEqual(lost.rpcError.code, "host_unverifiable")
        XCTAssertTrue(lost.rpcError.message.contains("Loss of contact is not evidence"),
                      lost.rpcError.message)
    }

    // MARK: - Which machine the pane opens on

    /// `RemotePaneLauncher.resolveHost` is the one place the pane's host is decided, and
    /// rule 1 says it is never inferred: a stamp we cannot read is refused rather than
    /// downgraded to local.
    func testPaneHostResolutionFollowsTheWorkspaceStamp() throws {
        XCTAssertNil(try RemotePaneLauncher.resolveHost(
            workspaceID: "wt", workspaceStamp: "local", requested: .local))
        XCTAssertEqual(try RemotePaneLauncher.resolveHost(
            workspaceID: "wt", workspaceStamp: "ssh:build", requested: .local),
                       ExecutionHostId(rawValue: "ssh:build"))
        // A workspace with no stamp and an explicit --host is the T29 shape: a bare
        // remote connection, not a remote workspace.
        XCTAssertEqual(try RemotePaneLauncher.resolveHost(
            workspaceID: "wt", workspaceStamp: nil,
            requested: ExecutionHostId(rawValue: "ssh:build")!),
                       ExecutionHostId(rawValue: "ssh:build"))
        // Disagreement is a typed refusal, not a reinterpretation.
        XCTAssertThrowsError(try RemotePaneLauncher.resolveHost(
            workspaceID: "wt", workspaceStamp: "ssh:build",
            requested: ExecutionHostId(rawValue: "ssh:other")!))
        // An unreadable stamp never reads as local.
        XCTAssertThrowsError(try RemotePaneLauncher.resolveHost(
            workspaceID: "wt", workspaceStamp: "runtime:vm-1", requested: .local))
    }
}
