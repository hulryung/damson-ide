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
    /// Typed links (T88). Inventory §2 gives the card four link properties —
    /// `issue`, `linear-issue`, `jira-issue`, `pr` — so the store keeps kinds, not
    /// two bare strings. `linkedIssue`/`linkedPR` below are views onto this array
    /// so every existing caller, selector, and stored file keeps working.
    public var links: [WorktreeLink]

    /// The issue slot, as the string it was written as. Reads the first non-PR
    /// link; writing replaces every non-PR link with the inferred typed one.
    public var linkedIssue: String? {
        get { links.first { !$0.kind.isPullRequest }?.raw }
        set { setSlot(.issue, to: newValue) }
    }

    /// The pull-request slot, same contract as `linkedIssue`.
    public var linkedPR: String? {
        get { links.first { $0.kind.isPullRequest }?.raw }
        set { setSlot(.pullRequest, to: newValue) }
    }

    /// Replace one slot. `nil`/empty clears it; anything else is typed by
    /// `WorktreeLinkInference`, which leaves unrecognised text `.untyped` rather
    /// than guessing a tracker for it.
    public mutating func setSlot(_ slot: WorktreeLinkKind, to raw: String?,
                                 explicitKind: WorktreeLinkKind? = nil) {
        let wantsPR = (explicitKind ?? slot).isPullRequest
        links.removeAll { $0.kind.isPullRequest == wantsPR }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let link = WorktreeLinkInference.link(from: raw, slot: slot,
                                                    explicitKind: explicitKind)
        else { return }
        links.append(link)
    }

    /// The typed PR link, when one is set. `checks` needs the number.
    public var pullRequestLink: WorktreeLink? { links.first { $0.kind.isPullRequest } }

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
                linkedPR: String? = nil,
                links: [WorktreeLink]? = nil) {
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
        // Typed links win when handed in; otherwise the two legacy strings are
        // inferred into their slots, which is also the on-disk migration path.
        if let links {
            self.links = links
        } else {
            self.links = []
            self.linkedIssue = linkedIssue
            self.linkedPR = linkedPR
        }
    }

    public static func defaults(for worktree: Worktree) -> WorktreeMeta {
        WorktreeMeta(
            instanceId: worktree.id.uuidString,
            displayName: worktree.title,
            lastActivityAt: worktree.createdAt,
            createdAt: worktree.createdAt)
    }
}

// MARK: - Persistence

/// Hand-written because `linkedIssue`/`linkedPR` became views onto `links` (T88)
/// and a synthesized `Codable` would silently drop them from the file — every
/// existing `orchard-data.json` carries those two keys and nothing else.
///
/// Decode reads `links` when the file already has it and otherwise *migrates* the
/// two legacy strings into typed links. Encode writes both: `links` is the truth,
/// and the two strings stay in the file so an older build (or anything reading the
/// JSON directly) still sees what it wrote.
extension WorktreeMeta {
    private enum CodingKeys: String, CodingKey {
        case instanceId, displayName, comment, workspaceStatus, isPinned, isUnread
        case isArchived, sortOrder, lastActivityAt, createdAt
        case links, linkedIssue, linkedPR
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.instanceId = try c.decode(String.self, forKey: .instanceId)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        self.workspaceStatus = try c.decodeIfPresent(String.self, forKey: .workspaceStatus)
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.isUnread = try c.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? Date()
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.links = []
        if let stored = try c.decodeIfPresent([WorktreeLink].self, forKey: .links) {
            self.links = stored
        } else {
            self.linkedIssue = try c.decodeIfPresent(String.self, forKey: .linkedIssue)
            self.linkedPR = try c.decodeIfPresent(String.self, forKey: .linkedPR)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instanceId, forKey: .instanceId)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(comment, forKey: .comment)
        try c.encodeIfPresent(workspaceStatus, forKey: .workspaceStatus)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(isUnread, forKey: .isUnread)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(lastActivityAt, forKey: .lastActivityAt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(links, forKey: .links)
        try c.encodeIfPresent(linkedIssue, forKey: .linkedIssue)
        try c.encodeIfPresent(linkedPR, forKey: .linkedPR)
    }
}
