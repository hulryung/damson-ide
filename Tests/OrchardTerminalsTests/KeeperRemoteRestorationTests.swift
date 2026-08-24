import Combine
import DamsonTerminal
import Foundation
import XCTest
@testable import OrchardTerminals

/// A scripted session that can play the keeper-handoff side of the seam, with a
/// settable `config.argv` so a remote pane's real spawn argv can be read back out of
/// the restoration record.
@MainActor
private final class HandoffFakeSession: TerminalSession {
    private let inner: ScriptedTerminalSession
    var scriptedHandoff: KeeperPTYHandoff?

    init(config: DamsonConfig = DamsonConfig()) {
        self.inner = ScriptedTerminalSession(config: config)
        self.scriptedHandoff = KeeperPTYHandoff(fd: -1, pid: 4242, startSec: 1, startUsec: 2,
                                                cwd: nil, tail: Data())
    }

    func releaseForKeeperHandoff() -> KeeperPTYHandoff? {
        defer { scriptedHandoff = nil }
        return scriptedHandoff
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
    func exit(code: Int32) { inner.exit(code: code) }
}

/// A hook channel that binds nothing: the port is a *number* the restoration path
/// reads and compares, and no test needs a listening socket to pin what it does with
/// two numbers that differ.
private final class FakeHookChannel: AgentHookChannel, @unchecked Sendable {
    let localHookPort: UInt16
    private(set) var registered: [String] = []

    init(port: UInt16) { self.localHookPort = port }

    func register(token: String, handler: @escaping @Sendable (String, Data) -> Void) {
        registered.append(token)
    }

    func unregister(token: String) {}
}

/// T43 — SSH stage 4: restoring the rest of a remote pane's identity across a restart.
///
/// The keeper already keeps the `ssh` child alive (T23). What is proved here is what
/// the child alone cannot carry: the host stamp, the remote directory, the invocation,
/// the hook token, and the two ports the status channel runs between — plus the two
/// forks that follow from them, rebind versus typed degradation, and a reconnect built
/// from the pane's own recorded spec.
@MainActor
final class KeeperRemoteRestorationTests: XCTestCase {

    private let remotePath = "/home/ci/Orchard/worktrees/orchard/apricot"
    private let claudeID = "claude-code"

    /// The argv a T39 remote agent pane actually runs.
    private func remoteArgv(remotePort: UInt16 = 47110, localPort: UInt16 = 9091) -> [String] {
        ["/usr/bin/ssh", "-tt", "-R", "\(remotePort):127.0.0.1:\(localPort)", "ci@build.internal",
         "cd '\(remotePath)' && unset CLAUDECODE && exec claude"]
    }

    private func makeService(hookPort: UInt16?,
                             session: @escaping @MainActor () -> TerminalSession)
        -> (TerminalService, FakeHookChannel?) {
        let channel = hookPort.map { FakeHookChannel(port: $0) }
        let service = TerminalService(factory: { _, _ in session() })
        service.hookChannel = channel
        return (service, channel)
    }

    /// One live remote agent pane, released for handoff.
    private func releasedRemoteAgentPane(
        localHookPort: UInt16 = 9091, remotePort: UInt16 = 47110
    ) throws -> (record: KeeperPaneRecord, summary: TerminalSummary) {
        var config = DamsonConfig()
        config.argv = remoteArgv(remotePort: remotePort, localPort: localHookPort)
        let fake = HandoffFakeSession(config: config)
        let (service, _) = makeService(hookPort: localHookPort, session: { fake })
        let summary = try service.create(
            worktreeId: "repo_1::\(remotePath)", cwd: nil, engineID: claudeID,
            prompt: "", title: "apricot", executionHostId: "ssh:build",
            launchArgv: config.argv, hookToken: "tok-remote",
            statusDetection: .hooks(tunnelPort: Int(remotePort)),
            remoteCwd: remotePath)
        let released = service.releaseForKeeperHandoff()
        XCTAssertEqual(released.count, 1)
        return (try XCTUnwrap(released.first).paneRecord, summary)
    }

    // MARK: - The record

    func testReleaseRecordsHostRemoteCwdArgvAndTunnel() throws {
        let (pane, summary) = try releasedRemoteAgentPane()

        XCTAssertEqual(pane.paneKey, summary.paneKey)
        // Rule 1: the stamp travels. A restored pane that lost it reads as local, and
        // local is the one answer that must never be guessed.
        XCTAssertEqual(pane.executionHostId, "ssh:build")
        XCTAssertTrue(pane.isRemote)
        let remote = try XCTUnwrap(pane.remote)
        XCTAssertEqual(remote.remoteCwd, remotePath)
        XCTAssertEqual(remote.launchArgv, remoteArgv())
        XCTAssertNil(remote.launchPrompt, "an agent pane launches from argv, not a prompt")
        XCTAssertEqual(remote.tunnel, KeeperTunnelRecord(remotePort: 47110, localPort: 9091))
        XCTAssertEqual(remote.statusDetection?.mode, .hooks)
        // The token the far side's config already names — reminting it would restore
        // the pane as a different, statusless agent.
        XCTAssertEqual(pane.hookToken, "tok-remote")
    }

    func testTheLocalPortComesFromTheLiveChannelNotTheRecordedDetection() throws {
        // The detection only carries the REMOTE port. The local one is whatever this
        // app instance's hook server bound, because that is the number the surviving
        // `ssh` keeps forwarding to.
        let (pane, _) = try releasedRemoteAgentPane(localHookPort: 51000, remotePort: 47115)
        XCTAssertEqual(pane.remote?.tunnel,
                       KeeperTunnelRecord(remotePort: 47115, localPort: 51000))
    }

    func testAPaneWithNoHookChannelRecordsNoTunnelButKeepsItsLimitation() throws {
        var config = DamsonConfig()
        config.argv = ["/usr/bin/ssh", "-tt", "ci@build.internal", "cd '/x' && exec claude"]
        let fake = HandoffFakeSession(config: config)
        let (service, _) = makeService(hookPort: nil, session: { fake })
        _ = try service.create(
            engineID: claudeID, executionHostId: "ssh:build", launchArgv: config.argv,
            statusDetection: .fingerprintOnly("No hook tunnel to build — every candidate "
                                              + "port was in use."),
            remoteCwd: "/x")

        let pane = try XCTUnwrap(service.releaseForKeeperHandoff().first).paneRecord
        XCTAssertNil(pane.remote?.tunnel)
        XCTAssertEqual(pane.remote?.statusDetection?.mode, .fingerprintOnly)
    }

    func testALocalPaneRecordsNoRemoteBlockAtAll() throws {
        let fake = HandoffFakeSession()
        let (service, _) = makeService(hookPort: 9091, session: { fake })
        _ = try service.create(cwd: "/tmp", engineID: "shell")
        let pane = try XCTUnwrap(service.releaseForKeeperHandoff().first).paneRecord
        XCTAssertNil(pane.remote)
        XCTAssertEqual(pane.executionHostId, "local")
        XCTAssertFalse(pane.isRemote)
    }

    func testTheRecordSurvivesTheJSONItIsPersistedAs() throws {
        let (pane, _) = try releasedRemoteAgentPane()
        let state = KeeperRestorationState(generation: "gen-1", panes: [pane])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-remote-\(UUID().uuidString).json")
        try KeeperRestorationStore.save(state, to: url)
        let loaded = try XCTUnwrap(KeeperRestorationStore.loadAndDelete(at: url))

        XCTAssertEqual(loaded.panes.first?.remote, pane.remote)
        XCTAssertEqual(loaded.panes.first, pane)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the restoration file is one-shot")
    }

    func testAStateFileFromBeforeStage4StillDecodesAsLocalPanes() throws {
        // The remote block is optional precisely so a quit written by an older build
        // does not fail to decode — which would send every held child a SIGHUP.
        let json = """
            {"generation":"g","savedAt":"2026-08-24T00:00:00Z","panes":[
              {"keeperUUID":"k","paneKey":"tab_1:leaf","incarnation":1,"engineID":"shell",
               "argv":["/bin/zsh"],"preambleBase64":"","cols":80,"rows":24}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(KeeperRestorationState.self, from: Data(json.utf8))
        XCTAssertEqual(state.panes.first?.executionHostId, "local")
        XCTAssertNil(state.panes.first?.remote)
    }

    // MARK: - Rebind vs degradation

    func testAdoptingRebindsTheTunnelWhenTheOldLocalPortCameBack() throws {
        let (pane, _) = try releasedRemoteAgentPane(localHookPort: 9091)
        let (service, channel) = makeService(hookPort: 9091,
                                             session: { ScriptedTerminalSession() })
        let restored = try service.adoptKeeperRestored(pane: pane,
                                                       session: ScriptedTerminalSession())

        XCTAssertEqual(restored.paneKey, pane.paneKey)
        XCTAssertEqual(restored.incarnation, pane.incarnation + 1)
        XCTAssertEqual(restored.executionHostId, "ssh:build")
        XCTAssertEqual(restored.statusDetection?.mode, .hooks)
        XCTAssertEqual(restored.statusDetection?.tunnelPort, 47110)
        XCTAssertNil(restored.statusDetection?.limitation)
        // The surviving CLI's POSTs route to the restored pane because the token is
        // the one its config already names.
        XCTAssertEqual(channel?.registered, ["tok-remote"])
    }

    func testAdoptingDegradesTypedWhenTheLocalPortWasTakenDuringTheRestart() throws {
        let (pane, _) = try releasedRemoteAgentPane(localHookPort: 9091)
        // Something else holds 9091 now, so the hook server landed elsewhere. The
        // surviving `ssh` still forwards to 9091 — nothing can move it.
        let (service, channel) = makeService(hookPort: 61000,
                                             session: { ScriptedTerminalSession() })
        let restored = try service.adoptKeeperRestored(pane: pane,
                                                       session: ScriptedTerminalSession())

        XCTAssertEqual(restored.executionHostId, "ssh:build", "the pane is still remote")
        XCTAssertEqual(restored.statusDetection?.mode, .fingerprintOnly)
        let limitation = try XCTUnwrap(restored.statusDetection?.limitation)
        XCTAssertTrue(limitation.contains("9091"), limitation)
        XCTAssertTrue(limitation.contains("61000"), limitation)
        XCTAssertTrue(limitation.contains("fingerprints only"), limitation)
        // A pane with no channel never subscribes a token nothing will POST to.
        XCTAssertEqual(channel?.registered, [])
    }

    func testAdoptingDegradesWhenNoHookServerIsListeningAtAll() throws {
        let (pane, _) = try releasedRemoteAgentPane()
        let (service, _) = makeService(hookPort: nil, session: { ScriptedTerminalSession() })
        let restored = try service.adoptKeeperRestored(pane: pane,
                                                       session: ScriptedTerminalSession())
        XCTAssertEqual(restored.statusDetection?.mode, .fingerprintOnly)
        XCTAssertTrue(try XCTUnwrap(restored.statusDetection?.limitation)
            .contains("not listening"))
    }

    func testResolveIsPureAndDecidesOnTheRecordedPortNotMerelyOnHavingOne() throws {
        let (pane, _) = try releasedRemoteAgentPane(localHookPort: 9091, remotePort: 47112)
        XCTAssertEqual(KeeperRemoteRestoration.resolve(pane: pane, boundLocalPort: 9091).channel,
                       .rebound(localPort: 9091))
        if case .degraded = KeeperRemoteRestoration.resolve(pane: pane,
                                                           boundLocalPort: 9092).channel {} else {
            XCTFail("a hook server on a different port is not this pane's channel")
        }
        var local = pane
        local.remote = nil
        XCTAssertEqual(KeeperRemoteRestoration.resolve(pane: local, boundLocalPort: 9091).channel,
                       .notRemote)
    }

    // MARK: - Remote shell panes

    func testARestoredRemoteShellKeepsTheCommandLineThatMakesItRemote() throws {
        let commandLine = "/usr/bin/ssh -tt ci@build.internal 'cd /srv && exec \"$SHELL\" -l'"
        var config = DamsonConfig()
        config.argv = ["/bin/zsh", "-l", "-c", commandLine]
        let fake = HandoffFakeSession(config: config)
        let (service, _) = makeService(hookPort: nil, session: { fake })
        _ = try service.create(worktreeId: "repo_1::/srv", engineID: "shell",
                               prompt: commandLine, executionHostId: "ssh:build",
                               remoteCwd: "/srv")

        let pane = try XCTUnwrap(service.releaseForKeeperHandoff().first).paneRecord
        XCTAssertEqual(pane.remote?.launchPrompt, commandLine)

        // The prompt IS the launch for a shell pane, so the restored pane has to carry
        // it: a respawn that lost it would reopen the pane as a LOCAL shell, silently
        // relocating the work.
        var specs: [TerminalCreateSpec] = []
        let next = TerminalService(factory: { spec, _ in
            specs.append(spec)
            return ScriptedTerminalSession()
        })
        let restored = try next.adoptKeeperRestored(pane: pane,
                                                    session: ScriptedTerminalSession())
        XCTAssertEqual(restored.executionHostId, "ssh:build")
        _ = try next.respawn(paneKey: pane.paneKey)
        XCTAssertEqual(specs.last?.prompt, commandLine)
        XCTAssertEqual(specs.last?.executionHostId, "ssh:build")
        XCTAssertEqual(specs.last?.remoteCwd, "/srv")
    }

    // MARK: - A connection that ended while the app was gone

    func testAnEndedRemotePaneComesBackInspectableWithNoExitStatus() throws {
        let (pane, _) = try releasedRemoteAgentPane()
        let (service, _) = makeService(hookPort: 9091, session: { ScriptedTerminalSession() })
        let restored = try service.adoptEndedRemote(pane: pane)

        XCTAssertEqual(restored.paneKey, pane.paneKey)
        XCTAssertEqual(restored.incarnation, pane.incarnation + 1)
        XCTAssertEqual(restored.executionHostId, "ssh:build")
        XCTAssertFalse(restored.connected)
        XCTAssertFalse(restored.writable)
        XCTAssertEqual(service.endedRemotePane()?.paneKey, pane.paneKey)
    }

    func testAnEndedRemotePaneReportsNoExitStatusRatherThanAFabricatedZero() async throws {
        let (pane, _) = try releasedRemoteAgentPane()
        let (service, _) = makeService(hookPort: 9091, session: { ScriptedTerminalSession() })
        let restored = try service.adoptEndedRemote(pane: pane)
        let waited = try await service.wait(handle: restored.handle, for: .exit, timeout: 1)

        XCTAssertTrue(waited.satisfied)
        // The status nobody reported stays absent. `HostLiveness.verdictForPTYEnd`
        // reads a nil status as `unverifiable`; a synthesized 0 would read as "the
        // remote command exited cleanly" — a death certificate for work nobody saw.
        XCTAssertNil(waited.exitCode)
    }

    func testALocalPaneIsNotAdoptableAsAnEndedRemoteOne() throws {
        let fake = HandoffFakeSession()
        let (service, _) = makeService(hookPort: nil, session: { fake })
        _ = try service.create(engineID: "shell")
        let pane = try XCTUnwrap(service.releaseForKeeperHandoff().first).paneRecord
        XCTAssertThrowsError(try service.adoptEndedRemote(pane: pane)) { error in
            XCTAssertEqual((error as? TerminalServiceError)?.code, "invalid_argument")
        }
    }

    // MARK: - Reconnect

    func testReconnectRelaunchesTheRecordedInvocationWithTheTunnelRepointed() throws {
        let (pane, _) = try releasedRemoteAgentPane(localHookPort: 9091)
        var specs: [TerminalCreateSpec] = []
        let channel = FakeHookChannel(port: 55055)
        let service = TerminalService(factory: { spec, _ in
            specs.append(spec)
            return ScriptedTerminalSession()
        })
        service.hookChannel = channel
        _ = try service.adoptEndedRemote(pane: pane)

        let reconnected = try service.reconnectRemote(paneKey: pane.paneKey)

        XCTAssertEqual(reconnected.paneKey, pane.paneKey, "same pane")
        XCTAssertEqual(reconnected.incarnation, pane.incarnation + 2,
                       "a reconnect is a new PTY channel, and says so")
        XCTAssertEqual(reconnected.executionHostId, "ssh:build")
        XCTAssertTrue(reconnected.connected)

        let spec = try XCTUnwrap(specs.last)
        // Same host, same remote directory, same agent — rebuilt from the pane's own
        // record rather than from anything the caller supplied.
        XCTAssertEqual(spec.remoteCwd, remotePath)
        XCTAssertEqual(spec.launchArgv?.last, remoteArgv().last)
        XCTAssertEqual(spec.hookToken, "tok-remote", "the far side's config still names it")
        // The forward is re-pointed at the port this app instance actually bound; the
        // remote listen port (which the far side's config names) is unchanged.
        XCTAssertEqual(spec.launchArgv?[3], "47110:127.0.0.1:55055")
        XCTAssertEqual(reconnected.statusDetection?.mode, .hooks)
        XCTAssertEqual(reconnected.statusDetection?.tunnelPort, 47110)
        XCTAssertEqual(channel.registered, ["tok-remote"])
    }

    func testReconnectWithNoHookServerDropsTheForwardInsteadOfPointingItAtNothing() throws {
        let (pane, _) = try releasedRemoteAgentPane()
        var specs: [TerminalCreateSpec] = []
        let service = TerminalService(factory: { spec, _ in
            specs.append(spec)
            return ScriptedTerminalSession()
        })
        _ = try service.adoptEndedRemote(pane: pane)
        let reconnected = try service.reconnectRemote(paneKey: pane.paneKey)

        let argv = try XCTUnwrap(specs.last?.launchArgv)
        XCTAssertFalse(argv.contains("-R"), "an -R into nothing is worse than none")
        XCTAssertEqual(argv.last, remoteArgv().last, "the agent launches identically")
        XCTAssertEqual(reconnected.statusDetection?.mode, .fingerprintOnly)
        XCTAssertTrue(try XCTUnwrap(reconnected.statusDetection?.limitation)
            .contains("fingerprints only"))
    }

    func testReconnectRefusesALivePaneAndALocalOne() throws {
        let (pane, _) = try releasedRemoteAgentPane()
        let (service, _) = makeService(hookPort: 9091, session: { ScriptedTerminalSession() })
        // Live: reconnecting would tear down a working connection to a machine we
        // cannot see.
        _ = try service.adoptKeeperRestored(pane: pane, session: ScriptedTerminalSession())
        XCTAssertThrowsError(try service.reconnectRemote(paneKey: pane.paneKey)) { error in
            XCTAssertEqual((error as? TerminalServiceError)?.code, "invalid_argument")
            XCTAssertTrue((error as? TerminalServiceError)?.message.contains("still connected")
                          ?? false)
        }

        let local = try service.create(engineID: "shell")
        XCTAssertThrowsError(try service.reconnectRemote(paneKey: local.paneKey)) { error in
            XCTAssertEqual((error as? TerminalServiceError)?.code, "invalid_argument")
        }
        XCTAssertThrowsError(try service.reconnectRemote(paneKey: "tab_nope:leaf")) { error in
            XCTAssertEqual((error as? TerminalServiceError)?.code, "terminal_not_found")
        }
    }

    // MARK: - Tunnel argv surgery

    func testTunnelArgvHelpersOnlyTouchOrchardsOwnLoopbackForward() {
        let argv = remoteArgv()
        let ports = KeeperRemoteRestoration.tunnelPorts(in: argv)
        XCTAssertEqual(ports?.remote, 47110)
        XCTAssertEqual(ports?.local, 9091)

        XCTAssertEqual(KeeperRemoteRestoration.retargetTunnel(argv: argv, localPort: 40000)[3],
                       "47110:127.0.0.1:40000")
        XCTAssertFalse(KeeperRemoteRestoration.withoutTunnel(argv).contains("-R"))
        XCTAssertEqual(KeeperRemoteRestoration.withoutTunnel(argv).count, argv.count - 2)

        // A forward that is not ours (a remote-bound address, a local forward) is left
        // exactly as it is: re-pointing somebody else's forward at our hook server is
        // strictly worse than ignoring it.
        let foreign = ["/usr/bin/ssh", "-R", "8080:10.0.0.9:80", "host", "true"]
        XCTAssertNil(KeeperRemoteRestoration.tunnelPorts(in: foreign))
        XCTAssertEqual(KeeperRemoteRestoration.retargetTunnel(argv: foreign, localPort: 1), foreign)
        XCTAssertEqual(KeeperRemoteRestoration.withoutTunnel(foreign), foreign)
    }

    func testHostLabelReadsTheIdWithoutAskingARegistry() {
        XCTAssertEqual(KeeperRemoteRestoration.hostLabel("ssh:build"), "build")
        XCTAssertEqual(KeeperRemoteRestoration.hostLabel("local"), "local")
        XCTAssertEqual(KeeperRemoteRestoration.hostLabel("ssh:"), "ssh:")
    }
}
