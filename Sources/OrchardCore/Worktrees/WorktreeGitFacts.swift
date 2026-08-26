import Foundation

/// The git facts a workspace projection needs about one checkout: what commit it has and
/// what branch it is on. Everything else a `Workspace` carries comes from
/// `orchard-data.json` or from the repo's git-config metadata, neither of which costs a
/// process.
public struct WorktreeGitFacts: Equatable, Sendable {
    /// Commit the worktree has checked out. Empty for a bare entry or a repo with no
    /// commits yet.
    public let head: String
    /// Short branch name, or empty when detached or bare.
    public let branch: String
    public let isDetached: Bool

    public init(head: String, branch: String, isDetached: Bool = false) {
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
    }
}

/// Reads `WorktreeGitFacts` for whole repos at a time, one `git` spawn each, with the
/// repos read in parallel.
///
/// Serial-per-repo was the other half of a slow workspace switch: three repos meant three
/// round trips laid end to end, and each of those was already several spawns. One spawn
/// per repo, all repos at once, makes the wall-clock of a listing the cost of a single
/// `git worktree list` rather than the sum of everything.
public enum WorktreeFactsReader {
    /// Facts for one repo, keyed by standardized worktree path (the primary checkout
    /// included). Returns an empty map when git could not answer — a folder that is not a
    /// repo is an ordinary case, not an error.
    public static func facts(forRepo repo: URL, git: GitRunner = .shared)
        -> [String: WorktreeGitFacts] {
        guard let out = git.query(in: repo, ["worktree", "list", "--porcelain"]) else { return [:] }
        let entries = WorktreePorcelain.parse(out)
        var indexed = index(entries)
        // A repo can be registered by a path *inside* the checkout, in which case git
        // answers with the toplevel and the caller's own spelling would find nothing.
        // git always prints the main worktree first, so that entry is the right answer
        // for whatever path was used to reach it.
        let repoKey = key(repo)
        if indexed[repoKey] == nil, let main = entries.first(where: { !$0.isBare }) {
            indexed[repoKey] = WorktreeGitFacts(head: main.head, branch: main.branch,
                                                isDetached: main.isDetached)
        }
        return indexed
    }

    /// The same read for several repos at once. Order of the result matches `repos`.
    ///
    /// `concurrentPerform` rather than a task group because every caller is a synchronous
    /// projection: the point is to overlap the process spawns, not to restructure the
    /// call sites that need the answer before they can return.
    public static func facts(forRepos repos: [URL], git: GitRunner = .shared)
        -> [[String: WorktreeGitFacts]] {
        guard !repos.isEmpty else { return [] }
        if repos.count == 1 { return [facts(forRepo: repos[0], git: git)] }

        let lock = NSLock()
        var out = [[String: WorktreeGitFacts]](repeating: [:], count: repos.count)
        DispatchQueue.concurrentPerform(iterations: repos.count) { index in
            let value = facts(forRepo: repos[index], git: git)
            lock.lock()
            out[index] = value
            lock.unlock()
        }
        return out
    }

    /// Fold porcelain entries into a path-keyed map. Bare entries are dropped: a bare repo
    /// has no working tree to project.
    public static func index(_ entries: [WorktreePorcelainEntry]) -> [String: WorktreeGitFacts] {
        var out: [String: WorktreeGitFacts] = [:]
        for entry in entries where !entry.isBare {
            out[key(entry.path)] = WorktreeGitFacts(head: entry.head, branch: entry.branch,
                                                    isDetached: entry.isDetached)
        }
        return out
    }

    /// Lookup key for a worktree path, symlinks resolved.
    ///
    /// git prints the realpath of every worktree (`/private/tmp/...` where Orchard holds
    /// `/tmp/...`), so a map keyed on the stored spelling would miss every entry on macOS
    /// and quietly report an empty branch and head for workspaces that have both.
    public static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
