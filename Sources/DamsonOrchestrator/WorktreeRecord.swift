import Foundation
import Combine

/// A worktree as the UI sees it: the git worktree, the agent currently attached to it (if
/// any), and a cached git status refreshed on demand.
///
/// This is the app's primary noun. An `AgentSession` is transient — it starts, finishes, and
/// can be dismissed or replaced — while the worktree and its branch persist until the user
/// deletes them. Making the worktree the durable entity is what lets a finished agent's work
/// survive a dismissal, an app restart, or a crash.
@MainActor
public final class WorktreeRecord: ObservableObject, @MainActor Identifiable {
    public let worktree: Worktree
    public var id: UUID { worktree.id }

    /// The agent currently running in this worktree. `nil` after the agent is dismissed or
    /// the app restarts — the worktree is still fully usable, just idle.
    @Published public private(set) var agent: AgentSession?

    /// Cached git status. Refreshed by `refresh()` rather than on every UI read, since each
    /// call is several git subprocesses.
    @Published public private(set) var status: GitWorktreeStatus = .unknown
    @Published public private(set) var isRefreshing = false

    /// Set when an agent finishes a turn while this worktree isn't the one on screen, so the
    /// sidebar can mark it the way an unread message is marked.
    @Published public var hasUnseenActivity = false

    /// Last prompt sent here, shown as the worktree's subtitle when there's no live agent.
    @Published public var lastPrompt: String?

    /// Progress of the project's `orchard.yaml` setup script for this worktree.
    @Published public var setupState: SetupState = .none

    private let manager: WorktreeManager

    public init(worktree: Worktree, manager: WorktreeManager, agent: AgentSession? = nil) {
        self.worktree = worktree
        self.manager = manager
        self.agent = agent
    }

    public var branch: String { worktree.branch }
    public var title: String { worktree.title }
    public var path: URL { worktree.path }

    /// What the sidebar row displays as this worktree's state, collapsing "has a live agent"
    /// and "is just sitting there" into one vocabulary.
    public var displayState: WorktreeDisplayState {
        guard let agent else {
            return status.isPristine ? .idle : .hasChanges
        }
        switch agent.state {
        case .starting: return .starting
        case .working: return .working
        case .awaitingApproval: return .needsApproval
        case .awaitingInput: return .needsInput
        case .idle: return .agentIdle
        case .finished: return .done
        case .errored: return .failed
        }
    }

    public func attach(_ agent: AgentSession) {
        self.agent = agent
    }

    /// Detach the agent without touching the worktree — the "dismiss this agent, keep the
    /// work" path.
    public func detachAgent() {
        agent = nil
    }

    /// Re-read git status. Runs the git calls off the main actor so a large repo's status
    /// can't stutter the UI.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let manager = self.manager
        let wt = self.worktree
        let fresh = await Task.detached(priority: .utility) { manager.status(wt) }.value
        status = fresh
        isRefreshing = false
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
