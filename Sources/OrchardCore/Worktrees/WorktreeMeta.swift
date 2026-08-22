import Foundation

/// User-assigned board column. Distinct from the derived live status
/// (`active|working|permission|done|inactive`) that the terminal layer computes.
public struct WorkspaceStatusDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var color: String?
    public var icon: String?

    public init(id: String, label: String, color: String? = nil, icon: String? = nil) {
        self.id = id
        self.label = label
        self.color = color
        self.icon = icon
    }

    /// The four defaults Orca ships. Custom vocabulary is additive on top of these.
    public static let defaults: [WorkspaceStatusDefinition] = [
        WorkspaceStatusDefinition(id: "todo", label: "Todo", color: "neutral", icon: "circle"),
        WorkspaceStatusDefinition(id: "in-progress", label: "In progress",
                                  color: "blue", icon: "circle-dot"),
        WorkspaceStatusDefinition(id: "in-review", label: "In review",
                                  color: "violet", icon: "git-pull-request"),
        WorkspaceStatusDefinition(id: "completed", label: "Done",
                                  color: "emerald", icon: "circle-check"),
    ]

    public static let defaultIDs: Set<String> = Set(defaults.map(\.id))
}

/// User-authored worktree fields. Persisted in `orchard-data.json`, keyed by
/// worktree id (`<repoId>::<path>`). Git facts (path, branch, baseRef, title)
/// stay in the repo's git-config so they cannot drift from disk.
public struct WorktreeMeta: Codable, Equatable, Sendable {
    /// Immutable per-workspace-instance id. Matches `Worktree.id` (the git-config
    /// key). Rejects stale lineage after a path is reused.
    public var instanceId: String
    public var displayName: String
    public var comment: String
    /// Board-column id; one of the four defaults or a custom vocabulary entry.
    public var workspaceStatus: String?
    public var isPinned: Bool
    public var isUnread: Bool
    public var isArchived: Bool
    public var sortOrder: Int
    public var lastActivityAt: Date
    public var createdAt: Date?
    /// Plain strings for v2 foundation (Orca stores typed issue/PR numbers).
    public var linkedIssue: String?
    public var linkedPR: String?

    public init(instanceId: String,
                displayName: String,
                comment: String = "",
                workspaceStatus: String? = nil,
                isPinned: Bool = false,
                isUnread: Bool = false,
                isArchived: Bool = false,
                sortOrder: Int = 0,
                lastActivityAt: Date = Date(),
                createdAt: Date? = nil,
                linkedIssue: String? = nil,
                linkedPR: String? = nil) {
        self.instanceId = instanceId
        self.displayName = displayName
        self.comment = comment
        self.workspaceStatus = workspaceStatus
        self.isPinned = isPinned
        self.isUnread = isUnread
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.lastActivityAt = lastActivityAt
        self.createdAt = createdAt
        self.linkedIssue = linkedIssue
        self.linkedPR = linkedPR
    }

    public static func defaults(for worktree: Worktree) -> WorktreeMeta {
        WorktreeMeta(
            instanceId: worktree.id.uuidString,
            displayName: worktree.title,
            lastActivityAt: worktree.createdAt,
            createdAt: worktree.createdAt)
    }
}
