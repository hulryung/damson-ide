import Foundation
@_exported import OrchardCore

/// Unified workspace shape. Git worktrees and folder workspaces project into
/// this so every UI/RPC surface treats both uniformly. Folder workspaces have
/// empty `branch`/`head`.
public struct Workspace: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case worktree, folder }

    /// `"<repoId>::<path>"`.
    public var id: String
    public var instanceId: String
    public var repoId: String
    public var path: String
    /// The `ExecutionHostId` raw value (`local` or `ssh:<name>`) this workspace's files
    /// and processes live on — stamped, never inferred (T29,
    /// docs/design/remote-hosts.md). Remote worktrees are a later stage, so today every
    /// workspace is `local`; the field exists so per-host partitioning has something to
    /// key on when they land.
    public var hostId: String
    public var displayName: String
    public var comment: String
    public var workspaceStatus: String?
    public var isPinned: Bool
    public var isUnread: Bool
    public var isArchived: Bool
    public var sortOrder: Int
    public var lastActivityAt: Date
    public var createdAt: Date
    public var linkedIssue: String?
    public var linkedPR: String?
    /// T88: the same two links, typed (`issue`/`linear-issue`/`jira-issue`/`pr`),
    /// with the raw strings above kept so nothing that reads them has to change.
    /// Text that types to nothing stays `untyped` rather than being guessed into
    /// a tracker.
    public var links: [WorktreeLink]
    public var branch: String
    public var head: String
    public var baseRef: String
    public var kind: Kind
    public var parentWorktreeId: String?
    public var lineage: WorktreeLineage?

    public init(id: String,
                instanceId: String,
                repoId: String,
                path: String,
                hostId: String = "local",
                displayName: String,
                comment: String = "",
                workspaceStatus: String? = nil,
                isPinned: Bool = false,
                isUnread: Bool = false,
                isArchived: Bool = false,
                sortOrder: Int = 0,
                lastActivityAt: Date = Date(),
                createdAt: Date = Date(),
                linkedIssue: String? = nil,
                linkedPR: String? = nil,
                links: [WorktreeLink]? = nil,
                branch: String = "",
                head: String = "",
                baseRef: String = "",
                kind: Kind,
                parentWorktreeId: String? = nil,
                lineage: WorktreeLineage? = nil) {
        self.id = id
        self.instanceId = instanceId
        self.repoId = repoId
        self.path = path
        self.hostId = hostId
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
        // Callers that hand over raw strings (the folder path, the remote record)
        // get them typed here, so `links` is never out of step with the two fields.
        self.links = links ?? WorkspaceLinks.typed(issue: linkedIssue, pr: linkedPR)
        self.branch = branch
        self.head = head
        self.baseRef = baseRef
        self.kind = kind
        self.parentWorktreeId = parentWorktreeId
        self.lineage = lineage
    }

    public static func from(worktree: Worktree, repo: RepoRecord,
                            meta: WorktreeMeta, head: String,
                            lineage: WorktreeLineage?) -> Workspace {
        Workspace(
            id: worktree.workspaceId(repoId: repo.id),
            instanceId: worktree.id.uuidString,
            repoId: repo.id,
            path: worktree.path.path,
            hostId: repo.hostId,
            displayName: meta.displayName,
            comment: meta.comment,
            workspaceStatus: meta.workspaceStatus,
            isPinned: meta.isPinned,
            isUnread: meta.isUnread,
            isArchived: meta.isArchived,
            sortOrder: meta.sortOrder,
            lastActivityAt: meta.lastActivityAt,
            createdAt: meta.createdAt ?? worktree.createdAt,
            linkedIssue: meta.linkedIssue,
            linkedPR: meta.linkedPR,
            links: meta.links,
            branch: worktree.branch,
            head: head,
            baseRef: worktree.baseRef,
            kind: .worktree,
            parentWorktreeId: lineage?.parentWorktreeId,
            lineage: lineage)
    }

    public static func from(folder: FolderWorkspaceRecord, repo: RepoRecord,
                            lineage: WorktreeLineage?) -> Workspace {
        Workspace(
            id: folder.id,
            instanceId: folder.instanceId,
            repoId: repo.id,
            path: folder.folderPath,
            hostId: repo.hostId,
            displayName: folder.name,
            comment: folder.comment,
            workspaceStatus: folder.workspaceStatus,
            isPinned: folder.isPinned,
            isUnread: folder.isUnread,
            isArchived: folder.isArchived,
            sortOrder: folder.sortOrder,
            lastActivityAt: folder.lastActivityAt,
            createdAt: folder.createdAt,
            linkedIssue: folder.linkedIssue,
            linkedPR: folder.linkedPR,
            links: folder.links,
            branch: "",
            head: "",
            baseRef: "",
            kind: .folder,
            parentWorktreeId: lineage?.parentWorktreeId,
            lineage: lineage)
    }

    /// Repo primary checkout as a first-class workspace (`repoId::path`). Git
    /// checkouts carry live branch/head; callers pass empty strings for folder
    /// roots.
    public static func fromPrimaryCheckout(repo: RepoRecord, meta: WorktreeMeta,
                                           branch: String, head: String,
                                           lineage: WorktreeLineage?) -> Workspace {
        let path = URL(fileURLWithPath: repo.path).standardizedFileURL.path
        return Workspace(
            id: WorktreeIdentity.make(repoId: repo.id, path: path),
            instanceId: meta.instanceId,
            repoId: repo.id,
            path: path,
            hostId: repo.hostId,
            displayName: meta.displayName.isEmpty ? repo.displayName : meta.displayName,
            comment: meta.comment,
            workspaceStatus: meta.workspaceStatus,
            isPinned: meta.isPinned,
            isUnread: meta.isUnread,
            isArchived: meta.isArchived,
            sortOrder: meta.sortOrder,
            lastActivityAt: meta.lastActivityAt,
            createdAt: meta.createdAt ?? repo.addedAt,
            linkedIssue: meta.linkedIssue,
            linkedPR: meta.linkedPR,
            links: meta.links,
            branch: branch,
            head: head,
            baseRef: repo.baseRef,
            kind: .worktree,
            parentWorktreeId: lineage?.parentWorktreeId,
            lineage: lineage)
    }
}

public struct WorkspaceCreateRequest: Sendable {
    public var repo: String
    public var name: String?
    public var displayName: String?
    public var baseBranch: String?
    public var comment: String?
    public var linkedIssue: String?
    public var linkedPR: String?
    public var workspaceStatus: String?
    public var parentWorktree: String?
    public var noParent: Bool
    public var origin: LineageOrigin
    public var cwd: String?
    public var agent: String?
    public var prompt: String
    public var runSetup: Bool?
    public var captureSource: LineageCaptureSource?

    public init(repo: String,
                name: String? = nil,
                displayName: String? = nil,
                baseBranch: String? = nil,
                comment: String? = nil,
                linkedIssue: String? = nil,
                linkedPR: String? = nil,
                workspaceStatus: String? = nil,
                parentWorktree: String? = nil,
                noParent: Bool = false,
                origin: LineageOrigin = .cli,
                cwd: String? = nil,
                agent: String? = nil,
                prompt: String = "",
                runSetup: Bool? = nil,
                captureSource: LineageCaptureSource? = nil) {
        self.repo = repo
        self.name = name
        self.displayName = displayName
        self.baseBranch = baseBranch
        self.comment = comment
        self.linkedIssue = linkedIssue
        self.linkedPR = linkedPR
        self.workspaceStatus = workspaceStatus
        self.parentWorktree = parentWorktree
        self.noParent = noParent
        self.origin = origin
        self.cwd = cwd
        self.agent = agent
        self.prompt = prompt
        self.runSetup = runSetup
        self.captureSource = captureSource
    }
}

public struct WorkspaceCreateResult: Sendable {
    public var workspace: Workspace
    public var lineage: WorktreeLineage?
    public var agentTerminalHandle: String?
    public var warning: String?

    public init(workspace: Workspace, lineage: WorktreeLineage? = nil,
                agentTerminalHandle: String? = nil, warning: String? = nil) {
        self.workspace = workspace
        self.lineage = lineage
        self.agentTerminalHandle = agentTerminalHandle
        self.warning = warning
    }
}

public struct WorkspaceUpdateRequest: Sendable {
    public var displayName: String?
    public var comment: String?
    public var workspaceStatus: String?
    public var linkedIssue: String?
    public var linkedPR: String?
    /// T88: names which tracker `linkedIssue` is on when the text alone cannot say.
    /// `ENG-412` is a Linear key and a Jira key; without this it stays `untyped`
    /// rather than being guessed into one of them.
    public var linkKind: WorktreeLinkKind?
    public var isPinned: Bool?
    public var isUnread: Bool?
    public var isArchived: Bool?
    public var sortOrder: Int?
    public var parentWorktree: String?
    public var noParent: Bool

    public init(displayName: String? = nil,
                comment: String? = nil,
                workspaceStatus: String? = nil,
                linkedIssue: String? = nil,
                linkedPR: String? = nil,
                linkKind: WorktreeLinkKind? = nil,
                isPinned: Bool? = nil,
                isUnread: Bool? = nil,
                isArchived: Bool? = nil,
                sortOrder: Int? = nil,
                parentWorktree: String? = nil,
                noParent: Bool = false) {
        self.displayName = displayName
        self.comment = comment
        self.workspaceStatus = workspaceStatus
        self.linkedIssue = linkedIssue
        self.linkedPR = linkedPR
        self.linkKind = linkKind
        self.isPinned = isPinned
        self.isUnread = isUnread
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.parentWorktree = parentWorktree
        self.noParent = noParent
    }
}

public struct WorkspaceRemoveResult: Sendable {
    public var removed: Bool
    public var warning: String?
    public var preflightWarnings: [String]
    public var branch: String? = nil
    public var branchMerged: Bool? = nil
    public var branchDeleted: Bool? = nil
}


/// Typing for the two legacy link strings on records that still store them
/// (folder workspaces, the remote worktree record). `WorktreeMeta` types its own.
public enum WorkspaceLinks {
    public static func typed(issue: String?, pr: String?) -> [WorktreeLink] {
        var links: [WorktreeLink] = []
        if let issue, let link = WorktreeLinkInference.link(from: issue, slot: .issue) {
            links.append(link)
        }
        if let pr, let link = WorktreeLinkInference.link(from: pr, slot: .pullRequest) {
            links.append(link)
        }
        return links
    }
}
