import Foundation
import OrchardCore
import OrchardTerminals

/// Result of the worker-start-shaped composition: a new worktree plus, when
/// agent-first creation ran, the handle of the agent terminal spawned in it.
///
/// The RPC-level `worker-start` verb is a follow-up once T1–T4 merge; this is
/// the composition those handlers will call. `agentTerminalHandle` is minted
/// here as `term_<uuid>` from the `AgentSession` id — T3's terminal registry
/// remints handles, and the follow-up verb should treat this as a provisional
/// handle to re-list against, not as a durable pane key.
public struct WorkerStartResult: Sendable {
    public var worktreeId: String
    public var instanceId: String
    public var agentTerminalHandle: String?
    public var workspace: Workspace
    public var warning: String?
}

/// Seam between workspace create and the terminal/agent layer. T3 owns the
/// real terminal registry; we talk to T0's `AgentSupervisor` through this so
/// workspace tests can stub launching without a PTY, and so T3 can swap the
/// production implementation without a signature change here.
public protocol AgentLaunching: Sendable {
    func launch(engineID: String, prompt: String, worktree: Worktree,
                title: String?) async throws -> LaunchedAgent
}

public struct LaunchedAgent: Sendable {
    public var terminalHandle: String
    /// Wait until the agent is `.idle`. `.awaitingApproval` / `.awaitingInput`
    /// (permission) must **not** satisfy this — matching `terminal wait --for
    /// tui-idle`. Throws on process exit or timeout.
    public var waitUntilReady: @Sendable (TimeInterval) async throws -> Void

    public init(terminalHandle: String,
                waitUntilReady: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.terminalHandle = terminalHandle
        self.waitUntilReady = waitUntilReady
    }
}

public struct AgentLaunchError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { message }
}

/// Production launcher wrapping T0's `AgentSupervisor`. Does not change the
/// supervisor's signature — spawn stays `spawnAgent(engineID:prompt:in:title:)`.
public final class AgentSupervisorLauncher: AgentLaunching, @unchecked Sendable {
    private let supervisor: AgentSupervisor

    public init(supervisor: AgentSupervisor) {
        self.supervisor = supervisor
    }

    public func launch(engineID: String, prompt: String, worktree: Worktree,
                       title: String?) async throws -> LaunchedAgent {
        let (session, handle) = try await MainActor.run { () -> (AgentSession, String) in
            let session = try supervisor.spawnAgent(engineID: engineID, prompt: prompt,
                                                    in: worktree, title: title)
            // Provisional handle. T3 remints `term_<uuid>` against its registry;
            // callers of worker-start should re-list if a later send reports stale.
            let handle = "term_\(session.id.uuidString.lowercased())"
            return (session, handle)
        }
        return LaunchedAgent(terminalHandle: handle) { timeout in
            try await AgentSupervisorLauncher.waitUntilIdle(session, timeout: timeout)
        }
    }

    /// Fast-path already-idle; resolve on any transition to idle; reject on PTY
    /// exit; permission does not satisfy idle. Default timeout is the caller's.
    static func waitUntilIdle(_ session: AgentSession, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = await MainActor.run { session.state }
            if state == .idle { return }
            if case .finished(let code) = state {
                throw AgentLaunchError("agent_exited", "agent process exited (\(code))")
            }
            if case .errored(let message) = state {
                throw AgentLaunchError("agent_exited", message)
            }
            if Date() >= deadline {
                throw AgentLaunchError("agent_not_ready",
                    "agent did not reach idle within \(Int(timeout))s")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Default readiness wait used by worker-start (Orca §1.7: wait tui-idle, 60s).
public let workerStartReadinessTimeout: TimeInterval = 60
