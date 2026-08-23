import Foundation

/// Single source of unread markers for workspace cards and the agent dashboard.
///
/// Agent activity inserts the agent (and its workspace when known). Focus clears
/// the matching rows. Views must not keep their own unread sets — they read this
/// state through the app store.
public struct UnreadState: Equatable, Sendable {
    /// Agent → workspace. A nil workspace still marks the agent (dashboard) but
    /// does not light a card.
    public var agents: [UUID: UUID?]

    public init(agents: [UUID: UUID?] = [:]) {
        self.agents = agents
    }

    public var agentIDs: Set<UUID> { Set(agents.keys) }

    public var workspaceIDs: Set<UUID> {
        Set(agents.values.compactMap { $0 })
    }

    public func isUnread(agent id: UUID) -> Bool {
        agents.keys.contains(id)
    }

    public func isUnread(workspace id: UUID) -> Bool {
        agents.values.contains { $0 == id }
    }
}

public enum UnreadEvent: Equatable, Sendable {
    /// Turn finished, blocked, or otherwise needing a look. Marks card + dashboard.
    case agentActivity(agentID: UUID, workspaceID: UUID?)
    /// User focused a workspace card (and therefore its agents).
    case focusedWorkspace(UUID)
    /// User focused a specific agent (dashboard click or jump-to-agent).
    case focusedAgent(UUID)
    case agentRetired(UUID)
    case workspaceRemoved(UUID)
}

/// Pure fold over unread events. UI-free so cards and the dashboard cannot drift.
public enum UnreadReducer {
    public static func reduce(_ state: UnreadState, _ event: UnreadEvent) -> UnreadState {
        var next = state
        switch event {
        case .agentActivity(let agentID, let workspaceID):
            // `updateValue` keeps a nil workspace; `dict[k] = nil` would drop the agent.
            next.agents.updateValue(workspaceID, forKey: agentID)
        case .focusedWorkspace(let workspaceID):
            next.agents = next.agents.filter { $0.value != workspaceID }
        case .focusedAgent(let agentID):
            next.agents.removeValue(forKey: agentID)
        case .agentRetired(let agentID):
            next.agents.removeValue(forKey: agentID)
        case .workspaceRemoved(let workspaceID):
            next.agents = next.agents.filter { $0.value != workspaceID }
        }
        return next
    }

    public static func reduce(_ state: UnreadState, events: [UnreadEvent]) -> UnreadState {
        events.reduce(state, reduce)
    }
}
