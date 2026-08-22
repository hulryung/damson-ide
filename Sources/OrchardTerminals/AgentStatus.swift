import Foundation
import OrchardCore

/// Orca's four-state agent-status vocabulary (`AGENT_STATUS_STATES`). This is what a
/// status *entry* records; the runtime projection below is what `wait`/`send` gate on.
public enum AgentStatusState: String, Codable, Sendable {
    case working
    case blocked
    case waiting
    case done
}

/// The runtime projection of an agent's turn state (`working | permission | idle | nil`).
/// `nil` means "no live agent to have a state" — a plain shell, or an exited process.
/// The distinction that matters most: `permission` is NOT `idle`. `terminal wait --for
/// tui-idle` is satisfied only by `idle`; dispatching into a permission prompt corrupts
/// the agent's pending decision.
public enum AgentRuntimeProjection: String, Codable, Sendable {
    case working
    case permission
    case idle
}

public extension AgentRuntimeState {
    /// The status-entry state for this runtime state.
    var statusState: AgentStatusState {
        switch self {
        case .starting, .working: return .working
        case .awaitingApproval: return .blocked
        case .awaitingInput: return .waiting
        case .idle, .finished, .errored: return .done
        }
    }

    /// The `working | permission | idle | nil` projection. `awaitingInput` projects to
    /// `permission` (a prompt only a human can answer must never satisfy tui-idle);
    /// terminal states project to nil (there is no agent left to have a state).
    var runtimeProjection: AgentRuntimeProjection? {
        switch self {
        case .starting, .working: return .working
        case .awaitingApproval, .awaitingInput: return .permission
        case .idle: return .idle
        case .finished, .errored: return nil
        }
    }
}

/// One historical state on an agent, for activity rendering (Orca's
/// `AgentStateHistoryEntry`). Timestamps are ms epoch, matching the wire convention.
public struct AgentStateHistoryRecord: Codable, Equatable, Sendable {
    public let state: AgentStatusState
    public let prompt: String
    public let startedAt: Double
}

/// An `AgentStatusEntry`-shaped snapshot of one terminal's agent (the subset v2
/// tracks; Orca's extra hook-payload fields — tool previews, subagents, provider
/// session ids — join as the hook server grows richer payloads).
public struct AgentStatusSnapshot: Codable, Equatable, Sendable {
    public let state: AgentStatusState
    /// The most recent prompt delivered to the agent (empty when none/unknown).
    public let prompt: String
    /// ms epoch of the last status update.
    public let updatedAt: Double
    /// ms epoch when the current `state` was first reported — kept separate from
    /// `updatedAt` so repeat confirmations of one state don't move it.
    public let stateStartedAt: Double
    public let agentType: String
    /// Durable pane identity `"<tabId>:<leafUUID>"` — the key orchestration authority
    /// uses, surviving handle remints.
    public let paneKey: String
    /// The current (remintable) handle, for callers that need to address the terminal.
    public let terminalHandle: String
    public let worktreeId: String?
    public let terminalTitle: String?
    /// Whether an agent process is live in this terminal (false for plain shells and
    /// after exit). When false, `state`/history are the last factual record, not live.
    public let isRunningAgent: Bool
    /// The runtime projection at snapshot time (`nil` = no live agent state).
    public let projection: AgentRuntimeProjection?
    /// Rolling log of previous states, newest last, capped.
    public let stateHistory: [AgentStateHistoryRecord]
}

/// Maximum history entries kept per agent (Orca's `AGENT_STATE_HISTORY_MAX`).
public let agentStateHistoryMax = 20

/// Fuses one terminal's 3-tier detection output (the `AgentSession`'s fused
/// `AgentRuntimeState` — hooks over OSC over fingerprints over process signals) into
/// `AgentStatusEntry`-shaped snapshots plus the runtime projection.
///
/// The tracker is a factual record: it is updated on every transition and **never
/// cleared** when a waiter consumes it — clearing the last status made later waiters
/// hang in v1-era Orca, which is why "never clear lastAgentStatus" is on the rebuild
/// checklist.
@MainActor
final class AgentStatusTracker {
    private(set) var currentState: AgentRuntimeState = .starting
    private var statusState: AgentStatusState = .working
    private var stateStartedAt = Date()
    private var updatedAt = Date()
    private var history: [AgentStateHistoryRecord] = []
    /// The most recent prompt delivered (send pipeline / initial task prompt).
    var lastPrompt = ""

    /// Record a fused-state transition. Same-state confirmations refresh `updatedAt`
    /// only, so `stateStartedAt` keeps meaning "when this state began".
    func note(_ state: AgentRuntimeState) {
        let now = Date()
        updatedAt = now
        currentState = state
        let mapped = state.statusState
        guard mapped != statusState else { return }
        history.append(AgentStateHistoryRecord(
            state: statusState, prompt: lastPrompt,
            startedAt: stateStartedAt.timeIntervalSince1970 * 1000))
        if history.count > agentStateHistoryMax {
            history.removeFirst(history.count - agentStateHistoryMax)
        }
        statusState = mapped
        stateStartedAt = now
    }

    func snapshot(handle: String, paneKey: String, worktreeId: String?, title: String?,
                  agentType: String, isRunningAgent: Bool) -> AgentStatusSnapshot {
        AgentStatusSnapshot(
            state: statusState,
            prompt: lastPrompt,
            updatedAt: updatedAt.timeIntervalSince1970 * 1000,
            stateStartedAt: stateStartedAt.timeIntervalSince1970 * 1000,
            agentType: agentType,
            paneKey: paneKey,
            terminalHandle: handle,
            worktreeId: worktreeId,
            terminalTitle: title,
            isRunningAgent: isRunningAgent,
            projection: isRunningAgent ? currentState.runtimeProjection : nil,
            stateHistory: history)
    }
}
