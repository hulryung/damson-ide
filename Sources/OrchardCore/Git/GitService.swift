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
    /// Whether `added`/`deleted` were actually measured.
    ///
    /// False only for an untracked file this refresh declined to read: too large on its
    /// own, or past the refresh's whole-file read budget. That is a real change of
    /// unknown size, which is a different claim from "a change of zero lines" and from
    /// "binary" — reporting either of those instead is how a sidebar ends up lying about
    /// a file nobody looked at.
    public let linesCounted: Bool

    public init(path: String, kind: Kind, added: Int, deleted: Int, isBinary: Bool = false,
                linesCounted: Bool = true) {
        self.path = path
        self.kind = kind
        self.added = added
        self.deleted = deleted
        self.isBinary = isBinary
        self.linesCounted = linesCounted
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
    /// Whether every file in `files` had its line counts measured. False makes `added`
    /// a floor rather than a total, and the UI says so instead of printing it as fact.
    public let countsComplete: Bool

    public init(files: [GitFileChange]) {
        self.files = files
        self.added = files.reduce(0) { $0 + $1.added }
        self.deleted = files.reduce(0) { $0 + $1.deleted }
        self.countsComplete = files.allSatisfy { $0.linesCounted }
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
    ///
    /// Three `git` spawns, down from eight. `status --porcelain=v2 --branch` carries the
    /// branch, the upstream, the ahead/behind counts and the untracked list that five
    /// separate spawns used to fetch; `diff --raw --numstat` carries change kind and line
    /// counts in one walk; `log --format=%s` carries both how many commits are ahead of
    /// the fork point and the newest subject.
    ///
    /// Caching is `GitFactsCache`'s job, not this type's: it is the thing that owns a
    /// watcher and can say when a reading stopped being true.
    public func status(worktree: URL, baseRef: String) -> GitWorktreeStatus {
        facts(worktree: worktree, baseRef: baseRef).status
    }

    /// The status reading **and** the conflict summary, from the same three spawns.
    ///
    /// The conflict summary used to cost two `git` processes of its own — a
    /// `rev-parse --absolute-git-dir` and a second `git status --porcelain`. Both are
    /// gone: porcelain v2 already names every unmerged path in the reading that answers
    /// "is this tree dirty", and which operation is mid-flight is read from the control
    /// files in the git dir, which is resolved from `<worktree>/.git` without asking git.
    /// A workspace switch that used to run five processes now runs three, and none of
    /// them if the cache still holds a reading nothing has invalidated.
    public func facts(worktree: URL, baseRef: String) -> GitWorktreeFacts {
        let porcelain = GitStatusPorcelainV2.parse(
            git.query(in: worktree, GitStatusPorcelainV2.arguments) ?? "")
        let stat = diffStat(worktree: worktree, baseRef: baseRef, untracked: porcelain.untracked)
        let subjects = commitSubjects(worktree: worktree, baseRef: baseRef)

        // No upstream is the normal case for a fresh agent branch — `nil` means
        // "nothing to push to", which the delete preflight treats differently from "0 unpushed".
        let unpushed = porcelain.upstream == nil ? nil : porcelain.ahead

        let status = GitWorktreeStatus(
            branch: porcelain.branch, stat: stat, commitsAhead: subjects.count,
            hasUncommittedChanges: porcelain.hasChanges,
            lastCommitSubject: subjects.first, unpushedCommits: unpushed)
        return GitWorktreeFacts(
            status: status,
            conflicts: GitConflictService(git: git).summary(worktree: worktree,
                                                            unmerged: porcelain.unmerged))
    }

    /// Commit subjects on HEAD but not on `baseRef`, newest first. The count is
    /// `commitsAhead` and the first element is `lastCommitSubject`, so one walk answers
    /// both — `rev-list --count` plus `log -1` were two spawns over the same commits.
    private func commitSubjects(worktree: URL, baseRef: String) -> [String] {
        guard let out = git.query(in: worktree, ["log", "-z", "--format=%s", "\(baseRef)..HEAD"])
        else { return [] }
        return out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// Changed files + line counts vs `baseRef`, including files the agent created but
    /// never added to the index (which `git diff` alone would miss entirely).
    ///
    /// Rename detection is deliberately off (see `GitRawNumstat.arguments`): a rename
    /// reads as delete+add in the file list, and the rendered diff still shows it as git
    /// sees it.
    ///
    /// `untracked` lets a caller that already ran `status --porcelain=v2 -uall` hand the
    /// untracked list straight in instead of paying a second spawn for it.
    public func diffStat(worktree: URL, baseRef: String, untracked: [String]? = nil) -> GitDiffStat {
        var files: [GitFileChange] = []
        for entry in GitRawNumstat.parse(
            git.query(in: worktree, GitRawNumstat.arguments(baseRef: baseRef)) ?? "")
        {
            files.append(GitFileChange(
                path: entry.path,
                // git can suffix a similarity score (`R100`); only the letter is meaningful.
                kind: entry.statusLetter.flatMap(\.first).map { Self.kind(forStatusLetter: String($0)) }
                    ?? .modified,
                added: entry.added, deleted: entry.deleted, isBinary: entry.isBinary))
        }
        files.append(contentsOf: untrackedChanges(worktree: worktree, paths: untracked))

        files.sort { $0.path < $1.path }
        return GitDiffStat(files: files)
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
    ///
    /// `paths` short-circuits the `ls-files` spawn when the caller already has the list
    /// from `status --porcelain=v2 -uall`, which reports exactly the same set.
    private func untrackedChanges(worktree: URL, paths: [String]? = nil) -> [GitFileChange] {
        let relatives: [String]
        if let paths {
            relatives = paths
        } else {
            guard let out = git.query(in: worktree,
                                      ["ls-files", "--others", "--exclude-standard", "-z"])
            else { return [] }
            relatives = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        }
        var budget = ReadBudget()
        return relatives.map { path in
            let reading = Self.countLines(at: worktree.appendingPathComponent(path),
                                          budget: &budget)
            return GitFileChange(path: path, kind: .untracked,
                                 added: reading.lines, deleted: 0,
                                 isBinary: reading.binary, linesCounted: reading.counted)
        }
    }

    /// What one status reading is allowed to spend reading untracked file content.
    ///
    /// There is no `git` command that counts the lines in a file git is not tracking, so
    /// the only way to put a `+N` on a brand-new file is to read it — and a checkout with
    /// a few thousand untracked files was reading *all of them, whole*, on every sidebar
    /// refresh. Both halves are bounded because both can be the cost: 3000 tiny files cost
    /// as much as 100 MB of large ones, and a budget in bytes alone would not notice.
    /// Everything is counted until the budget runs out; what is past it is reported as a
    /// change of unknown size, never as zero lines.
    public struct ReadBudget {
        public var bytes: Int
        public var files: Int
        public init(bytes: Int = GitService.untrackedByteBudget,
                    files: Int = GitService.untrackedFileBudget) {
            self.bytes = bytes
            self.files = files
        }
    }

    /// Sized so a refresh cannot spend more here than on the git it is already running.
    /// Measured on a warm cache this reader does about 2 MB/ms and about 12 µs a file, so
    /// the two bounds together cap this at roughly 30 ms — under one git spawn's worth of
    /// the time a switch used to spend, and reached only by a checkout with thousands of
    /// untracked files, which is exactly the case that used to have no bound at all.
    public static let untrackedByteBudget = 16 * 1024 * 1024
    public static let untrackedFileBudget = 2000
    /// Per-file ceiling. A file this large is not something a sidebar `+N` is worth
    /// reading; it reads as uncounted, not as binary.
    public static let untrackedFileCeiling = 2 * 1024 * 1024

    /// Line count of an untracked file, whether it looks binary (a NUL byte in the head,
    /// the same heuristic git uses), and whether it was counted at all.
    ///
    /// `stat` and a plain `read` rather than `attributesOfItem` and `Data(contentsOf:)`:
    /// the old pair spent most of its time building an `NSDictionary` of every attribute
    /// of a file to read one field off it, which is what made a few thousand untracked
    /// files expensive regardless of how big they were. The newline scan is `memchr`.
    static func countLines(at url: URL, budget: inout ReadBudget)
        -> (lines: Int, binary: Bool, counted: Bool) {
        let path = url.path
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return (0, false, false)
        }
        let size = Int(info.st_size)
        guard budget.files > 0, size <= untrackedFileCeiling, size <= budget.bytes else {
            return (0, false, false)
        }
        budget.files -= 1
        budget.bytes -= size
        if size == 0 { return (0, false, true) }

        let fd = path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { return (0, false, false) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: size)
        var filled = 0
        while filled < size {
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress!.advanced(by: filled), size - filled)
            }
            if got > 0 { filled += got; continue }
            if got == 0 { break }
            if errno == EINTR { continue }
            return (0, false, false)
        }
        guard filled > 0 else { return (0, false, true) }

        return buffer.withUnsafeBytes { raw -> (Int, Bool, Bool) in
            let base = raw.baseAddress!
            // git's own binary heuristic: a NUL anywhere in the first 8000 bytes.
            if memchr(base, 0, min(8000, filled)) != nil { return (0, true, true) }
            var newlines = 0
            var offset = 0
            while offset < filled {
                guard let hit = memchr(base + offset, 0x0A, filled - offset) else { break }
                newlines += 1
                offset = UnsafeRawPointer(hit) - base + 1
            }
            // A trailing line without a final newline still counts.
            let last = raw.load(fromByteOffset: filled - 1, as: UInt8.self)
            return (last == 0x0A ? newlines : newlines + 1, false, true)
        }
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
