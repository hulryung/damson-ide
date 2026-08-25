import Foundation
import OrchardCore

/// Click-to-focus routing ids for a dashboard card (inventory §6).
/// `leafId` is nil when the pane key could not be parsed; `agentID` is the
/// in-process session the app focuses.
public struct DashboardFocusRoute: Equatable, Sendable {
    public let agentID: UUID
    public let paneKey: String
    public let repoId: String?
    public let worktreeId: String?
    public let tabId: String?
    public let leafId: String?

    public init(agentID: UUID, paneKey: String, repoId: String? = nil,
                worktreeId: String? = nil, tabId: String? = nil, leafId: String? = nil) {
        self.agentID = agentID
        self.paneKey = paneKey
        self.repoId = repoId
        self.worktreeId = worktreeId
        self.tabId = tabId
        self.leafId = leafId
    }
}

/// UI-free kanban card. Matches Orca's `DashboardCard` inventory fields:
/// paneKey, agentType, bucket, dotState, task, last user/agent message,
/// click-to-focus routing, parentPaneKey, workspaceStatus, startedAt/finishedAt,
/// unseen, askSummary.
public struct DashboardCard: Equatable, Sendable, Identifiable {
    public var id: String { paneKey }

    public let paneKey: String
    public let agentType: String
    public let bucket: DashboardBucket
    /// Raw live-state glyph. Distinct from `bucket` so a done card that has
    /// been acknowledged can sit in idle while still reading as done internally.
    public let dotState: DashboardDotState
    public let task: String
    public let lastUserMessage: String?
    public let lastAgentMessage: String?
    public let focus: DashboardFocusRoute
    public let parentPaneKey: String?
    public let workspaceName: String
    public let workspaceStatusId: String?
    public let workspaceStatusLabel: String?
    /// Spawn / first-seen time, ms epoch.
    public let startedAt: Double
    /// When the agent last entered `done`, or nil if it never finished.
    public let finishedAt: Double?
    /// When the agent entered its current state — column ordering key.
    public let stateChangedAt: Double
    public let unseen: Bool
    /// Short pending-question text when `bucket == .attention`.
    public let askSummary: String?

    public init(paneKey: String, agentType: String, bucket: DashboardBucket,
                dotState: DashboardDotState, task: String,
                lastUserMessage: String? = nil, lastAgentMessage: String? = nil,
                focus: DashboardFocusRoute, parentPaneKey: String? = nil,
                workspaceName: String, workspaceStatusId: String? = nil,
                workspaceStatusLabel: String? = nil, startedAt: Double,
                finishedAt: Double? = nil, stateChangedAt: Double,
                unseen: Bool, askSummary: String? = nil) {
        self.paneKey = paneKey
        self.agentType = agentType
        self.bucket = bucket
        self.dotState = dotState
        self.task = task
        self.lastUserMessage = lastUserMessage
        self.lastAgentMessage = lastAgentMessage
        self.focus = focus
        self.parentPaneKey = parentPaneKey
        self.workspaceName = workspaceName
        self.workspaceStatusId = workspaceStatusId
        self.workspaceStatusLabel = workspaceStatusLabel
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stateChangedAt = stateChangedAt
        self.unseen = unseen
        self.askSummary = askSummary
    }

    /// Done cards stay highlighted until acknowledged.
    public var isHighlighted: Bool { dotState == .done && unseen }

    public var displayDotState: DashboardDotState {
        DashboardProjection.displayState(dotState: dotState, unseen: unseen)
    }

    /// Finished cards read time-since-finish; active cards fall back to startedAt.
    public var timeColumnMs: Double { finishedAt ?? startedAt }
}

/// Bounded kanban board. Visible cards are capped per bucket so a huge fleet
/// cannot blank the dashboard.
public struct DashboardBoard: Equatable, Sendable {
    public let cards: [DashboardCard]
    public let totalByBucket: [DashboardBucket: Int]
    public let overflowByBucket: [DashboardBucket: Int]
    public let capPerBucket: Int

    public init(cards: [DashboardCard], totalByBucket: [DashboardBucket: Int],
                overflowByBucket: [DashboardBucket: Int], capPerBucket: Int) {
        self.cards = cards
        self.totalByBucket = totalByBucket
        self.overflowByBucket = overflowByBucket
        self.capPerBucket = capPerBucket
    }

    public static let empty = DashboardBoard(
        cards: [], totalByBucket: [:], overflowByBucket: [:],
        capPerBucket: DashboardProjection.maxCardsPerBucket)

    public func cards(in bucket: DashboardBucket) -> [DashboardCard] {
        cards.filter { $0.bucket == bucket }
    }

    public func total(in bucket: DashboardBucket) -> Int {
        totalByBucket[bucket] ?? 0
    }

    public func overflow(in bucket: DashboardBucket) -> Int {
        overflowByBucket[bucket] ?? 0
    }
}

/// Facts the UI-free projector needs. AppStore (and tests) fill this; the
/// projection never reads SwiftUI or AgentSession.
public struct DashboardCardInput: Equatable, Sendable {
    public var paneKey: String
    public var agentType: String
    public var snapshot: AgentStatusSnapshot?
    public var runtime: AgentRuntimeState
    public var unseen: Bool
    public var taskTitle: String?
    public var taskPrompt: String?
    public var parentPaneKey: String?
    public var workspaceName: String
    public var workspaceStatusId: String?
    public var workspaceStatusLabel: String?
    public var repoId: String?
    public var worktreeId: String?
    public var tabId: String?
    public var leafId: String?
    public var agentID: UUID
    public var startedAtMs: Double
    public var finishedAtMs: Double?
    public var interactivePrompt: String?

    public init(paneKey: String, agentType: String,
                snapshot: AgentStatusSnapshot? = nil,
                runtime: AgentRuntimeState, unseen: Bool,
                taskTitle: String? = nil, taskPrompt: String? = nil,
                parentPaneKey: String? = nil, workspaceName: String,
                workspaceStatusId: String? = nil,
                workspaceStatusLabel: String? = nil,
                repoId: String? = nil, worktreeId: String? = nil,
                tabId: String? = nil, leafId: String? = nil,
                agentID: UUID, startedAtMs: Double,
                finishedAtMs: Double? = nil,
                interactivePrompt: String? = nil) {
        self.paneKey = paneKey
        self.agentType = agentType
        self.snapshot = snapshot
        self.runtime = runtime
        self.unseen = unseen
        self.taskTitle = taskTitle
        self.taskPrompt = taskPrompt
        self.parentPaneKey = parentPaneKey
        self.workspaceName = workspaceName
        self.workspaceStatusId = workspaceStatusId
        self.workspaceStatusLabel = workspaceStatusLabel
        self.repoId = repoId
        self.worktreeId = worktreeId
        self.tabId = tabId
        self.leafId = leafId
        self.agentID = agentID
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
        self.interactivePrompt = interactivePrompt
    }
}
