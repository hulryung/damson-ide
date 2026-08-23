import XCTest
import OrchardCore
@testable import OrchardTerminals

/// Wave-2 seam: supervisor-spawned agent sessions are adopted into the terminal
/// registry under the identity injected into their PTY env, so the handle a worker
/// sees in `ORCHARD_TERMINAL_HANDLE` is real — resolvable, remintable, stale-answering.
@MainActor
final class TerminalAdoptionTests: XCTestCase {
    private func makeService() -> TerminalService {
        TerminalService(factory: { _, _ in ScriptedTerminalSession() })
    }

    private func makeAgentSession() -> (AgentSession, ScriptedTerminalSession) {
        let terminal = ScriptedTerminalSession()
        let task = AgentTask(title: "t", prompt: "", engineID: "shell", baseRepoPath: "")
        let session = AgentSession(engine: GenericShellEngine(), terminal: terminal,
                                   worktree: nil, task: task)
        return (session, terminal)
    }

    func testAdoptRegistersUnderInjectedIdentityWithRemintSemantics() throws {
        let service = makeService()
        let (session, _) = makeAgentSession()
        let spec = TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(), paneKey: TerminalRegistry.mintPaneKey(),
            worktreeId: "repo1::/tmp/wt", cwd: "/tmp/wt", engineID: "shell",
            prompt: "", title: "worker")

        let summary = try service.adopt(agentSession: session, spec: spec)
        XCTAssertEqual(summary.handle, spec.handle)
        XCTAssertEqual(summary.paneKey, spec.paneKey)
        XCTAssertEqual(service.list(worktreeId: "repo1::/tmp/wt").map(\.handle), [spec.handle])

        // Remint: the pane survives, the old handle answers stale with the replacement.
        let reminted = try service.remintHandle(paneKey: spec.paneKey)
        XCTAssertNotEqual(reminted.handle, spec.handle)
        XCTAssertEqual(reminted.paneKey, spec.paneKey)
        do {
            _ = try service.read(handle: spec.handle)
            XCTFail("stale handle must not resolve")
        } catch TerminalServiceError.handleStale(let handle, let replacement) {
            XCTAssertEqual(handle, spec.handle)
            XCTAssertEqual(replacement, reminted.handle)
        }
    }

    func testAdoptChainsStateObserversInsteadOfReplacingThem() throws {
        let service = makeService()
        let (session, _) = makeAgentSession()
        var upstream: [AgentRuntimeState] = []
        session.onStateChange = { upstream.append($0) }

        let spec = TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(), paneKey: TerminalRegistry.mintPaneKey(),
            worktreeId: nil, cwd: nil, engineID: "shell", prompt: "", title: nil)
        _ = try service.adopt(agentSession: session, spec: spec)

        // Simulate a fused-state transition: the supervisor's observer still fires,
        // and the service's status snapshot tracks the same transition.
        session.onStateChange?(.working)
        XCTAssertEqual(upstream, [.working])
        XCTAssertEqual(try service.agentStatus(handle: spec.handle).state, .working)
    }

    func testDuplicatePaneAdoptionIsRefused() throws {
        let service = makeService()
        let (first, _) = makeAgentSession()
        let (second, _) = makeAgentSession()
        let spec = TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(), paneKey: TerminalRegistry.mintPaneKey(),
            worktreeId: nil, cwd: nil, engineID: "shell", prompt: "", title: nil)
        _ = try service.adopt(agentSession: first, spec: spec)
        XCTAssertThrowsError(try service.adopt(agentSession: second, spec: spec))
    }

    func testSupervisorSpawnEnvironmentCarriesOrchardIdentity() {
        let env = AgentSupervisor.spawnEnvironment(
            base: ["PATH": "/usr/bin"],
            handle: "term_abc", paneKey: "tab_1:leaf_1",
            workspaceID: "repo1::/tmp/wt",
            hostContext: TerminalHostContext(cliCommand: "orchard", dataPath: "/tmp/data"))
        XCTAssertEqual(env["ORCHARD_TERMINAL_HANDLE"], "term_abc")
        XCTAssertEqual(env["ORCHARD_PANE_KEY"], "tab_1:leaf_1")
        XCTAssertEqual(env["ORCHARD_WORKTREE_ID"], "repo1::/tmp/wt")
        XCTAssertEqual(env["ORCHARD_CLI_COMMAND"], "orchard")
        XCTAssertEqual(env["ORCHARD_DATA_PATH"], "/tmp/data")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }
}
