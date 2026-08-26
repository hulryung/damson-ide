import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// A hook channel that binds nothing. The port is a value the launch path reads and
/// writes into a remote config; no test needs a real listening socket to pin that.
private final class StubHookChannel: AgentHookChannel, @unchecked Sendable {
    let localHookPort: UInt16
    private(set) var registered: [String] = []
    private(set) var unregistered: [String] = []
    private var handlers: [String: @Sendable (String, Data) -> Void] = [:]

    init(port: UInt16) { self.localHookPort = port }

    func register(token: String, handler: @escaping @Sendable (String, Data) -> Void) {
        registered.append(token)
        handlers[token] = handler
    }

    func unregister(token: String) { unregistered.append(token) }

    /// Deliver an event the way a real POST would.
    func deliver(token: String, event: String, body: Data = Data()) {
        handlers[token]?(event, body)
    }
}

private func stdout(_ text: String) -> HostCommandResult {
    HostCommandResult(exitCode: 0, stdout: text)
}

/// OpenSSH refusing one remote forward: fatal under `ExitOnForwardFailure`, so it comes
/// back as 255 — the same status a dead transport uses. Only the message separates them.
private func forwardRefused(_ port: Int) -> HostCommandResult {
    HostCommandResult(exitCode: 255,
                      stderr: "Warning: remote port forwarding failed for listen port \(port)\n"
                          + "Error: forwarding disabled due to prior request failure\n")
}

private func transportFailure(
    _ stderr: String = "ssh: connect to host build.internal port 22: Connection refused"
) -> HostCommandResult {
    HostCommandResult(exitCode: 255, stderr: stderr + "\n")
}

/// T39 — SSH stage 3: an agent CLI running in a worktree on another machine, watched
/// from this one over an SSH reverse tunnel.
///
/// Everything here rides the scripted `ssh` runner: no host, no network, no key. What a
/// scripted runner cannot prove is listed on the honest-scope note in the task report —
/// principally that `sshd` really grants the reverse forward and that a real Claude Code
/// on the far side really POSTs through it.
@MainActor
final class RemoteAgentTests: XCTestCase {
    private var tmp: URL!
    private var store: OrchardDataStore!
    private var service: WorkspaceService!
    private var runner: ScriptedSSHRunner!
    private var hosts: HostRegistry!
    private var hookChannel: StubHookChannel!
    private var terminals: TerminalService!
    private var server: InMemoryRuntimeServer!
    private var terminalSpecs: [TerminalCreateSpec] = []

    private let repoPath = "/srv/work/orchard"
    private let worktreePath = "/home/ci/Orchard/worktrees/orchard/apricot"
    private let porcelain = """
        worktree /srv/work/orchard
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /home/ci/Orchard/worktrees/orchard/apricot
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/ci/apricot

        """

    private var host: HostRecord {
        HostRecord(name: "build", hostname: "build.internal", user: "ci", source: .manual)
    }

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-remote-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
        runner = ScriptedSSHRunner()
        hosts = HostRegistry(store: store, sshConfig: { [] })
        try hosts.add(name: "build", hostname: "build.internal", user: "ci", port: nil)
        service = WorkspaceService(store: store, worktreesRoot: tmp.appendingPathComponent("wt"))
        service.hostCommandRunner = runner
        service.remoteCommandTimeout = 1
        hookChannel = StubHookChannel(port: 9091)

        terminalSpecs = []
        // A hook signal is the *authoritative* state source, so the fusion knobs that
        // exist to survive screen repaint gaps only get in the way here: no spawn
        // floor, no debounce, one event = one verdict.
        var detector = ReadinessDetector.Config()
        detector.idleDebounce = 1
        detector.spawnFloor = 0
        terminals = TerminalService(factory: { [weak self] spec, _ in
            self?.terminalSpecs.append(spec)
            return ScriptedTerminalSession()
        }, detectorConfig: detector)
        terminals.hookChannel = hookChannel
        var registry = CommandRegistry()
        registry.register(RepoRegistryHandler(service: service))
        registry.register(WorkspaceCommandHandler(service: service))
        registry.register(TerminalCommandHandler(service: terminals, workspaces: service,
                                                 hosts: hosts, hookChannel: hookChannel,
                                                 hostRunner: runner))
        server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_remote_agent")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    /// Register the remote repo and project its worktrees, so `--worktree <remote id>`
    /// resolves.
    @discardableResult
    private func seedRemoteWorktree() async throws -> String {
        runner.on("test -d /srv/work/orchard/.git", stdout(""))
        runner.on("for-each-ref '--format=%(refname)' refs/remotes",
                  stdout("refs/remotes/origin/main\n"))
        runner.on("worktree list --porcelain", stdout(porcelain))
        let added = await call("repo-add", ["path": .string(repoPath),
                                            "host": .string("ssh:build")])
        XCTAssertTrue(added.ok, String(describing: added.error))
        let repo = try XCTUnwrap(service.listRepos().first)
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        return "\(repo.id)::\(worktreePath)"
    }

    /// The tunnel claim succeeds on the first candidate port.
    private func scriptTunnel(port: UInt16 = 47110) {
        runner.on("-R \(port):127.0.0.1:9091", HostCommandResult(exitCode: 0))
    }

    // MARK: - Remote argv construction

    func testRemoteArgvCdsExecsAndStripsClaudesInheritedSessionMarkers() {
        let launch = try! RemoteAgentService.requireRemoteLaunch(ClaudeCodeEngine(),
                                                                hostName: "build")
        let command = RemoteAgentLaunch.remoteCommand(directory: worktreePath, launch: launch)
        // `cd` on the far side, never as the local PTY's cwd; `exec` so the remote child
        // IS the agent and its exit status is the agent's, not a wrapper shell's.
        XCTAssertTrue(command.hasPrefix("cd /home/ci/Orchard/worktrees/orchard/apricot && "),
                      command)
        XCTAssertTrue(command.hasSuffix("exec claude'"), command)
        // The marker strip travels: `ssh` forwards no environment by default, but a
        // user's own SendEnv/AcceptEnv pair or the remote account's rc can still set
        // these, and an agent that believes it is a child session turns transcripts off.
        for marker in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
                       "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_SESSION_ID"] {
            XCTAssertTrue(command.contains(marker), "\(marker) missing from \(command)")
        }
        XCTAssertTrue(command.contains("unset CLAUDECODE "), command)
    }

    /// T83, found live: `ssh host '<command>'` is **not** a login. sshd runs the command
    /// through `$SHELL -c`, which reads no `.zprofile`/`.zshrc`, so PATH is sshd's own
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`) and `claude` — installed under homebrew, `~/.local`
    /// or a version manager on every real machine — is not on it. The pane died at spawn
    /// with `zsh:1: command not found: claude`.
    ///
    /// The local spawn has always wrapped an engine's argv in a login shell for exactly
    /// this reason (`EngineLaunch.argv`); the remote one now does the same, which is what
    /// makes `RemoteEngineLaunch`'s promise — send the *command* and let the far side
    /// resolve it "as the user would" — actually true.
    func testRemoteAgentRunsThroughALoginShellSoTheCommandResolves() {
        let command = RemoteAgentLaunch.remoteCommand(
            directory: worktreePath, launch: ClaudeCodeEngine().remoteLaunch!)
        XCTAssertTrue(command.contains("exec \"${SHELL:-/bin/sh}\" -lc "), command)
        // `${SHELL:-/bin/sh}` stays unquoted so the far side expands it, and keeps its
        // fallback: a host with no SHELL would otherwise exec the empty string.
        XCTAssertFalse(command.contains("'\"${SHELL:-/bin/sh}\"'"), command)
        // The agent still ends up as the PTY's remote child — one `exec` into the login
        // shell, one out of it — so `HostLiveness.verdictForPTYEnd` reads the agent's own
        // exit status and not a wrapper's.
        XCTAssertEqual(command.components(separatedBy: "exec ").count - 1, 2, command)
        // The whole inner command is one quoted argument, so nothing in it can be split
        // by the outer shell.
        let inner = String(command[command.range(of: " -lc ")!.upperBound...])
        XCTAssertTrue(inner.hasPrefix("'") && inner.hasSuffix("'"), inner)
        XCTAssertFalse(inner.dropFirst().dropLast().contains("'"), inner)
    }

    /// An engine with no environment to strip still gets the login shell — the PATH
    /// problem has nothing to do with the markers.
    func testARemoteLaunchWithNothingToUnsetStillGetsTheLoginShell() {
        let command = RemoteAgentLaunch.remoteCommand(
            directory: "/w", launch: RemoteEngineLaunch(command: "codex", arguments: ["--x"]))
        XCTAssertEqual(command, "cd /w && exec \"${SHELL:-/bin/sh}\" -lc 'exec codex --x'")
    }

    func testRemoteArgvIsSSHWithTheTunnelAndTheHostsOwnDestinationRules() {
        let launch = ClaudeCodeEngine().remoteLaunch!
        let command = RemoteAgentLaunch.remoteCommand(directory: worktreePath, launch: launch)
        let tunnel = RemoteHookTunnel.Plan(remotePort: 47110, localPort: 9091, mode: .fixedRange)
        let argv = RemoteAgentLaunch.argv(for: host, remoteCommand: command, tunnel: tunnel)

        XCTAssertEqual(argv[0], "/usr/bin/ssh")
        XCTAssertEqual(argv[1], "-tt")
        XCTAssertEqual(Array(argv[2...3]), ["-R", "47110:127.0.0.1:9091"])
        XCTAssertEqual(argv[4], "ci@build.internal")
        XCTAssertEqual(argv.last, command)
        // No ExitOnForwardFailure on the pane: losing the port race must degrade the
        // status, never kill a working agent.
        XCTAssertFalse(argv.contains("ExitOnForwardFailure"))

        // A manual host with a non-default port carries `-p`; an ssh-config host
        // connects by its alias so the user's own config still resolves.
        let ported = HostRecord(name: "box", hostname: "10.0.0.5", user: "dk", port: 2200,
                                source: .manual)
        XCTAssertTrue(RemoteAgentLaunch.argv(for: ported, remoteCommand: "true", tunnel: nil)
            .contains("-p"))
        let alias = HostRecord(name: "build", hostname: "build.internal", user: "ci",
                               port: 2222, source: .sshConfig)
        let aliasArgv = RemoteAgentLaunch.argv(for: alias, remoteCommand: "true", tunnel: nil)
        XCTAssertFalse(aliasArgv.contains("-p"))
        XCTAssertTrue(aliasArgv.contains("build"))
    }

    func testAPaneWithNoTunnelLaunchesTheSameAgentWithNoForward() {
        let command = RemoteAgentLaunch.remoteCommand(
            directory: worktreePath, launch: ClaudeCodeEngine().remoteLaunch!)
        let argv = RemoteAgentLaunch.argv(for: host, remoteCommand: command, tunnel: nil)
        XCTAssertFalse(argv.contains("-R"))
        XCTAssertEqual(argv.last, command)
    }

    func testAnEngineWithNoRemoteLaunchIsRefusedTypedNotApproximated() {
        // The shell engine has its own remote path (a login shell); a launch Orchard
        // cannot describe remotely must never fall back to running it here.
        XCTAssertThrowsError(try RemoteAgentService.requireRemoteLaunch(
            GenericShellEngine(), hostName: "build")) { error in
            XCTAssertEqual((error as? RemoteHostError)?.code, "remote_unsupported")
        }
    }

    // MARK: - Tunnel port

    func testAllocatedPortIsParsedFromOpenSSHsOwnLine() {
        XCTAssertEqual(RemoteHookTunnel.parseAllocatedPort(
            "Allocated port 39735 for remote forward to 127.0.0.1:9091"), 39735)
        XCTAssertEqual(RemoteHookTunnel.parseAllocatedPort(
            "some noise\nAllocated port 41000 for remote forward to 127.0.0.1:1\nmore"), 41000)
        // Never a guess: no line, no port. A guessed port is a hook config that POSTs
        // into nothing while claiming an authoritative channel.
        XCTAssertNil(RemoteHookTunnel.parseAllocatedPort("Allocated port 39735 for local forward"))
        XCTAssertNil(RemoteHookTunnel.parseAllocatedPort("bind: Address already in use"))
        XCTAssertNil(RemoteHookTunnel.parseAllocatedPort(""))
    }

    func testAForwardRefusalIsRecognisedInBothOfOpenSSHsSpellings() {
        XCTAssertTrue(RemoteHookTunnel.isForwardFailure(
            "Warning: remote port forwarding failed for listen port 47110"))
        XCTAssertTrue(RemoteHookTunnel.isForwardFailure(
            "Error: remote port forwarding failed for listen port 47110"))
        XCTAssertFalse(RemoteHookTunnel.isForwardFailure("Permission denied (publickey)."))
    }

    func testTheClaimWalksTheFixedRangeAndTakesTheFirstFreePort() async {
        runner.on("-R 47110:127.0.0.1:9091", forwardRefused(47110))
        runner.on("-R 47111:127.0.0.1:9091", forwardRefused(47111))
        runner.on("-R 47112:127.0.0.1:9091", HostCommandResult(exitCode: 0))
        let outcome = await RemoteHookTunnel.plan(
            runner: SSHRunner(host: host, runner: runner, timeout: 1), localPort: 9091)
        XCTAssertEqual(outcome, .established(RemoteHookTunnel.Plan(
            remotePort: 47112, localPort: 9091, mode: .fixedRange)))
        // The claim is one bounded round trip per candidate and asks for the refusal to
        // be fatal — that is the only way a busy port comes back as a status we can read.
        let claim = runner.commandLines.first { $0.contains("-R 47110") } ?? ""
        XCTAssertTrue(claim.contains("-o ExitOnForwardFailure=yes"), claim)
        XCTAssertTrue(claim.contains("-o BatchMode=yes"), claim)
        XCTAssertTrue(claim.hasSuffix("true"), claim)
    }

    func testAFullRangeFallsBackToDynamicAllocationAndReadsTheAssignedPort() async {
        runner.fallback = forwardRefused(0)
        runner.on("-R 0:127.0.0.1:9091", HostCommandResult(
            exitCode: 0,
            stderr: "Allocated port 51234 for remote forward to 127.0.0.1:9091\n"))
        let outcome = await RemoteHookTunnel.plan(
            runner: SSHRunner(host: host, runner: runner, timeout: 1), localPort: 9091,
            candidates: [47110, 47111])
        XCTAssertEqual(outcome, .established(RemoteHookTunnel.Plan(
            remotePort: 51234, localPort: 9091, mode: .dynamic)))
    }

    func testLossOfContactStopsTheWalkInsteadOfHammeringEveryPort() async {
        // A host that cannot be reached will not become reachable on port 47111, and
        // a transport failure is not evidence about the port at all.
        runner.fallback = transportFailure()
        let outcome = await RemoteHookTunnel.plan(
            runner: SSHRunner(host: host, runner: runner, timeout: 1), localPort: 9091)
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected unavailable, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("Connection refused"), reason)
        XCTAssertEqual(runner.commandLines.count, 1)
    }

    /// Bounded twice, like the connectivity probe: the runner's timeout bounds one
    /// round trip and the deadline bounds their sum, so a slow host cannot turn
    /// `terminal create` into a multi-minute wait for what is only telemetry.
    func testTheClaimIsBoundedAcrossTheWholeWalkNotJustPerAttempt() async {
        let outcome = await RemoteHookTunnel.plan(
            runner: SSHRunner(host: host, runner: runner, timeout: 1), localPort: 9091,
            deadline: 0)
        guard case .unavailable(let reason) = outcome else {
            return XCTFail("expected unavailable, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("within 0s"), reason)
        XCTAssertTrue(runner.commandLines.isEmpty)
        XCTAssertEqual(RemoteAgentService.preflightTimeout, 10,
                       "a preflight round trip must stay far below the git-sized default")
    }

    func testNoLocalHookServerMeansNoTunnelIsEvenAttempted() async {
        let outcome = await RemoteHookTunnel.plan(
            runner: SSHRunner(host: host, runner: runner, timeout: 1), localPort: 0)
        guard case .unavailable = outcome else { return XCTFail("expected unavailable") }
        XCTAssertTrue(runner.commandLines.isEmpty)
    }

    // MARK: - Hook config over ssh

    func testHookConfigIsWrittenOnTheFarSidePointingAtTheTunnelledPort() async throws {
        let config = RemoteHookConfig(runner: SSHRunner(host: host, runner: runner, timeout: 1))
        try await config.install(worktreePath: worktreePath, port: 47110, token: "tok123",
                                 events: ClaudeCodeEngine().hookEvents!)

        let write = try XCTUnwrap(runner.commandLines.first { $0.contains("printf %s") })
        XCTAssertTrue(write.contains("mkdir -p /home/ci/Orchard/worktrees/orchard/apricot/.claude"),
                      write)
        XCTAssertTrue(
            write.contains("> /home/ci/Orchard/worktrees/orchard/apricot/.claude/settings.local.json"),
            write)
        // The hook endpoint is the *remote* loopback, which the reverse tunnel makes
        // true — so the config is what `HookInstaller` would have written locally, port
        // for port. (Slashes arrive JSON-escaped because the payload comes from the
        // same `JSONSerialization` call the local installer uses; identical on purpose.)
        XCTAssertTrue(write.contains("127.0.0.1:47110"), write)
        XCTAssertTrue(write.contains("agent=tok123&event=Stop"), write)
        XCTAssertTrue(write.contains("PostToolUse"), write)
        // …and Orchard's own config stays out of the agent's `git status`.
        XCTAssertTrue(runner.ran("rev-parse --git-path info/exclude"))
        XCTAssertTrue(runner.ran(".claude/settings.local.json"))
    }

    func testHookConfigMergesWithSettingsTheRepoAlreadyHasThere() async throws {
        runner.on("cat /home/ci/Orchard/worktrees/orchard/apricot/.claude/settings.local.json",
                  stdout(#"{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"Old":[]}}"#))
        let config = RemoteHookConfig(runner: SSHRunner(host: host, runner: runner, timeout: 1))
        try await config.install(worktreePath: worktreePath, port: 47110, token: "tok",
                                 events: ["Stop"])
        let write = try XCTUnwrap(runner.commandLines.first { $0.contains("printf %s") })
        // Their settings survive; only `hooks` is ours to own — and ours replaces theirs
        // wholesale so a stale event from a previous run cannot linger.
        XCTAssertTrue(write.contains("Bash(ls:*)"), write)
        XCTAssertFalse(write.contains("\"Old\""), write)
    }

    func testAHostThatDoesNotAnswerTheWriteIsUnverifiableNotAFailedWrite() async {
        runner.on("printf %s", transportFailure())
        let config = RemoteHookConfig(runner: SSHRunner(host: host, runner: runner, timeout: 1))
        do {
            try await config.install(worktreePath: worktreePath, port: 47110, token: "t",
                                     events: ["Stop"])
            XCTFail("expected a throw")
        } catch let error as RemoteHostError {
            XCTAssertEqual(error.code, "host_unverifiable")
            XCTAssertTrue(error.message.contains("not evidence"), error.message)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Typed degradation

    func testAPaneWhoseTunnelCannotBindDegradesToFingerprintsAndSaysSo() async throws {
        runner.fallback = forwardRefused(0)   // every candidate, and the dynamic ask, refused
        let plan = try await RemoteAgentService(host: host, runner: runner, timeout: 1)
            .plan(engine: ClaudeCodeEngine(), worktreePath: worktreePath,
                  hookToken: "tok", localHookPort: 9091)
        XCTAssertEqual(plan.detection.mode, .fingerprintOnly)
        XCTAssertNil(plan.detection.tunnelPort)
        let limitation = try XCTUnwrap(plan.detection.limitation)
        XCTAssertTrue(limitation.contains("fingerprints only"), limitation)
        // The agent still launches — just without a channel home.
        XCTAssertFalse(plan.argv.contains("-R"))
        XCTAssertTrue(plan.remoteCommand.hasSuffix("exec claude'"))
        // And nothing was written on the far side pointing at a port nobody holds.
        XCTAssertFalse(runner.ran("printf %s"))
    }

    func testAConfigWriteTheHostRefusesDegradesRatherThanClaimingHooks() async throws {
        scriptTunnel()
        runner.on("printf %s", HostCommandResult(exitCode: 1, stderr: "sh: Read-only file system\n"))
        let plan = try await RemoteAgentService(host: host, runner: runner, timeout: 1)
            .plan(engine: ClaudeCodeEngine(), worktreePath: worktreePath,
                  hookToken: "tok", localHookPort: 9091)
        // The tunnel would work; the config that uses it does not exist. Reporting
        // hooks here would be the worst answer available.
        XCTAssertEqual(plan.detection.mode, .fingerprintOnly)
        let limitation = try XCTUnwrap(plan.detection.limitation)
        XCTAssertTrue(limitation.contains("remote_hook_install_failed"), limitation)
        XCTAssertFalse(plan.argv.contains("-R"))
    }

    /// T83, found live: the hook install was the first thing to touch the far side, and
    /// it used `mkdir -p` — so on a host where the worktree was gone (removed underneath
    /// the registry, a stale row) it *created* the directory, and the pane's `cd` then
    /// succeeded into an empty one. The agent came up in a directory wearing the
    /// workspace's name with none of its files in it.
    ///
    /// It must create nothing. The launch that follows then fails honestly with the far
    /// side's own `cd: no such file or directory`.
    func testAMissingRemoteWorktreeIsRefusedRatherThanCreated() async throws {
        scriptTunnel()
        runner.on("[ -d \(worktreePath) ]",
                  HostCommandResult(exitCode: 66,
                                    stderr: "orchard-remote-worktree-missing\n"))
        let plan = try await RemoteAgentService(host: host, runner: runner, timeout: 1)
            .plan(engine: ClaudeCodeEngine(), worktreePath: worktreePath,
                  hookToken: "tok", localHookPort: 9091)
        // The pane still opens — a hook install is never fatal — but it says what it
        // lost rather than claiming a channel nothing will POST to.
        XCTAssertEqual(plan.detection.mode, .fingerprintOnly)
        let limitation = try XCTUnwrap(plan.detection.limitation)
        XCTAssertTrue(limitation.contains("remote_worktree_missing"), limitation)
        XCTAssertTrue(limitation.contains(worktreePath), limitation)
        // And the guard runs *before* the mkdir, in the same command, so no round trip
        // can land between the check and the create.
        let write = try XCTUnwrap(runner.commandLines.first { $0.contains("mkdir -p") })
        let guardIndex = try XCTUnwrap(write.range(of: "[ -d \(worktreePath) ]"))
        let mkdirIndex = try XCTUnwrap(write.range(of: "mkdir -p"))
        XCTAssertLessThan(guardIndex.lowerBound, mkdirIndex.lowerBound, write)
    }

    func testAnEngineWithNoHookMechanismIsFingerprintOnlyWithoutTouchingTheHost() async throws {
        let plan = try await RemoteAgentService(host: host, runner: runner, timeout: 1)
            .plan(engine: CodexEngine(), worktreePath: worktreePath,
                  hookToken: "tok", localHookPort: 9091)
        XCTAssertEqual(plan.detection.mode, .fingerprintOnly)
        XCTAssertTrue(plan.remoteCommand.hasSuffix("exec codex'"))
        XCTAssertTrue(runner.commandLines.isEmpty)
    }

    func testAWorkingTunnelAndConfigReportHooks() async throws {
        scriptTunnel()
        let plan = try await RemoteAgentService(host: host, runner: runner, timeout: 1)
            .plan(engine: ClaudeCodeEngine(), worktreePath: worktreePath,
                  hookToken: "tok", localHookPort: 9091)
        XCTAssertEqual(plan.detection.mode, .hooks)
        XCTAssertEqual(plan.detection.tunnelPort, 47110)
        XCTAssertNil(plan.detection.limitation)
        XCTAssertTrue(plan.argv.contains("47110:127.0.0.1:9091"))
    }

    func testARelativeRemotePathIsRefusedBeforeAnythingRuns() async {
        do {
            _ = try await RemoteAgentService(host: host, runner: runner, timeout: 1)
                .plan(engine: ClaudeCodeEngine(), worktreePath: "wt/apricot",
                      hookToken: "t", localHookPort: 9091)
            XCTFail("expected a throw")
        } catch let error as RemoteHostError {
            XCTAssertEqual(error.code, "invalid_argument")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertTrue(runner.commandLines.isEmpty)
    }

    // MARK: - The pane, end to end over the RPC seam

    func testCreatingAnAgentPaneInARemoteWorktreeLaunchesItThereWithLiveStatus() async throws {
        let worktreeID = try await seedRemoteWorktree()
        scriptTunnel()

        let created = await call("terminal-create", ["worktree": .string(worktreeID),
                                                     "engine": .string("claude")])
        XCTAssertTrue(created.ok, String(describing: created.error))
        let summary = try XCTUnwrap(created.result?.objectValue)
        XCTAssertEqual(summary["executionHostId"]?.stringValue, "ssh:build")
        // The pane's engine is the agent's, so fingerprints, `wait --for tui-idle`,
        // verified sends and the agent-state projection all apply — the alias resolves
        // to the canonical id exactly as it does locally.
        XCTAssertEqual(summary["engine"]?.stringValue, "claude-code")
        XCTAssertEqual(summary["statusDetection"]?.objectValue?["mode"]?.stringValue, "hooks")
        XCTAssertEqual(summary["statusDetection"]?.objectValue?["tunnelPort"]?.intValue, 47110)

        let spec = try XCTUnwrap(terminalSpecs.last)
        XCTAssertEqual(spec.executionHostId, "ssh:build")
        // Local PTY, remote child: the argv is `ssh`, with the tunnel, and the local
        // cwd is left alone because a remote path handed to a local chdir either fails
        // or finds a same-named local directory.
        XCTAssertNil(spec.cwd)
        let argv = try XCTUnwrap(spec.launchArgv)
        XCTAssertEqual(argv.first, "/usr/bin/ssh")
        XCTAssertTrue(argv.contains("-R"))
        XCTAssertTrue(argv.contains("47110:127.0.0.1:9091"))
        XCTAssertTrue(argv.last?.contains("cd /home/ci/Orchard/worktrees/orchard/apricot") ?? false,
                      argv.last ?? "")
        XCTAssertTrue(argv.last?.hasSuffix("exec claude'") ?? false, argv.last ?? "")
        // The prompt stays empty: for a `.typeWhenIdle` engine the prompt is what gets
        // TYPED into the agent, and an ssh command line typed into Claude is a message,
        // not a launch.
        XCTAssertEqual(spec.prompt, "")

        // The hook config on the far side carries this pane's own token, and that token
        // is the one subscribed locally — which is what makes the round trip land.
        let token = try XCTUnwrap(spec.hookToken)
        XCTAssertEqual(hookChannel.registered, [token])
        let write = try XCTUnwrap(runner.commandLines.first { $0.contains("printf %s") })
        XCTAssertTrue(write.contains("agent=\(token)"), write)
    }

    func testHooksFromTheFarSideDriveThePanesAgentState() async throws {
        let worktreeID = try await seedRemoteWorktree()
        scriptTunnel()
        let created = await call("terminal-create", ["worktree": .string(worktreeID),
                                                     "engine": .string("claude-code")])
        let handle = try XCTUnwrap(created.result?.objectValue?["handle"]?.stringValue)
        let token = try XCTUnwrap(terminalSpecs.last?.hookToken)

        hookChannel.deliver(token: token, event: "PreToolUse")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(try terminals.summary(handle: handle).agentState, .working)

        hookChannel.deliver(token: token, event: "Stop")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(try terminals.summary(handle: handle).agentState, .idle)
    }

    func testAPaneThatLostItsTunnelCarriesTheLimitationOnItsSummary() async throws {
        let worktreeID = try await seedRemoteWorktree()
        runner.on("-R ", forwardRefused(47110))   // every candidate and the dynamic ask

        let created = await call("terminal-create", ["worktree": .string(worktreeID),
                                                     "engine": .string("claude-code")])
        XCTAssertTrue(created.ok, String(describing: created.error))
        let detection = try XCTUnwrap(created.result?.objectValue?["statusDetection"]?.objectValue)
        XCTAssertEqual(detection["mode"]?.stringValue, "fingerprint-only")
        let limitation = try XCTUnwrap(detection["limitation"]?.stringValue)
        XCTAssertTrue(limitation.contains("build"), limitation)
        XCTAssertTrue(limitation.contains("fingerprints only"), limitation)
        // Nothing subscribed: a pane with no config on the far side has no token that
        // anything will ever POST.
        XCTAssertTrue(hookChannel.registered.isEmpty)
        // The agent still launched.
        XCTAssertFalse(try XCTUnwrap(terminalSpecs.last?.launchArgv).contains("-R"))
    }

    func testARespawnKeepsTheRemoteInvocationAndTheHookTokenItAlreadyWrote() async throws {
        let worktreeID = try await seedRemoteWorktree()
        scriptTunnel()
        _ = await call("terminal-create", ["worktree": .string(worktreeID),
                                           "engine": .string("claude-code")])
        let first = try XCTUnwrap(terminalSpecs.last)
        _ = try terminals.respawn(paneKey: first.paneKey)
        let second = try XCTUnwrap(terminalSpecs.last)
        // Dropping either would reopen the pane as something else: a local shell (argv)
        // or a statusless agent whose config on the far side names a token nobody holds.
        XCTAssertEqual(second.launchArgv, first.launchArgv)
        XCTAssertEqual(second.hookToken, first.hookToken)
        XCTAssertEqual(second.statusDetection, first.statusDetection)
        // And the token re-subscribes: the far side's config still names it, but the
        // session it routed to was just replaced.
        XCTAssertEqual(hookChannel.registered, [first.hookToken, second.hookToken].compactMap { $0 })
        let handle = try XCTUnwrap(terminals.list().first?.handle)
        hookChannel.deliver(token: try XCTUnwrap(second.hookToken), event: "PreToolUse")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(try terminals.summary(handle: handle).agentState, .working)
    }

    func testAnEngineOrchardCannotLaunchRemotelyIsRefusedWithNothingSpawned() async throws {
        let worktreeID = try await seedRemoteWorktree()
        // `--host ssh:<name>` alone still refuses: a remote agent needs a remote
        // worktree, because that is where its hook config lives.
        let hostOnly = await call("terminal-create", ["host": .string("ssh:build"),
                                                      "engine": .string("claude-code")])
        XCTAssertEqual(hostOnly.error?.code, "not_implemented")
        // An unknown engine never reaches the host at all.
        let unknown = await call("terminal-create", ["worktree": .string(worktreeID),
                                                     "engine": .string("nonesuch")])
        XCTAssertEqual(unknown.error?.code, "unknown_engine")
        XCTAssertTrue(terminalSpecs.isEmpty)
    }
}
