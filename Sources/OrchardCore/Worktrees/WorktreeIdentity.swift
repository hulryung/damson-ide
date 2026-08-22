import Foundation

/// Worktree (and folder-workspace) identity as Orca defines it: `"<repoId>::<path>"`.
///
/// A bare repo id is **not** a worktree id. The UUID stored in git-config
/// (`Worktree.id`) is the immutable *instance* id — it rejects stale lineage after
/// a path is reused. This string is the user-facing / RPC identity.
public struct WorktreeIdentity: Equatable, Sendable, Hashable {
    public let repoId: String
    public let path: String

    public init(repoId: String, path: String) {
        self.repoId = repoId
        self.path = path
    }

    /// `"<repoId>::<path>"`.
    public var raw: String { Self.make(repoId: repoId, path: path) }

    public static func make(repoId: String, path: String) -> String {
        "\(repoId)::\(path)"
    }

    /// Parse `"<repoId>::<path>"`. Returns nil when the separator is missing or
    /// either side is empty. Extra `::` after the first separator belong to `path`
    /// (a Windows-ish path will never appear on macOS, but a folder session id of
    /// the form `repo::workspace:<uuid>` must round-trip).
    public static func parse(_ raw: String) -> WorktreeIdentity? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = trimmed.range(of: "::") else { return nil }
        let repoId = String(trimmed[..<sep.lowerBound])
        let path = String(trimmed[sep.upperBound...])
        guard !repoId.isEmpty, !path.isEmpty else { return nil }
        return WorktreeIdentity(repoId: repoId, path: path)
    }
}

public extension Worktree {
    /// RPC / UI identity once the owning repo's id is known.
    func workspaceId(repoId: String) -> String {
        WorktreeIdentity.make(repoId: repoId, path: path.path)
    }
}
