import Foundation

/// Domain events emitted by the headless services (`WorktreeService`, and the agent
/// supervisor in OrchardTerminals) — the v2 replacement for v1's ad-hoc UI callbacks
/// (`onAgentSpawned`, `onAgentRetired`, `onError`, `onAgentNeedsAttention`).
///
/// Consumers observe an `AsyncStream<OrchardEvent>`. The stream is deliberately a
/// one-way fact feed: services never wait on a consumer, so a slow (or absent) UI can
/// never stall worktree or agent work. Each service's stream is single-subscriber —
/// the process assembly (app or runtime) owns fan-out if more than one listener needs it.
public enum OrchardEvent: Sendable {
    // MARK: Worktree domain

    case worktreeCreated(Worktree)
    case worktreeRemoved(worktreeID: UUID, branch: String)
    /// Worktrees re-attached from git on service start (count, not the records —
    /// consumers read the service's list for the authoritative state).
    case worktreesRestored(count: Int)
    /// A worktree's `orchard.yaml` setup script progressed (running/succeeded/failed).
    case setupStateChanged(worktreeID: UUID, state: SetupState)

    // MARK: Agent domain

    case agentSpawned(agentID: UUID, worktreeID: UUID?, engineID: String)
    case agentStateChanged(agentID: UUID, worktreeID: UUID?, state: AgentRuntimeState)
    /// The agent reached a state the user would want to know about while looking
    /// elsewhere (turn finished, blocked on approval) — v1's `onAgentNeedsAttention`.
    case agentNeedsAttention(agentID: UUID, worktreeID: UUID?, state: AgentRuntimeState)
    case agentRetired(agentID: UUID, worktreeID: UUID?)

    // MARK: Failures surfaced as facts (never thrown across the stream)

    case serviceError(String)
}
