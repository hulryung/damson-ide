import Combine
import DamsonTerminal
import Foundation
import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// A hook channel that binds nothing; the port is a number the restoration path reads.
private final class PortStubHookChannel: AgentHookChannel, @unchecked Sendable {
    let localHookPort: UInt16
    private(set) var registered: [String] = []

    init(port: UInt16) { self.localHookPort = port }

    func register(token: String, handler: @escaping @Sendable (String, Data) -> Void) {
        registered.append(token)
    }

    func unregister(token: String) {}
}

/// A scripted session that yields a keeper handoff once, so a pane created through the
/// RPC seam can be released into a restoration record without a real PTY.
@MainActor
private final class ReleasableSession: TerminalSession {
    private let inner: ScriptedTerminalSession
    private var handoff: KeeperPTYHandoff?

    init(config: DamsonConfig) {
        self.inner = ScriptedTerminalSession(config: config)
        self.handoff = KeeperPTYHandoff(fd: -1, pid: 909, startSec: 7, startUsec: 8,
                                        cwd: nil, tail: Data())
    }

    func releaseForKeeperHandoff() -> KeeperPTYHandoff? {
        defer { handoff = nil }
        return handoff
    }

    func write(_ data: Data) { inner.write(data) }
    func gridSnapshot() -> TerminalGridSnapshot { inner.gridSnapshot() }
    var config: DamsonConfig { inner.config }
    func updateConfig(_ config: DamsonConfig) { inner.updateConfig(config) }
    func terminate() { inner.terminate() }
    var processExited: Bool { inner.processExited }
    var exitCode: Int32? { inner.exitCode }
    var bracketedPasteEnabled: Bool { inner.bracketedPasteEnabled }
    var hasRunningForegroundJob: Bool { inner.hasRunningForegroundJob }
    var gridChanged: AnyPublisher<Void, Never> { inner.gridChanged }
    var outputEvents: AnyPublisher<TerminalOutputEvent, Never> { inner.outputEvents }
    var outputBytes: AnyPublisher<Data, Never> { inner.outputBytes }
    var onExit: ((Int32) -> Void)? {
        get { inner.onExit }
        set { inner.onExit = newValue }
    }
}

private func ok(_ text: String = "") -> HostCommandResult {
    HostCommandResult(exitCode: 0, stdout: text)
}

/// T43 — SSH stage 4 over the RPC seam: a remote agent pane created the way the runtime
/// really creates one, handed off, restored into a *second* app instance, and reopened
/// through `terminal-reconnect`.
///
/// Everything rides the scripted `ssh` runner and a keeper-free release/adopt: no host,
/// no network, no fd. What that cannot prove is listed on the honest-scope note in the
/// task report — principally that a real `sshd` grants the reverse forward again on a
/// reconnect, and that a real Claude Code on the far side keeps POSTing through a
/// forward whose local end was rebound under it.
@MainActor
final class RemotePaneReconnectTests: XCTestCase {
    private var tmp: URL!
    private var store: OrchardDataStore!
    private var workspaces: WorkspaceService!
    private var runner: ScriptedSSHRunner!
    private var hosts: HostRegistry!
    private var hookChannel: PortStubHookChannel!
    private var terminals: TerminalService!
    private var server: InMemoryRuntimeServer!
    private var specs: [TerminalCreateSpec] = []
    private var sessions: [ReleasableSession] = []

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

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-remote-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
        runner = ScriptedSSHRunner()
        hosts = HostRegistry(store: store, sshConfig: { [] })
        try hosts.add(name: "build", hostname: "build.internal", user: "ci", port: nil)
        workspaces = WorkspaceService(store: store,
                                      worktreesRoot: tmp.appendingPathComponent("wt"))
        workspaces.hostCommandRunner = runner
        workspaces.remoteCommandTimeout = 1
        hookChannel = PortStubHookChannel(port: 9091)
        (terminals, server) = makeStack(hookChannel: hookChannel)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// One app instance's terminal service plus the RPC surface in front of it. Called
    /// twice per restart test: the second stack is the next app instance.
    private func makeStack(hookChannel: PortStubHookChannel?)
        -> (TerminalService, InMemoryRuntimeServer) {
        let service = TerminalService(factory: { [weak self] spec, engine in
            var config = DamsonConfig()
            config.argv = spec.launchArgv ?? [spec.prompt]
            config.cwd = spec.cwd
            let session = ReleasableSession(config: config)
            self?.specs.append(spec)
            self?.sessions.append(session)
            return session
        })
        service.hookChannel = hookChannel
        var registry = CommandRegistry()
        registry.register(RepoRegistryHandler(service: workspaces))
        registry.register(WorkspaceCommandHandler(service: workspaces))
        registry.register(TerminalCommandHandler(service: service, workspaces: workspaces,
                                                 hosts: hosts, hookChannel: hookChannel,
                                                 hostRunner: runner))
        registry.register(RemotePaneReconnectHandler(service: service, hosts: hosts))
        return (service, InMemoryRuntimeServer(registry: registry, runtimeId: "rt_restore"))
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:],
                      on server: InMemoryRuntimeServer? = nil) async -> RPCResponse {
        await (server ?? self.server).perform(RPCRequest(method: method,
                                                         params: .object(params)))
    }

    @discardableResult
    private func seedRemoteWorktree() async throws -> String {
        runner.on("test -d /srv/work/orchard/.git", ok())
        runner.on("for-each-ref '--format=%(refname)' refs/remotes", ok("refs/remotes/origin/main\n"))
        runner.on("worktree list --porcelain", ok(porcelain))
        let added = await call("repo-add", ["path": .string(repoPath),
                                            "host": .string("ssh:build")])
        XCTAssertTrue(added.ok, String(describing: added.error))
        let repo = try XCTUnwrap(workspaces.listRepos().first)
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        return "\(repo.id)::\(worktreePath)"
    }

    private func scriptTunnel(port: UInt16 = 47110, localPort: UInt16 = 9091) {
        runner.on("-R \(port):127.0.0.1:\(localPort)", HostCommandResult(exitCode: 0))
    }

    /// A live remote agent pane, created exactly the way the runtime creates one.
    @discardableResult
    private func createRemoteAgentPane() async throws -> [String: JSONValue] {
        let worktreeID = try await seedRemoteWorktree()
        scriptTunnel()
        let created = await call("terminal-create", ["worktree": .string(worktreeID),
                                                     "engine": .string("claude-code")])
        XCTAssertTrue(created.ok, String(describing: created.error))
        return try XCTUnwrap(created.result?.objectValue)
    }

    // MARK: - The record, from a pane the RPC seam really built

    func testAReleasedRemotePaneCarriesHostDirectoryArgvAndTunnelThroughItsJSON() async throws {
        let summary = try await createRemoteAgentPane()
        let token = try XCTUnwrap(specs.last?.hookToken)

        let released = terminals.releaseForKeeperHandoff()
        XCTAssertEqual(released.count, 1)
        let pane = try XCTUnwrap(released.first).paneRecord

        XCTAssertEqual(pane.paneKey, summary["paneKey"]?.stringValue)
        XCTAssertEqual(pane.executionHostId, "ssh:build")
        let remote = try XCTUnwrap(pane.remote)
        // The far side's directory — the fact a local `cwd` deliberately does not hold.
        XCTAssertEqual(remote.remoteCwd, worktreePath)
        XCTAssertNil(pane.cwd, "the local PTY's cwd is only where ssh was launched from")
        let argv = try XCTUnwrap(remote.launchArgv)
        XCTAssertEqual(argv.first, "/usr/bin/ssh")
        XCTAssertTrue(argv.contains("47110:127.0.0.1:9091"), argv.joined(separator: " "))
        XCTAssertTrue(argv.last?.hasSuffix("exec claude'") ?? false, argv.last ?? "")
        XCTAssertEqual(remote.tunnel, KeeperTunnelRecord(remotePort: 47110, localPort: 9091))
        XCTAssertEqual(pane.hookToken, token)

        // Everything survives the file it is persisted as.
        let url = tmp.appendingPathComponent("keeper-restoration.json")
        try KeeperRestorationStore.save(
            KeeperRestorationState(generation: "gen-1", panes: [pane]), to: url)
        let reloaded = try XCTUnwrap(KeeperRestorationStore.loadAndDelete(at: url))
        XCTAssertEqual(reloaded.panes, [pane])
    }

    // MARK: - The next app instance

    func testTheNextInstanceRebindsTheSurvivingForwardsLocalPort() async throws {
        try await createRemoteAgentPane()
        let pane = try XCTUnwrap(terminals.releaseForKeeperHandoff().first).paneRecord

        // Same port back: the still-open `ssh` keeps forwarding to it, so the far
        // side's already-installed hook config keeps landing here.
        let next = PortStubHookChannel(port: 9091)
        let (service, _) = makeStack(hookChannel: next)
        let restored = try service.adoptKeeperRestored(pane: pane,
                                                       session: ScriptedTerminalSession())

        XCTAssertEqual(restored.executionHostId, "ssh:build")
        XCTAssertEqual(restored.incarnation, pane.incarnation + 1)
        XCTAssertEqual(restored.statusDetection?.mode, .hooks)
        XCTAssertEqual(restored.statusDetection?.tunnelPort, 47110)
        XCTAssertEqual(next.registered, [pane.hookToken].compactMap { $0 })
    }

    func testAPortLostDuringTheRestartDegradesTypedOnTheSummary() async throws {
        try await createRemoteAgentPane()
        let pane = try XCTUnwrap(terminals.releaseForKeeperHandoff().first).paneRecord

        // Something else took 9091 while we were down; the hook server landed on 40404
        // and the surviving `ssh` cannot be re-pointed at it.
        let next = PortStubHookChannel(port: 40404)
        let (service, server) = makeStack(hookChannel: next)
        _ = try service.adoptKeeperRestored(pane: pane, session: ScriptedTerminalSession())

        let listed = await call("terminal-list", [:], on: server)
        let row = try XCTUnwrap(listed.result?.objectValue?["terminals"]?.arrayValue?.first?
            .objectValue)
        XCTAssertEqual(row["executionHostId"]?.stringValue, "ssh:build",
                       "a degraded pane is still a remote pane")
        let detection = try XCTUnwrap(row["statusDetection"]?.objectValue)
        XCTAssertEqual(detection["mode"]?.stringValue, "fingerprint-only")
        let limitation = try XCTUnwrap(detection["limitation"]?.stringValue)
        XCTAssertTrue(limitation.contains("9091"), limitation)
        XCTAssertTrue(limitation.contains("build"), limitation)
        XCTAssertTrue(limitation.contains("fingerprints only"), limitation)
        // Nothing subscribed: an idle it could never confirm is the worst answer here.
        XCTAssertTrue(next.registered.isEmpty)
    }

    // MARK: - Reconnect over the wire

    func testReconnectReopensTheRecordedInvocationUnderTheSamePaneKey() async throws {
        try await createRemoteAgentPane()
        let pane = try XCTUnwrap(terminals.releaseForKeeperHandoff().first).paneRecord

        // This instance's hook server bound a different port, and the pane's `ssh`
        // ended while we were gone.
        let next = PortStubHookChannel(port: 55055)
        let (service, server) = makeStack(hookChannel: next)
        let ended = try service.adoptEndedRemote(pane: pane)
        XCTAssertFalse(ended.connected)

        specs.removeAll()
        let response = await call("terminal-reconnect", ["pane": .string(pane.paneKey)],
                                  on: server)
        XCTAssertTrue(response.ok, String(describing: response.error))
        let result = try XCTUnwrap(response.result?.objectValue)
        let terminal = try XCTUnwrap(result["terminal"]?.objectValue)
        XCTAssertEqual(terminal["paneKey"]?.stringValue, pane.paneKey, "same pane")
        XCTAssertEqual(terminal["incarnation"]?.intValue, pane.incarnation + 2,
                       "a reconnect is a new PTY channel and says so")
        XCTAssertEqual(terminal["executionHostId"]?.stringValue, "ssh:build")
        XCTAssertEqual(terminal["connected"]?.boolValue, true)

        let reconnect = try XCTUnwrap(result["reconnect"]?.objectValue)
        XCTAssertEqual(reconnect["tunnelled"]?.boolValue, true)
        let note = try XCTUnwrap(reconnect["note"]?.stringValue)
        // Verdict language: a new connection, and no claim about what the old one left.
        XCTAssertTrue(note.contains("new connection"), note)
        XCTAssertTrue(note.contains("unverified"), note)

        // Spec fidelity: same host, same remote directory, same agent, same token —
        // with only the forward's LOCAL end moved to the port this instance holds.
        let spec = try XCTUnwrap(specs.last)
        XCTAssertEqual(spec.remoteCwd, worktreePath)
        XCTAssertEqual(spec.hookToken, pane.hookToken)
        let argv = try XCTUnwrap(spec.launchArgv)
        XCTAssertTrue(argv.contains("47110:127.0.0.1:55055"), argv.joined(separator: " "))
        XCTAssertFalse(argv.contains("47110:127.0.0.1:9091"))
        XCTAssertEqual(argv.last, pane.remote?.launchArgv?.last, "the far side is untouched")
        XCTAssertEqual(next.registered, [pane.hookToken].compactMap { $0 })
    }

    func testReconnectRefusesAPaneWhoseHostLeftTheRegistry() async throws {
        try await createRemoteAgentPane()
        let pane = try XCTUnwrap(terminals.releaseForKeeperHandoff().first).paneRecord
        let (service, _) = makeStack(hookChannel: PortStubHookChannel(port: 9091))
        _ = try service.adoptEndedRemote(pane: pane)

        // The pane stays inspectable when its host record is gone (design §5, rule 3);
        // what it loses is permission to dial that name again.
        let emptyHosts = HostRegistry(
            store: OrchardDataStore(url: tmp.appendingPathComponent("other.json")),
            sshConfig: { [] })
        var registry = CommandRegistry()
        registry.register(RemotePaneReconnectHandler(service: service, hosts: emptyHosts))
        let hostless = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_hostless")

        let spawnsBefore = specs.count
        let response = await call("terminal-reconnect", ["pane": .string(pane.paneKey)],
                                  on: hostless)
        XCTAssertEqual(response.error?.code, "unknown_host")
        XCTAssertEqual(specs.count, spawnsBefore, "the refusal came before any spawn")
    }

    func testReconnectRefusesALiveRemotePaneAndALocalOne() async throws {
        let summary = try await createRemoteAgentPane()
        let handle = try XCTUnwrap(summary["handle"]?.stringValue)

        // Live: reopening would tear down a working connection to a machine we cannot
        // see — the trade rule 2 exists to prevent.
        let live = await call("terminal-reconnect", ["terminal": .string(handle)])
        XCTAssertEqual(live.error?.code, "invalid_argument")
        XCTAssertTrue(live.error?.message.contains("still connected") ?? false,
                      live.error?.message ?? "")

        let local = await call("terminal-create", [:])
        let localHandle = try XCTUnwrap(local.result?.objectValue?["handle"]?.stringValue)
        let refused = await call("terminal-reconnect", ["terminal": .string(localHandle)])
        XCTAssertEqual(refused.error?.code, "invalid_argument")
        XCTAssertTrue(refused.error?.message.contains("this machine") ?? false,
                      refused.error?.message ?? "")

        let unaddressed = await call("terminal-reconnect", [:])
        XCTAssertEqual(unaddressed.error?.code, "invalid_argument")
        let missing = await call("terminal-reconnect", ["pane": .string("tab_none:leaf")])
        XCTAssertEqual(missing.error?.code, "terminal_not_found")
    }
}
