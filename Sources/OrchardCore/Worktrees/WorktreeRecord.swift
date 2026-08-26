import Foundation
import Combine

/// A worktree as consumers see it: the git worktree plus a cached git status refreshed
/// on demand.
///
/// This is the durable primary noun. An agent session is transient — it starts, finishes,
/// and can be dismissed or replaced — while the worktree and its branch persist until the
/// user deletes them. Making the worktree the durable entity is what lets a finished
/// agent's work survive a dismissal, an app restart, or a crash.
///
/// v2 note: the record no longer holds the live `AgentSession` (that coupled the core to
/// the terminal layer). The agent layer mirrors its state into `agentState`; `nil` means
/// no live agent. T4 extends this with the persisted user-authored `WorktreeMeta`
/// (displayName, workspaceStatus, pins, links).
@MainActor
public final class WorktreeRecord: ObservableObject, @MainActor Identifiable {
    public let worktree: Worktree
    public var id: UUID { worktree.id }

    /// Live state of the agent currently running in this worktree, mirrored by the agent
    /// layer. `nil` after the agent is dismissed or the app restarts — the worktree is
    /// still fully usable, just idle.
    @Published public var agentState: AgentRuntimeState?

    /// Last git status published for this worktree. Refreshed by `refresh()` rather than
    /// on every read, since a fresh reading is several git subprocesses.
    @Published public private(set) var status: GitWorktreeStatus = .unknown
    /// Unmerged state, from the same reading as `status` — porcelain v2 names every
    /// conflicted path, so this costs no extra git.
    @Published public private(set) var conflicts: GitConflictSummary = .none
    @Published public private(set) var isRefreshing = false

    /// Set when an agent finishes a turn while this worktree isn't the one on screen, so
    /// a sidebar can mark it the way an unread message is marked.
    @Published public var hasUnseenActivity = false

    /// Last prompt sent here, shown as the worktree's subtitle when there's no live agent.
    @Published public var lastPrompt: String?

    /// Progress of the project's `orchard.yaml` setup script for this worktree.
    @Published public var setupState: SetupState = .none

    /// User-authored fields (displayName, board status, pins, links). Git facts stay
    /// on `worktree`; this is the orchard-data.json half, hydrated by the workspace
    /// service after restore.
    @Published public var meta: WorktreeMeta

    private let manager: WorktreeManager

    public init(worktree: Worktree, manager: WorktreeManager, meta: WorktreeMeta? = nil) {
        self.worktree = worktree
        self.manager = manager
        self.meta = meta ?? .defaults(for: worktree)
    }

    public var branch: String { worktree.branch }
    public var title: String { meta.displayName.isEmpty ? worktree.title : meta.displayName }
    public var path: URL { worktree.path }
    /// UUID instance id (git-config key). The RPC identity is `workspaceId(repoId:)`.
    public var instanceId: String { worktree.id.uuidString }

    /// What a sidebar row displays as this worktree's state, collapsing "has a live agent"
    /// and "is just sitting there" into one vocabulary.
    public var displayState: WorktreeDisplayState {
        guard let agentState else {
            return status.isPristine ? .idle : .hasChanges
        }
        switch agentState {
        case .starting: return .starting
        case .working: return .working
        case .awaitingApproval: return .needsApproval
        case .awaitingInput: return .needsInput
        case .idle: return .agentIdle
        case .finished: return .done
        case .errored: return .failed
        }
    }

    /// The base commit this worktree forked from, as the status reader spells it.
    public var effectiveBaseRef: String {
        worktree.baseRef.isEmpty ? "HEAD" : worktree.baseRef
    }

    /// Publish the cached reading if `GitFactsCache` still holds one, without running git
    /// or suspending. Returns whether it had one.
    ///
    /// This is what a workspace switch calls first: selecting a workspace visited a moment
    /// ago must not spawn anything, and must not wait for a hop off the main actor either.
    @discardableResult
    public func applyCachedFacts() -> Bool {
        guard let facts = GitFactsCache.shared.cached(worktree: worktree.path,
                                                      baseRef: effectiveBaseRef)
        else { return false }
        apply(facts)
        return true
    }

    /// Re-read git facts. The reading itself never touches the main actor, and several
    /// callers asking at once share one — the sidebar row, the workbench's conflict check
    /// and the source-control panel used to run their own.
    public func refresh() async {
        if applyCachedFacts() { return }
        isRefreshing = true
        let fresh = await GitFactsCache.shared.facts(worktree: worktree.path,
                                                     baseRef: effectiveBaseRef)
        apply(fresh)
        isRefreshing = false
    }

    private func apply(_ facts: GitWorktreeFacts) {
        if status != facts.status { status = facts.status }
        if conflicts != facts.conflicts { conflicts = facts.conflicts }
    }
}

/// Where the project's setup script got to in a given worktree. A failure is kept with its
/// output attached: a worktree whose `npm install` failed looks identical to a healthy one
/// until the agent starts producing nonsense, so the failure has to be visible up front.
public enum SetupState: Equatable, Sendable {
    /// The project declares no setup script.
    case none
    case running
    case succeeded
    case failed(String)

    public var isRunning: Bool { self == .running }

    public var failureOutput: String? {
        if case let .failed(output) = self { return output }
        return nil
    }
}

/// The five-ish states a worktree row can be in. Deliberately a smaller vocabulary than
/// `AgentRuntimeState`: the sidebar answers "does this need me?" at a glance, and the
/// detailed agent state is one level down, on the agent row itself.
public enum WorktreeDisplayState: Equatable, Sendable {
    /// No agent, no changes.
    case idle
    /// No agent, but the worktree holds work.
    case hasChanges
    case starting
    case working
    /// Blocked on a human decision — the only state that is genuinely urgent.
    case needsApproval
    case needsInput
    /// Agent is alive and at its prompt, waiting for the next instruction.
    case agentIdle
    case done
    case failed

    /// Whether this state should pull the user's attention.
    public var isBlocking: Bool {
        self == .needsApproval || self == .needsInput
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .hasChanges: return "Has changes"
        case .starting: return "Starting"
        case .working: return "Working"
        case .needsApproval: return "Needs approval"
        case .needsInput: return "Needs input"
        case .agentIdle: return "Ready"
        case .done: return "Done"
        case .failed: return "Error"
        }
    }
}
