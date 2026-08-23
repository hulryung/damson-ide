import Foundation

/// One record from `git worktree list --porcelain`.
///
/// Additive to the local worktree stack: the local manager reads worktrees from the
/// filesystem it is standing on, but a remote worktree can only be known through what
/// git printed over the connection, so that text needs a parser of its own. Pure, so it
/// is pinned by unit tests rather than by having a repo on the far side.
public struct WorktreePorcelainEntry: Equatable, Sendable {
    public let path: String
    /// Commit the worktree has checked out; empty for a bare entry.
    public let head: String
    /// Short branch name (`orchard/apricot`), empty when detached or bare.
    public let branch: String
    public let isBare: Bool
    public let isDetached: Bool
    /// git marked the entry locked or prunable — it is registered but not usable as-is.
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(path: String, head: String = "", branch: String = "",
                isBare: Bool = false, isDetached: Bool = false,
                isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

public enum WorktreePorcelain {
    /// Parse `git worktree list --porcelain`. Records are separated by a blank line and
    /// each starts with `worktree <path>`; unknown attribute lines are ignored so a
    /// newer git that adds one cannot make the whole listing unparseable.
    public static func parse(_ output: String) -> [WorktreePorcelainEntry] {
        var entries: [WorktreePorcelainEntry] = []
        var path: String?
        var head = "", branch = ""
        var bare = false, detached = false, locked = false, prunable = false

        func flush() {
            guard let value = path, !value.isEmpty else { return }
            entries.append(WorktreePorcelainEntry(
                path: value, head: head, branch: branch, isBare: bare,
                isDetached: detached, isLocked: locked, isPrunable: prunable))
            path = nil
            head = ""; branch = ""
            bare = false; detached = false; locked = false; prunable = false
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { flush(); continue }
            let (key, value) = split(line)
            switch key {
            case "worktree":
                flush()
                path = value
            case "HEAD": head = value
            case "branch": branch = shortBranch(value)
            case "bare": bare = true
            case "detached": detached = true
            case "locked": locked = true
            case "prunable": prunable = true
            default: continue
            }
        }
        flush()
        return entries
    }

    /// `refs/heads/orchard/apricot` → `orchard/apricot`. Anything that is not a local
    /// branch ref is returned unchanged rather than mangled.
    public static func shortBranch(_ ref: String) -> String {
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
