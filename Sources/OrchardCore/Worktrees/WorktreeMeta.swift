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

/// Sidebar / board grouping by user-set column. Distinct from the derived live
/// status (`active|working|permission|done|inactive`) the terminal layer computes.
public struct WorkspaceStatusGroup<Item>: Identifiable {
    public var id: String { definition.id }
    public var definition: WorkspaceStatusDefinition
    public var items: [Item]

    public init(definition: WorkspaceStatusDefinition, items: [Item]) {
        self.definition = definition
        self.items = items
    }
}

public enum WorkspaceStatusGrouping {
    /// Missing or unknown ids fall back to `todo` so a removed custom column
    /// still has a slot (same rule the sidebar card uses).
    public static func resolvedID(_ raw: String?,
                                 vocabulary: [WorkspaceStatusDefinition]) -> String {
        let id = raw ?? "todo"
        if vocabulary.contains(where: { $0.id == id }) { return id }
        return "todo"
    }

    /// Groups items by board-column id in vocabulary order. Empty lanes are
    /// omitted so the sidebar stays compact (Orca's status grouping).
    public static func groups<Item>(
        _ items: [Item],
        vocabulary: [WorkspaceStatusDefinition],
        statusID: (Item) -> String?
    ) -> [WorkspaceStatusGroup<Item>] {
        let vocab = vocabulary.isEmpty ? WorkspaceStatusDefinition.defaults : vocabulary
        var buckets: [String: [Item]] = [:]
        for item in items {
            let id = resolvedID(statusID(item), vocabulary: vocab)
            buckets[id, default: []].append(item)
        }
        return vocab.compactMap { definition in
            guard let grouped = buckets[definition.id], !grouped.isEmpty else { return nil }
            return WorkspaceStatusGroup(definition: definition, items: grouped)
        }
    }
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
