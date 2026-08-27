import Foundation
import OrchardCore

/// A remote worktree as Orchard remembers it between listings.
///
/// Local worktree *facts* live in the repo's own git config, which cannot drift from the
/// disk it describes. A remote repo's git config is on the far side, so that trick does
/// not transfer: the record here is Orchard's last-known state, stamped with when the
/// host last confirmed it.
///
/// It exists for one reason beyond convenience — rule 2. If the only source of remote
/// worktrees were a live listing, an unreachable host would answer "you have no
/// worktrees", which is the classic false `exited`. With these records the answer is
/// instead the last-known set, still inspectable, deleted only when a host that actually
/// answered says the worktree is gone.
public struct RemoteWorktreeRecord: Codable, Equatable, Sendable, Identifiable {
    /// `<repoId>::<remote path>` — the same identity shape as a local workspace, which
    /// is what lets one selector vocabulary address both.
    public var id: String
    public var repoId: String
    /// The `ExecutionHostId` raw value (`ssh:<name>`) this worktree's files live on.
    public var hostId: String
    /// Absolute path **on the host**. Never a local path, never a `URL`.
    public var path: String
    public var branch: String
    /// Commit the worktree forked from, when Orchard created it.
    public var baseRef: String
    public var head: String
    /// Immutable per-instance id; rejects stale meta/lineage after a path is reused.
    public var instanceId: String
    /// The repo's own checkout on the host, as opposed to a worktree of it.
    public var isPrimary: Bool
    public var createdAt: Date
    /// Last time the owning host confirmed this worktree exists.
    public var lastSeenAt: Date

    public init(id: String, repoId: String, hostId: String, path: String,
                branch: String = "", baseRef: String = "", head: String = "",
                instanceId: String = UUID().uuidString, isPrimary: Bool = false,
                createdAt: Date = Date(), lastSeenAt: Date = Date()) {
        self.id = id
        self.repoId = repoId
        self.hostId = hostId
        self.path = path
        self.branch = branch
        self.baseRef = baseRef
        self.head = head
        self.instanceId = instanceId
        self.isPrimary = isPrimary
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    public static func id(repoId: String, path: String) -> String {
        WorktreeIdentity.make(repoId: repoId, path: path)
    }
}

public extension Workspace {
    /// Project a remote worktree into the one workspace shape every RPC and UI surface
    /// reads, keyed `repoId::<remote path>` and stamped with the host that owns it.
    ///
    /// `hostId` comes from the record rather than from the repo so a workspace can never
    /// end up describing files on one machine while claiming another: the stamp travels
    /// with the thing it describes.
    static func from(remote record: RemoteWorktreeRecord, repo: RepoRecord,
                     meta: WorktreeMeta, lineage: WorktreeLineage?) -> Workspace {
        Workspace(
            id: record.id,
            instanceId: record.instanceId,
            repoId: repo.id,
            path: record.path,
            hostId: record.hostId,
            displayName: meta.displayName.isEmpty
                ? (record.path.split(separator: "/").last.map(String.init) ?? record.path)
                : meta.displayName,
            comment: meta.comment,
            workspaceStatus: meta.workspaceStatus,
            isPinned: meta.isPinned,
            isUnread: meta.isUnread,
            isArchived: meta.isArchived,
            sortOrder: meta.sortOrder,
            lastActivityAt: meta.lastActivityAt,
            createdAt: meta.createdAt ?? record.createdAt,
            linkedIssue: meta.linkedIssue,
            linkedPR: meta.linkedPR,
            links: meta.links,
            branch: record.branch,
            head: record.head,
            baseRef: record.baseRef,
            kind: .worktree,
            parentWorktreeId: lineage?.parentWorktreeId,
            lineage: lineage)
    }
}
