import Foundation

// MARK: - Vocabulary

/// Why a source-control mutation was refused. Codes are stable so the panel can
/// show them inline instead of swallowing a failure or parsing git's prose.
///
/// `gitFailed` is the escape hatch for a real git subprocess error — the payload
/// is git's own stderr, the same honesty the review pane uses.
public enum GitSourceControlError: Error, Equatable, Sendable {
    case emptyCommitMessage
    case emptyStagedSet
    case noRemote
    case notARepository
    case invalidBranchName
    case branchExists(String)
    case branchNotFound(String)
    case gitFailed(String)

    public var code: String {
        switch self {
        case .emptyCommitMessage: return "empty_commit_message"
        case .emptyStagedSet: return "empty_staged_set"
        case .noRemote: return "no_remote"
        case .notARepository: return "not_a_repository"
        case .invalidBranchName: return "invalid_branch_name"
        case .branchExists: return "branch_exists"
        case .branchNotFound: return "branch_not_found"
        case .gitFailed: return "git_failed"
        }
    }

    public var message: String {
        switch self {
        case .emptyCommitMessage:
            return "Commit message is empty."
        case .emptyStagedSet:
            return "Nothing is staged to commit."
        case .noRemote:
            return "This repository has no remotes."
        case .notARepository:
            return "Not a git repository."
        case .invalidBranchName:
            return "Branch name is empty or not a valid git ref."
        case .branchExists(let name):
            return "Branch '\(name)' already exists."
        case .branchNotFound(let name):
            return "Branch '\(name)' does not exist."
        case .gitFailed(let detail):
            return detail
        }
    }

    /// `code — message`, the line the panel renders so a failure is never a silent no-op.
    public var displayText: String { "\(code) — \(message)" }
}

extension GitSourceControlError: CustomStringConvertible {
    public var description: String { displayText }
}

/// One changed path as the source-control panel lists it: staged or unstaged,
/// with the same `GitFileChange.Kind` letters the diff pane paints.
public struct GitSourceControlChange: Equatable, Sendable, Identifiable, Hashable {
    public enum Area: String, Sendable, Hashable {
        case staged, unstaged
    }

    public var id: String { "\(area.rawValue):\(path)" }
    public let path: String
    public let kind: GitFileChange.Kind
    public let area: Area

    public init(path: String, kind: GitFileChange.Kind, area: Area) {
        self.path = path
        self.kind = kind
        self.area = area
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

/// Working-tree source-control state for the selected workspace: what is staged,
/// what is not, which branch we are on, and whether a remote exists so push/pull
/// can be offered without guessing.
public struct GitSourceControlSnapshot: Equatable, Sendable {
    public let branch: String
    public let branches: [String]
    public let staged: [GitSourceControlChange]
    public let unstaged: [GitSourceControlChange]
    public let remotes: [String]

    public static let empty = GitSourceControlSnapshot(
        branch: "", branches: [], staged: [], unstaged: [], remotes: [])

    public init(branch: String, branches: [String],
                staged: [GitSourceControlChange], unstaged: [GitSourceControlChange],
                remotes: [String]) {
        self.branch = branch
        self.branches = branches
        self.staged = staged
        self.unstaged = unstaged
        self.remotes = remotes
    }

    public var hasRemote: Bool { !remotes.isEmpty }
    public var stagedCount: Int { staged.count }
    public var unstagedCount: Int { unstaged.count }
    public var isClean: Bool { staged.isEmpty && unstaged.isEmpty }

    /// First remote, preferring `origin` when it exists — the same default
    /// `GitService.push` uses.
    public var preferredRemote: String? {
        if remotes.contains("origin") { return "origin" }
        return remotes.first
    }
}

// MARK: - Service

/// Staged/unstaged listing and the mutations the right-sidebar source-control
/// panel drives. UI-free: every method shells out through `GitRunner` and
/// returns a typed error. Nothing is cached; the caller owns refresh cadence.
///
/// Deliberately a new type rather than growing `GitService`. That service
/// measures a worktree against its fork-point (review: "what did the agent
/// do"). This one measures the index versus the working tree (source control:
/// "what will the next commit contain").
public struct GitSourceControlService: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = .shared) {
        self.git = git
    }

    // MARK: Snapshot

    /// Current branch, local branches, staged/unstaged paths, and remotes.
    /// Throws `notARepository` for a folder workspace so the panel can say so
    /// instead of rendering an empty, healthy-looking list.
    public func snapshot(worktree: URL) throws -> GitSourceControlSnapshot {
        try requireRepository(worktree)
        let branch = git.line(in: worktree, ["rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
        let branches = listBranches(worktree: worktree)
        let remotes = listRemotes(worktree: worktree)
        // `-uall` so an untracked directory is listed as its files, not a single
        // `src/` entry — the panel and the diff pane both talk in file paths.
        let porcelain = git.query(in: worktree, ["status", "--porcelain", "-z", "-uall"]) ?? ""
        let parsed = Self.parsePorcelain(porcelain)
        return GitSourceControlSnapshot(
            branch: branch, branches: branches,
            staged: parsed.staged, unstaged: parsed.unstaged,
            remotes: remotes)
    }

    /// Decode `git status --porcelain -z` into staged vs unstaged entries.
    ///
    /// Same rename-record trap as conflict porcelain: an `R`/`C` entry carries a
    /// second NUL-terminated origin path that must be consumed or later records
    /// shift. Unmerged XY codes land as `conflicted` on the unstaged side so
    /// they share the diff pane's `!` badge instead of looking like a normal
    /// modify.
    public static func parsePorcelain(_ text: String)
        -> (staged: [GitSourceControlChange], unstaged: [GitSourceControlChange]) {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var staged: [GitSourceControlChange] = []
        var unstaged: [GitSourceControlChange] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            let path = String(field.dropFirst(3))
            if code.hasPrefix("R") || code.hasPrefix("C") { i += 1 }
            if code == "!!" { continue }

            if code == "??" {
                unstaged.append(GitSourceControlChange(path: path, kind: .untracked, area: .unstaged))
                continue
            }

            if isUnmerged(code) {
                unstaged.append(GitSourceControlChange(path: path, kind: .conflicted, area: .unstaged))
                continue
            }

            let x = code[code.startIndex]
            let y = code[code.index(after: code.startIndex)]
            if let kind = kind(forIndexLetter: x) {
                staged.append(GitSourceControlChange(path: path, kind: kind, area: .staged))
            }
            if let kind = kind(forWorktreeLetter: y) {
                unstaged.append(GitSourceControlChange(path: path, kind: kind, area: .unstaged))
            }
        }
        return (staged.sorted { $0.path < $1.path },
                unstaged.sorted { $0.path < $1.path })
    }

    /// Unmerged porcelain XY codes — the same set `GitConflictKind` knows, listed
    /// here so this file does not reach into conflict-review types.
    private static let unmergedCodes: Set<String> = [
        "UU", "AA", "DD", "AU", "UA", "DU", "UD",
    ]

    private static func isUnmerged(_ code: String) -> Bool {
        unmergedCodes.contains(code)
    }

    /// Index column (staged). Space / `?` / `!` means "not staged".
    ///
    /// Letters match `GitService`'s kind map so the panel and the diff pane
    /// paint the same badge for the same git letter. `R`/`C` fall through to
    /// modified the same way an unknown name-status letter does there.
    private static func kind(forIndexLetter letter: Character) -> GitFileChange.Kind? {
        switch letter {
        case "A": return .added
        case "D": return .deleted
        case "T": return .typeChanged
        case "U": return .conflicted
        case " ", "?", "!": return nil
        default: return .modified
        }
    }

    /// Worktree column (unstaged). `?` is untracked; space / `!` is unchanged.
    private static func kind(forWorktreeLetter letter: Character) -> GitFileChange.Kind? {
        switch letter {
        case "A": return .added
        case "D": return .deleted
        case "T": return .typeChanged
        case "U": return .conflicted
        case "?": return .untracked
        case " ", "!": return nil
        default: return .modified
        }
    }

    // MARK: Stage / unstage

    public func stage(worktree: URL, path: String) throws {
        try requireRepository(worktree)
        try run(in: worktree, ["add", "--", path])
    }

    public func unstage(worktree: URL, path: String) throws {
        try requireRepository(worktree)
        // `restore --staged` is the modern unstage; it keeps the working tree
        // intact, which is what a source-control "unstage" button means.
        try run(in: worktree, ["restore", "--staged", "--", path])
    }

    public func stageAll(worktree: URL) throws {
        try requireRepository(worktree)
        try run(in: worktree, ["add", "-A"])
    }

    public func unstageAll(worktree: URL) throws {
        try requireRepository(worktree)
        let snap = try snapshot(worktree: worktree)
        // An empty index is already the desired state — do not invent a git
        // failure (or a silent no-op that looks like one) for "unstage nothing".
        guard !snap.staged.isEmpty else { return }
        try run(in: worktree, ["restore", "--staged", "--", "."])
    }

    // MARK: Commit

    /// Commit the index only. Refuses an empty/whitespace message and an empty
    /// staged set with typed codes — never falls through to `git commit` so the
    /// panel can show the refusal without depending on git's wording.
    @discardableResult
    public func commit(worktree: URL, message: String) throws -> String {
        try requireRepository(worktree)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitSourceControlError.emptyCommitMessage }
        let snap = try snapshot(worktree: worktree)
        guard !snap.staged.isEmpty else { throw GitSourceControlError.emptyStagedSet }
        try run(in: worktree, ["commit", "-m", trimmed])
        return git.line(in: worktree, ["rev-parse", "--short", "HEAD"]) ?? ""
    }

    // MARK: Branches

    public func switchBranch(worktree: URL, name: String) throws {
        try requireRepository(worktree)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitSourceControlError.invalidBranchName }
        let branches = listBranches(worktree: worktree)
        guard branches.contains(trimmed) else {
            throw GitSourceControlError.branchNotFound(trimmed)
        }
        try run(in: worktree, ["switch", "--", trimmed])
    }

    /// Create `name` and switch to it. Refuses an empty or illegal ref, and
    /// refuses to clobber an existing local branch.
    public func createBranch(worktree: URL, name: String) throws {
        try requireRepository(worktree)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitSourceControlError.invalidBranchName }
        if git.query(in: worktree, ["check-ref-format", "--branch", trimmed]) == nil {
            throw GitSourceControlError.invalidBranchName
        }
        let branches = listBranches(worktree: worktree)
        if branches.contains(trimmed) {
            throw GitSourceControlError.branchExists(trimmed)
        }
        try run(in: worktree, ["switch", "-c", trimmed])
    }

    // MARK: Push / pull

    /// Push the current branch, setting upstream on first push. Refuses when
    /// no remote is configured — the panel hides the buttons in that case, and
    /// this is the typed backstop if something still calls it.
    public func push(worktree: URL) throws {
        try requireRepository(worktree)
        let snap = try snapshot(worktree: worktree)
        guard let remote = snap.preferredRemote else { throw GitSourceControlError.noRemote }
        let branch = snap.branch.isEmpty ? "HEAD" : snap.branch
        try run(in: worktree, ["push", "--set-upstream", remote, branch])
    }

    public func pull(worktree: URL) throws {
        try requireRepository(worktree)
        let snap = try snapshot(worktree: worktree)
        guard let remote = snap.preferredRemote else { throw GitSourceControlError.noRemote }
        let branch = snap.branch.isEmpty ? "HEAD" : snap.branch
        try run(in: worktree, ["pull", remote, branch])
    }

    // MARK: Internals

    private func requireRepository(_ worktree: URL) throws {
        guard git.line(in: worktree, ["rev-parse", "--is-inside-work-tree"]) == "true" else {
            throw GitSourceControlError.notARepository
        }
    }

    private func listBranches(worktree: URL) -> [String] {
        let out = git.query(in: worktree, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) ?? ""
        return out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func listRemotes(worktree: URL) -> [String] {
        let out = git.query(in: worktree, ["remote"]) ?? ""
        return out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func run(in worktree: URL, _ args: [String]) throws {
        do {
            try git.run(in: worktree, args)
        } catch let error as GitError {
            throw GitSourceControlError.gitFailed(error.message)
        } catch {
            throw GitSourceControlError.gitFailed(error.localizedDescription)
        }
    }
}
