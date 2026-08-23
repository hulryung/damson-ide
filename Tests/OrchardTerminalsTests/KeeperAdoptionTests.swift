import Combine
import DamsonTerminal
import Foundation
import XCTest
import OrchardCore
@testable import OrchardTerminals

/// A scripted session that can also play the keeper-handoff side of the seam: it
/// yields a scripted `KeeperPTYHandoff` exactly once (like a real PTY, a released
/// session cannot be released again).
@MainActor
private final class KeeperFakeSession: TerminalSession {
    private let inner: ScriptedTerminalSession
    var scriptedHandoff: KeeperPTYHandoff?
    var scriptedPreamble = Data()
    private(set) var released = false

    init(config: DamsonConfig = DamsonConfig()) {
        self.inner = ScriptedTerminalSession(config: config)
    }

    func releaseForKeeperHandoff() -> KeeperPTYHandoff? {
        guard !released, let handoff = scriptedHandoff else { return nil }
        released = true
        return handoff
    }

    func keeperRestorationPreamble() -> Data { scriptedPreamble }

    // MARK: - Forwarding

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

/// T23 registry-side bookkeeping: releasing live panes into restoration records, and
/// adopting a survivor back under the SAME paneKey with a bumped incarnation — then
/// proving the adopted pane still behaves like any other (sized respawn, injection).
@MainActor
final class KeeperAdoptionTests: XCTestCase {

    // MARK: - Release side

    func testReleaseSkipsSessionsThatRefuseHandoffAndDeadPanes() throws {
        var sessions: [ScriptedTerminalSession] = []
        let service = TerminalService(factory: { _, _ in
            let s = ScriptedTerminalSession()
            sessions.append(s)
            return s
        })
        _ = try service.create(engineID: "shell")
        _ = try service.create(engineID: "shell")
        sessions[1].exit(code: 0)
        // ScriptedTerminalSession uses the protocol default (nil handoff): nothing to
        // hand off — and a dead pane must never be offered to the keeper at all.
        XCTAssertTrue(service.releaseForKeeperHandoff().isEmpty)
    }

    func testReleaseCapturesTheRestorationRecord() throws {
        var config = DamsonConfig()
        config.argv = ["/bin/zsh", "-l", "-c", "exec /usr/local/bin/claude --session-id abc"]
        let fake = KeeperFakeSession(config: config)
        fake.scriptedHandoff = KeeperPTYHandoff(fd: -1, pid: 123, startSec: 1, startUsec: 2,
                                                cwd: "/tmp/live-cwd", tail: Data())
        fake.scriptedPreamble = Data("\u{1b}[?1049h".utf8)
        let service = TerminalService(factory: { _, _ in fake })
        let summary = try service.create(worktreeId: "repo::/tmp/wt", cwd: "/tmp/spawn-cwd",
                                         engineID: "shell", title: "held pane")

        let released = service.releaseForKeeperHandoff()
        XCTAssertEqual(released.count, 1)
        let pane = try XCTUnwrap(released.first).paneRecord
        XCTAssertEqual(pane.paneKey, summary.paneKey)
        XCTAssertEqual(pane.incarnation, 1)
        XCTAssertEqual(pane.worktreeId, "repo::/tmp/wt")
        XCTAssertEqual(pane.engineID, "shell")
        XCTAssertEqual(pane.title, "held pane")
        XCTAssertEqual(pane.cwd, "/tmp/live-cwd", "the child's LIVE cwd wins over the spawn cwd")
        XCTAssertEqual(pane.argv, ["/bin/zsh", "-l", "-c", "exec /usr/local/bin/claude"],
                       "session-identity flags must be stripped from the restart argv")
        XCTAssertEqual(pane.preamble, Data("\u{1b}[?1049h".utf8))
        XCTAssertEqual(pane.cols, 80)
        XCTAssertEqual(pane.rows, 24)
        XCTAssertFalse(pane.keeperUUID.isEmpty)
        XCTAssertNotNil(pane.hookToken)

        // A second sweep finds the pane already released — nothing doubles.
        XCTAssertTrue(service.releaseForKeeperHandoff().isEmpty)
    }

    // MARK: - Adopt side

    private func makePane(paneKey: String, incarnation: Int = 3,
                          engineID: String = "shell") -> KeeperPaneRecord {
        KeeperPaneRecord(
            keeperUUID: "k", paneKey: paneKey, incarnation: incarnation,
            worktreeId: "repo::/tmp/wt", engineID: engineID, title: "restored",
            cwd: "/tmp/wt", argv: ["/bin/zsh"], preambleBase64: "",
            cols: 132, rows: 40)
    }

    func testAdoptRestoredKeepsPaneKeyAndBumpsIncarnation() throws {
        var specs: [TerminalCreateSpec] = []
        let service = TerminalService(factory: { spec, _ in
            specs.append(spec)
            return ScriptedTerminalSession()
        })
        let pane = makePane(paneKey: "tab_x:leaf_y", incarnation: 3)

        let summary = try service.adoptKeeperRestored(pane: pane,
                                                      session: ScriptedTerminalSession())
        XCTAssertEqual(summary.paneKey, "tab_x:leaf_y")
        XCTAssertEqual(summary.incarnation, 4, "adoption continues the incarnation sequence")
        XCTAssertTrue(summary.connected)
        XCTAssertEqual(service.liveHandle(forPaneKey: "tab_x:leaf_y"), summary.handle)
        XCTAssertEqual(try service.summary(handle: summary.handle).title, "restored")
        XCTAssertTrue(specs.isEmpty, "adoption must not spawn anything")
    }

    func testAdoptRestoredRefusesDuplicatePaneAndUnknownEngine() throws {
        let service = TerminalService(factory: { _, _ in ScriptedTerminalSession() })
        let pane = makePane(paneKey: "tab_d:leaf_d")
        _ = try service.adoptKeeperRestored(pane: pane, session: ScriptedTerminalSession())
        XCTAssertThrowsError(try service.adoptKeeperRestored(
            pane: pane, session: ScriptedTerminalSession()))
        XCTAssertThrowsError(try service.adoptKeeperRestored(
            pane: makePane(paneKey: "tab_e:leaf_e", engineID: "no-such-engine"),
            session: ScriptedTerminalSession()))
    }

    /// An adopted pane must keep working with the standard machinery: a sized respawn
    /// spawns at the pane's CURRENT grid geometry with the restored cwd/engine, bumps
    /// the incarnation again, and the injection pipeline writes into the live session.
    func testAdoptedPaneSupportsSizedRespawnAndInjection() async throws {
        var specs: [TerminalCreateSpec] = []
        var spawned: [ScriptedTerminalSession] = []
        let service = TerminalService(factory: { spec, _ in
            specs.append(spec)
            let s = ScriptedTerminalSession()
            spawned.append(s)
            return s
        })
        let adopted = ScriptedTerminalSession()
        let pane = makePane(paneKey: "tab_r:leaf_r", incarnation: 2)
        let summary = try service.adoptKeeperRestored(pane: pane, session: adopted)

        // Injection: a raw write through the service lands in the adopted session.
        let sent = try await service.send(handle: summary.handle, text: "echo hi", enter: false)
        XCTAssertTrue(sent.accepted)
        XCTAssertTrue(adopted.writtenText.contains("echo hi"))

        // Sized respawn: geometry from the adopted session's grid, identity from the
        // restored spec, incarnation continues.
        let respawned = try service.respawn(paneKey: "tab_r:leaf_r")
        XCTAssertEqual(respawned.incarnation, 4)
        XCTAssertEqual(respawned.paneKey, "tab_r:leaf_r")
        XCTAssertNotEqual(respawned.handle, summary.handle)
        let spec = try XCTUnwrap(specs.last)
        XCTAssertEqual(spec.cwd, "/tmp/wt")
        XCTAssertEqual(spec.engineID, "shell")
        XCTAssertEqual(spec.initialCols, 80)
        XCTAssertEqual(spec.initialRows, 24)
        do {
            _ = try service.read(handle: summary.handle)
            XCTFail("the pre-respawn handle must answer stale")
        } catch TerminalServiceError.handleStale(_, let replacement) {
            XCTAssertEqual(replacement, respawned.handle)
        }
    }

    /// Restoration geometry is the adopted session's live grid, not a spawn
    /// default: a session scripted at the pane's cols/rows must respawn there.
    func testAdoptedPaneRespawnUsesRestoredGridGeometry() throws {
        var specs: [TerminalCreateSpec] = []
        let service = TerminalService(factory: { spec, _ in
            specs.append(spec)
            return ScriptedTerminalSession()
        })
        let adopted = ScriptedTerminalSession()
        adopted.gridCols = 132
        adopted.gridRows = 40
        let pane = makePane(paneKey: "tab_g:leaf_g", incarnation: 1)
        _ = try service.adoptKeeperRestored(pane: pane, session: adopted)
        _ = try service.respawn(paneKey: "tab_g:leaf_g")
        let spec = try XCTUnwrap(specs.last)
        XCTAssertEqual(spec.initialCols, 132)
        XCTAssertEqual(spec.initialRows, 40)
        XCTAssertEqual(spec.cwd, "/tmp/wt")
    }

    /// Fresh create/adopt seed the tracker and the activity clock; keeper
    /// adoption was skipping both, so a restored pane looked idle-never-spoke
    /// until the next live chunk.
    func testAdoptedPaneSeedsStatusAndActivityClock() throws {
        let service = TerminalService(factory: { _, _ in ScriptedTerminalSession() })
        let terminal = ScriptedTerminalSession()
        let task = AgentTask(title: "t", prompt: "prior ask", engineID: "shell",
                             baseRepoPath: "")
        let agent = AgentSession(engine: GenericShellEngine(), terminal: terminal,
                                 worktree: nil, task: task)
        let pane = makePane(paneKey: "tab_s:leaf_s", incarnation: 4)
        let summary = try service.adoptKeeperRestored(pane: pane, session: terminal,
                                                      agentSession: agent)
        XCTAssertNotNil(summary.lastOutputAt,
                        "adoption must seed the activity clock; replay is async")
        XCTAssertEqual(try service.agentStatus(handle: summary.handle).prompt, "prior ask")
        XCTAssertEqual(try service.agentStatus(handle: summary.handle).state, .working,
                       "AgentSession starts in .starting → status .working, same as adopt()")

        // Live bytes after adoption still move the clock.
        let before = try XCTUnwrap(service.list().first?.lastOutputAt)
        terminal.emitRawBytes(Data("\u{1B}[0m".utf8))
        let after = try XCTUnwrap(service.list().first?.lastOutputAt)
        XCTAssertGreaterThanOrEqual(after, before)
    }

    /// Home-shell re-attach: a keeper-restored shell with no supervisor worktree
    /// is the session `adoptedShellDamsonSession` must find. Scripted fakes have
    /// no Damson surface, so the lookup is nil — but the record is still the
    /// one a real PTY would re-attach.
    func testAdoptedShellLookupSkipsSupervisorBoundAgents() throws {
        let service = TerminalService(factory: { _, _ in ScriptedTerminalSession() })
        let pane = makePane(paneKey: "tab_h:leaf_h")
        let summary = try service.adoptKeeperRestored(pane: pane,
                                                      session: ScriptedTerminalSession())
        XCTAssertEqual(summary.worktreeId, "repo::/tmp/wt")
        XCTAssertEqual(summary.engine, "shell")
        XCTAssertNil(service.damsonSession(handle: summary.handle),
                     "scripted sessions have no Damson surface")
        XCTAssertNil(service.adoptedShellDamsonSession(worktreeId: "repo::/tmp/wt"),
                     "same: lookup only returns a live DamsonSession")
    }

    /// The app hands a supervisor-built agent session in (restored hook token,
    /// worktree binding): its identity is stamped, its observers are chained rather
    /// than replaced, and the status stack tracks the restored pane.
    func testAdoptRestoredWithProvidedAgentSessionChainsObservers() throws {
        let service = TerminalService(factory: { _, _ in ScriptedTerminalSession() })
        let terminal = ScriptedTerminalSession()
        let task = AgentTask(title: "t", prompt: "", engineID: "shell", baseRepoPath: "")
        let agent = AgentSession(engine: GenericShellEngine(), terminal: terminal,
                                 worktree: nil, task: task, hookToken: "restored-token")
        var upstream: [AgentRuntimeState] = []
        agent.onStateChange = { upstream.append($0) }

        let pane = makePane(paneKey: "tab_a:leaf_a", incarnation: 5)
        let summary = try service.adoptKeeperRestored(pane: pane, session: terminal,
                                                      agentSession: agent)
        XCTAssertEqual(agent.hookToken, "restored-token",
                       "the restored token is what re-routes the surviving CLI's hooks")
        XCTAssertEqual(agent.terminalHandle, summary.handle)
        XCTAssertEqual(agent.paneKey, "tab_a:leaf_a")
        XCTAssertEqual(summary.incarnation, 6)

        agent.onStateChange?(.working)
        XCTAssertEqual(upstream, [.working], "the pre-adoption observer must still fire")
        XCTAssertEqual(try service.agentStatus(handle: summary.handle).state, .working)
    }
}
