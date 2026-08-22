import Foundation

/// One changed path in a worktree, relative to the commit the worktree forked from.
public struct GitFileChange: Equatable, Sendable, Identifiable, Hashable {
    /// git's status letter, narrowed to what the UI decorates differently.
    public enum Kind: String, Sendable, Hashable {
        case added, modified, deleted, untracked, conflicted, typeChanged

        /// Single-letter badge shown in the file list (matches git's own vocabulary).
        public var letter: String {
            switch self {
            case .added: return "A"
            case .modified: return "M"
            case .deleted: return "D"
            case .untracked: return "U"
            case .conflicted: return "!"
            case .typeChanged: return "T"
            }
        }
    }

    public var id: String { path }
    /// Repo-relative path.
    public let path: String
    public let kind: Kind
    public let added: Int
    public let deleted: Int
    /// git reported `-` line counts — a binary blob, so +/- are meaningless.
    public let isBinary: Bool

    public init(path: String, kind: Kind, added: Int, deleted: Int, isBinary: Bool = false) {
        self.path = path
        self.kind = kind
        self.added = added
        self.deleted = deleted
        self.isBinary = isBinary
    }

    /// Just the filename, for the primary label in a file row.
    public var fileName: String { (path as NSString).lastPathComponent }
    /// Containing directory, for the dimmed secondary label.
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

/// Everything an agent changed in its worktree since it forked — the summary the sidebar
/// row and the diff pane header both render.
public struct GitDiffStat: Equatable, Sendable {
    public let files: [GitFileChange]
    public let added: Int
    public let deleted: Int

    public init(files: [GitFileChange]) {
        self.files = files
        self.added = files.reduce(0) { $0 + $1.added }
        self.deleted = files.reduce(0) { $0 + $1.deleted }
    }

    public static let empty = GitDiffStat(files: [])
    public var fileCount: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }
}

/// A worktree's git state: what changed, how far it has diverged, and whether there is
/// work that would be lost by deleting it.
public struct GitWorktreeStatus: Equatable, Sendable {
    public let branch: String
    public let stat: GitDiffStat
    /// Commits on this branch not on the base commit.
    public let commitsAhead: Int
    /// Uncommitted modifications (tracked or untracked) exist in the working tree.
    public let hasUncommittedChanges: Bool
    /// Subject line of the branch's most recent commit, if it has any of its own.
    public let lastCommitSubject: String?
    /// Commits not present on the branch's upstream. `nil` when there is no upstream.
    public let unpushedCommits: Int?

    public static let unknown = GitWorktreeStatus(
        branch: "", stat: .empty, commitsAhead: 0,
        hasUncommittedChanges: false, lastCommitSubject: nil, unpushedCommits: nil)

    public init(branch: String, stat: GitDiffStat, commitsAhead: Int,
                hasUncommittedChanges: Bool, lastCommitSubject: String?, unpushedCommits: Int?) {
        self.branch = branch
        self.stat = stat
        self.commitsAhead = commitsAhead
        self.hasUncommittedChanges = hasUncommittedChanges
        self.lastCommitSubject = lastCommitSubject
        self.unpushedCommits = unpushedCommits
    }

    /// Nothing was produced here — safe to discard without asking.
    public var isPristine: Bool {
        stat.isEmpty && commitsAhead == 0 && !hasUncommittedChanges
    }
}

/// Read-only git queries against an agent's worktree, plus the few mutations the review
/// flow needs (commit, push). Every call shells out; nothing is cached here — callers
/// (`WorktreeRecord`) own refresh cadence so the UI decides when it's worth the syscalls.
///
/// All diffs are computed against the *base commit the worktree forked from*, not `HEAD`,
/// so committed and uncommitted agent work read as one change set. That matches how a
/// reviewer thinks about an agent's output: "what did this agent do", not "what is staged".
public struct GitService: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = .shared) {
        self.git = git
    }

    // MARK: - Status

    /// Full status of `worktree` relative to `baseRef` (the commit it forked from).
    public func status(worktree: URL, baseRef: String) -> GitWorktreeStatus {
        let branch = git.line(in: worktree, ["rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
        let stat = diffStat(worktree: worktree, baseRef: baseRef)

        let ahead = git.line(in: worktree, ["rev-list", "--count", "\(baseRef)..HEAD"])
            .flatMap(Int.init) ?? 0
        let dirty = !(git.query(in: worktree, ["status", "--porcelain"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let subject = ahead > 0
            ? git.line(in: worktree, ["log", "-1", "--pretty=%s"])
            : nil
        // No upstream is the normal case for a fresh agent branch — `nil` means
        // "nothing to push to", which the delete preflight treats differently from "0 unpushed".
        let unpushed = git.line(in: worktree, ["rev-parse", "--abbrev-ref", "@{upstream}"]) != nil
            ? git.line(in: worktree, ["rev-list", "--count", "@{upstream}..HEAD"]).flatMap(Int.init)
            : nil

        return GitWorktreeStatus(
            branch: branch, stat: stat, commitsAhead: ahead,
            hasUncommittedChanges: dirty, lastCommitSubject: subject, unpushedCommits: unpushed)
    }

    /// Changed files + line counts vs `baseRef`, including files the agent created but
    /// never added to the index (which `git diff` alone would miss entirely).
    ///
    /// Rename detection is deliberately off: with `-M`, `--numstat -z` emits a three-field
    /// record that complicates parsing for a cosmetic gain. A rename reads as delete+add in
    /// the file list; the rendered diff still shows it as git sees it.
    public func diffStat(worktree: URL, baseRef: String) -> GitDiffStat {
        var files: [GitFileChange] = []

        let kinds = nameStatus(worktree: worktree, baseRef: baseRef)
        for (path, added, deleted, binary) in numstat(worktree: worktree, baseRef: baseRef) {
            files.append(GitFileChange(path: path, kind: kinds[path] ?? .modified,
                                       added: added, deleted: deleted, isBinary: binary))
        }
        files.append(contentsOf: untrackedChanges(worktree: worktree))

        files.sort { $0.path < $1.path }
        return GitDiffStat(files: files)
    }

    /// `added deleted path` triples from `git diff --numstat`. A binary file reports `-`
    /// for both counts.
    private func numstat(worktree: URL, baseRef: String) -> [(String, Int, Int, Bool)] {
        guard let out = git.query(in: worktree, ["diff", "--numstat", "-z", baseRef, "--"]) else {
            return []
        }
        var result: [(String, Int, Int, Bool)] = []
        // `-z` makes each record `added\tdeleted\tpath` terminated by NUL (no rename records,
        // since -M is off), which keeps paths with spaces/newlines intact.
        for record in out.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let isBinary = parts[0] == "-" || parts[1] == "-"
            result.append((String(parts[2]),
                           Int(parts[0]) ?? 0,
                           Int(parts[1]) ?? 0,
                           isBinary))
        }
        return result
    }

    /// path → change kind, from `git diff --name-status`.
    private func nameStatus(worktree: URL, baseRef: String) -> [String: GitFileChange.Kind] {
        guard let out = git.query(in: worktree, ["diff", "--name-status", "-z", baseRef, "--"]) else {
            return [:]
        }
        // `-z` alternates status and path fields: "M\0path\0A\0path\0…".
        let fields = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var kinds: [String: GitFileChange.Kind] = [:]
        var i = 0
        while i + 1 < fields.count {
            let code = fields[i].first.map(String.init) ?? "M"
            let path = fields[i + 1]
            kinds[path] = Self.kind(forStatusLetter: code)
            i += 2
        }
        return kinds
    }

    private static func kind(forStatusLetter code: String) -> GitFileChange.Kind {
        switch code {
        case "A": return .added
        case "D": return .deleted
        case "T": return .typeChanged
        case "U": return .conflicted
        default: return .modified
        }
    }

    /// Files the agent created that git isn't tracking yet. `git diff` never reports these,
    /// but to a reviewer they are the most interesting changes of all, so they're counted as
    /// wholly-added files.
    private func untrackedChanges(worktree: URL) -> [GitFileChange] {
        guard let out = git.query(in: worktree, ["ls-files", "--others", "--exclude-standard", "-z"])
        else { return [] }
        return out.split(separator: "\0", omittingEmptySubsequences: true).map { rel in
            let path = String(rel)
            let (lines, binary) = Self.countLines(at: worktree.appendingPathComponent(path))
            return GitFileChange(path: path, kind: .untracked, added: lines, deleted: 0, isBinary: binary)
        }
    }

    /// Line count of an untracked file, and whether it looks binary (a NUL byte in the head,
    /// the same heuristic git uses). Large files are reported as binary rather than read
    /// whole — the count isn't worth stalling a sidebar refresh over.
    private static func countLines(at url: URL) -> (Int, Bool) {
        let maxBytes = 2 * 1024 * 1024
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return (0, true) }
        if data.prefix(8000).contains(0) { return (0, true) }
        let newlines = data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
        // A trailing line without a final newline still counts.
        return (data.last == 0x0A || data.isEmpty ? newlines : newlines + 1, false)
    }

    // MARK: - Diff text

    /// Unified diff of the whole worktree vs `baseRef`, or of one path when given.
    /// Untracked files are appended via `--no-index` so a brand-new file still renders as
    /// a diff instead of silently showing nothing.
    public func diff(worktree: URL, baseRef: String, path: String? = nil,
                     contextLines: Int = 3) -> String {
        var args = ["diff", "--no-color", "-U\(contextLines)", baseRef, "--"]
        if let path { args.append(path) }
        var text = git.query(in: worktree, args) ?? ""

        // One untracked path was asked for explicitly, or none was and we want them all.
        let untracked = (git.query(in: worktree, ["ls-files", "--others", "--exclude-standard", "-z"]) ?? "")
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        for rel in untracked where path == nil || path == rel {
            text += untrackedDiff(worktree: worktree, path: rel, contextLines: contextLines)
        }
        return text
    }

    /// Render an untracked file as a diff against /dev/null. `--no-index` exits 1 whenever
    /// it finds differences, which is the expected case here, so its output is read directly
    /// rather than through the throwing runner.
    private func untrackedDiff(worktree: URL, path: String, contextLines: Int) -> String {
        let out = try? git.capture(
            ["-C", worktree.path, "diff", "--no-color", "-U\(contextLines)",
             "--no-index", "--", "/dev/null", path])
        return out?.stdout ?? ""
    }

    // MARK: - Mutations used by the review flow

    /// Stage everything and commit. Returns the new commit's short sha.
    @discardableResult
    public func commitAll(worktree: URL, message: String) throws -> String {
        try git.run(in: worktree, ["add", "-A"])
        try git.run(in: worktree, ["commit", "-m", message])
        return git.line(in: worktree, ["rev-parse", "--short", "HEAD"]) ?? ""
    }

    /// Push the worktree's branch, setting upstream on first push.
    public func push(worktree: URL, remote: String = "origin") throws {
        let branch = git.line(in: worktree, ["rev-parse", "--abbrev-ref", "HEAD"]) ?? "HEAD"
        try git.run(in: worktree, ["push", "--set-upstream", remote, branch])
    }
}
