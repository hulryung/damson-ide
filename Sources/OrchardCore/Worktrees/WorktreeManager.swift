import Darwin
import Foundation

/// A git worktree allocated for an agent's task.
///
/// Worktrees are **persistent**: they outlive the agent that created them and the app
/// session that spawned it. An agent finishing is not a reason to delete its work — the
/// user reviews the diff, merges or discards, and deletes deliberately. Everything needed
/// to re-attach to a worktree after a relaunch is recorded in the repo's own git config,
/// so no app-side store can drift out of sync with what is actually on disk.
public struct Worktree: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let baseRepo: URL   // main repo root
    public let path: URL       // worktree directory
    public let branch: String
    /// Commit this worktree forked from — the reference point every diff is measured against.
    public let baseRef: String
    /// Human-facing label (the task title that created it), shown instead of the raw branch.
    public let title: String
    public let createdAt: Date

    public init(id: UUID = UUID(), baseRepo: URL, path: URL, branch: String,
                baseRef: String = "", title: String = "", createdAt: Date = Date()) {
        self.id = id
        self.baseRepo = baseRepo
        self.path = path
        self.branch = branch
        self.baseRef = baseRef
        self.title = title
        self.createdAt = createdAt
    }
}

public struct GitError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { self.message = m }
    public var description: String { message }
}

/// `git branch -d` refused because the branch still holds unmerged commits.
///
/// The message is git's own first line (`error: the branch 'X' is not fully merged.`)
/// so callers can surface it verbatim — wrapping it in a `git … failed` prefix would
/// lose the contract T40's `--delete-branch` path advertises.
public struct BranchDeletionError: Error, CustomStringConvertible {
    public let branch: String
    public let message: String
    public init(branch: String, message: String) {
        self.branch = branch
        self.message = message
    }
    public var description: String { message }

    /// Git's stable first line for an unmerged `branch -d`. Hints after it vary by
    /// git version and config, so they are not part of the typed contract.
    public static func unmergedMessage(for branch: String) -> String {
        "error: the branch '\(branch)' is not fully merged."
    }
}

/// What deleting a worktree would destroy. Surfaced in the delete confirmation so the user
/// is never asked a yes/no question without being told the stakes — an agent's only output
/// often lives in uncommitted files.
public struct WorktreeDeletionPreflight: Sendable {
    public let worktree: Worktree
    public let status: GitWorktreeStatus
    /// Reasons deletion would lose work. Empty means it's safe to remove without asking.
    /// Branch merged/unmerged state is *not* a warning — it is named separately so a
    /// clean worktree with an unmerged branch is still `isSafe` until the caller
    /// also asks to delete the branch.
    public let warnings: [String]
    /// Whether `worktree.branch` is fully merged into its upstream (or HEAD).
    public let branchMerged: Bool

    public var isSafe: Bool { warnings.isEmpty }

    /// Preflight sentence naming the branch and its merged/unmerged state.
    public var branchStatusMessage: String {
        if branchMerged {
            return "branch '\(worktree.branch)' is merged"
        }
        return "branch '\(worktree.branch)' is not fully merged"
    }

    public init(worktree: Worktree, status: GitWorktreeStatus, warnings: [String],
                branchMerged: Bool) {
        self.worktree = worktree
        self.status = status
        self.warnings = warnings
        self.branchMerged = branchMerged
    }
}

/// Creates, tracks, and tears down git worktrees so each agent works in isolation.
///
/// All mutations of a base repo's `.git/worktrees` are serialized to avoid index-lock races
/// between parallel agents.
public final class WorktreeManager {
    /// Where worktrees are created (outside the user's checkout to avoid watcher/ignore noise).
    public let root: URL
    private let queue = DispatchQueue(label: "damson.orchestrator.worktree")
    private let git: GitRunner
    private let service: GitService

    public init(root: URL, git: GitRunner = .shared) {
        self.root = root
        self.git = git
        self.service = GitService(git: git)
    }

    /// Default worktree root for a repo: `~/Orchard/worktrees/<repo-name>/`.
    ///
    /// Deliberately **outside** the checkout. Worktrees nested inside the repo get picked up
    /// by file watchers, test globs, language servers, and `rg` — every one of which then
    /// scans N copies of the project — and a stray `rm -rf` of a build dir can take them with
    /// it. Keeping them out of the tree also means the repo needs no `.gitignore` change.
    public static func defaultRoot(for repo: URL) -> URL {
        let name = repo.lastPathComponent.replacingOccurrences(of: ".git", with: "")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Orchard", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(name.isEmpty ? "repo" : name, isDirectory: true)
    }

    /// git-config namespace holding each worktree's Orchard metadata, keyed by worktree id.
    private enum MetaKey {
        static let prefix = "orchard.worktree"
        static func key(_ id: String, _ field: String) -> String { "\(prefix).\(id).\(field)" }
        static func section(_ id: String) -> String { "\(prefix).\(id)" }
    }

    // MARK: - Repo inspection

    /// Resolve the repo root containing `cwd` (`git rev-parse --show-toplevel`).
    public func detectBaseRepo(from cwd: URL) throws -> URL {
        let out = try git.run(["-C", cwd.path, "rev-parse", "--show-toplevel"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError("not a git repository: \(cwd.path)") }
        return URL(fileURLWithPath: trimmed)
    }

    /// Resolve a ref (e.g. "HEAD") to a commit SHA, so all agents fork from one pinned base.
    public func resolveRef(_ ref: String, in repo: URL) throws -> String {
        let out = try git.run(["-C", repo.path, "rev-parse", ref])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Branches the user can fork a new agent from, current branch first. Local branches
    /// only — an agent needs somewhere to commit, and a remote-tracking ref isn't a valid
    /// branch point without creating a local branch anyway.
    public func localBranches(in repo: URL) -> [String] {
        let all = (git.query(in: repo, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) ?? "")
            .split(separator: "\n").map(String.init)
        guard let current = currentBranch(in: repo), all.contains(current) else { return all }
        return [current] + all.filter { $0 != current }
    }

    public func currentBranch(in repo: URL) -> String? {
        guard let name = git.line(in: repo, ["rev-parse", "--abbrev-ref", "HEAD"]), name != "HEAD"
        else { return nil }
        return name
    }

    /// `user.name` from git config, used to namespace agent branches the way a team already
    /// reads branch ownership (`dkkang/fix-parser`).
    public func gitUserName(in repo: URL) -> String? {
        git.line(in: repo, ["config", "user.name"])
    }

    /// The branch a new agent should fork from when the user doesn't pick one.
    ///
    /// Probed in order rather than assumed: forking from whatever happens to be checked out
    /// would silently inherit half-finished local work, and hardcoding `main` breaks every
    /// repo that still uses `master` or has no remote at all.
    public func defaultBaseRef(in repo: URL) -> String {
        let probes = [
            ("refs/remotes/origin/main", "origin/main"),
            ("refs/remotes/origin/master", "origin/master"),
            ("refs/heads/main", "main"),
            ("refs/heads/master", "master"),
        ]
        for (ref, name) in probes
        where git.line(in: repo, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]) != nil {
            return name
        }
        return currentBranch(in: repo) ?? "HEAD"
    }

    /// Refuse to proceed if the repo is mid-rebase/merge or otherwise not in a clean state
    /// to fork from. Surfaces a clear error rather than half-creating worktrees.
    public func validateReady(_ repo: URL) throws {
        let gitDir = try git.run(["-C", repo.path, "rev-parse", "--git-dir"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(fileURLWithPath: gitDir, relativeTo: repo)
        let fm = FileManager.default
        for marker in ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD"] {
            if fm.fileExists(atPath: base.appendingPathComponent(marker).path) {
                throw GitError("repo is mid-operation (\(marker)); resolve it before orchestrating")
            }
        }
    }

    // MARK: - Create

    /// Create a worktree on a new branch forked from `ref`, and record its metadata so a
    /// later launch can find it again.
    ///
    /// The branch name is uniquified by suffix rather than salted with a UUID:
    /// `orchard/fix-parser`, then `orchard/fix-parser-2`. Branch names are how a user
    /// identifies an agent's work in `git branch`, in a PR, or in another git client, so
    /// they are worth keeping readable.
    public func create(base: URL, branch: String, from ref: String, title: String = "") throws -> Worktree {
        let wt: Worktree = try queue.sync {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let uniqueBranch = uniqueBranchName(branch, in: base)
            let dir = uniqueDirectory(for: uniqueBranch)
            // The branch name reaches here from a user field and from task titles, and it
            // determines the directory. A name that escaped the root would put a worktree —
            // and later a recursive delete — somewhere nobody intended.
            try Self.assertInsideRoot(dir, root: root)

            // Pin the fork point to a concrete commit: `ref` may be a branch that moves
            // between now and when the diff is read, which would make the agent's change set
            // silently shift under the reviewer.
            let baseSha = (try? resolveRef(ref, in: base)) ?? ref

            // `--no-track` so the new branch has no upstream: without it git reports the
            // worktree as "behind by N" against the base before the agent has done anything.
            try git.run(["-C", base.path, "worktree", "add", "--no-track",
                         "-b", uniqueBranch, dir.path, baseSha])

            // Record the fork point where git itself can see it, so `git config
            // branch.<b>.base` answers "what was this branched from" outside Orchard too.
            _ = try? git.run(in: base, ["config", "--local", "--replace-all",
                                        "branch.\(uniqueBranch).base", ref])
            // First `git push` from an agent worktree should just work rather than failing
            // with "no upstream branch". Never overwrite an existing user preference.
            if git.line(in: base, ["config", "--get", "push.autoSetupRemote"]) == nil {
                _ = try? git.run(in: base, ["config", "--local", "push.autoSetupRemote", "true"])
            }

            let wt = Worktree(id: UUID(), baseRepo: base, path: dir, branch: uniqueBranch,
                              baseRef: baseSha, title: title.isEmpty ? uniqueBranch : title)
            writeMeta(wt)
            return wt
        }

        // Outside the lock: these touch only the new worktree, and copying a large
        // `node_modules` shouldn't block another agent's `git worktree add`.
        materializeSharedPaths(from: base, into: wt)
        return wt
    }

    /// Copy the project's declared `sharedPaths` from the primary checkout into a new
    /// worktree (`node_modules`, `.env`, build caches).
    ///
    /// These are exactly the files a fresh checkout can't produce and that are too expensive
    /// or too secret to regenerate per agent. Missing sources are skipped silently — a repo
    /// that has never been installed simply has nothing to share yet.
    private func materializeSharedPaths(from repo: URL, into wt: Worktree) {
        let config = OrchardProjectConfig.load(from: wt.path)
        guard !config.sharedPaths.isEmpty else { return }
        let fm = FileManager.default

        for rel in config.sharedPaths {
            guard let safe = Self.safeRelativePath(rel) else { continue }
            let source = repo.appendingPathComponent(safe)
            let target = wt.path.appendingPathComponent(safe)
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            // A symlink rather than a copy: instant regardless of size, and an agent that
            // runs `npm install` updates the one shared store the user already had.
            try? fm.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }

    /// A computed worktree directory must land strictly inside the configured root.
    static func assertInsideRoot(_ path: URL, root: URL) throws {
        let target = path.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard target.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw GitError("invalid worktree path (outside \(base)): \(target)")
        }
    }

    /// Reject anything that could escape the worktree — absolute paths and `..` segments.
    /// `sharedPaths` comes from a file in the repo, which an agent can edit.
    static func safeRelativePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        let parts = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    /// The project's `orchard.yaml` setup script for a worktree, if it declares one. The
    /// caller runs it in a visible terminal so a failing install isn't silent.
    public func setupScript(for wt: Worktree) -> String? {
        scriptField(\.setup, for: wt)
    }

    /// The project's `orchard.yaml` archive script, run just before deletion when the
    /// caller opted in with `--run-hooks`. v1 parsed this and never executed it.
    public func archiveScript(for wt: Worktree) -> String? {
        scriptField(\.archive, for: wt)
    }

    private func scriptField(_ keyPath: KeyPath<OrchardProjectConfig, String?>,
                             for wt: Worktree) -> String? {
        let script = OrchardProjectConfig.load(from: wt.path)[keyPath: keyPath]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (script?.isEmpty ?? true) ? nil : script
    }

    /// HEAD of a worktree (empty string if git can't answer). Folder workspaces have no
    /// HEAD; callers that project both shapes treat empty as "not a git checkout".
    public func headCommit(_ wt: Worktree) -> String {
        git.line(in: wt.path, ["rev-parse", "HEAD"]) ?? ""
    }

    /// Environment a setup or archive script runs with, so scripts can locate both ends of
    /// the pair without hardcoding paths.
    public func hookEnvironment(for wt: Worktree) -> [String: String] {
        [
            "ORCHARD_ROOT_PATH": wt.baseRepo.path,
            "ORCHARD_WORKTREE_PATH": wt.path.path,
            "ORCHARD_WORKSPACE_NAME": wt.path.lastPathComponent,
            "ORCHARD_BRANCH": wt.branch,
        ]
    }

    /// Append `-2`, `-3`… until the branch name is free.
    private func uniqueBranchName(_ desired: String, in repo: URL) -> String {
        let existing = Set((git.query(in: repo, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) ?? "")
            .split(separator: "\n").map(String.init))
        guard existing.contains(desired) else { return desired }
        var n = 2
        while existing.contains("\(desired)-\(n)") { n += 1 }
        return "\(desired)-\(n)"
    }

    /// Directory named after the branch's last segment, suffixed only on collision. Flat and
    /// readable (`…/worktrees/fix-parser`) rather than UUID-salted, so the path shown in a
    /// shell prompt or an editor title bar still tells the user which agent they're looking at.
    private func uniqueDirectory(for branch: String) -> URL {
        let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
        let safe = leaf.replacingOccurrences(of: " ", with: "-")
        var candidate = root.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(safe)-\(n)")
            n += 1
        }
        return candidate
    }

    // MARK: - Metadata (persisted in the repo's git config)

    private func writeMeta(_ wt: Worktree) {
        let id = wt.id.uuidString
        let fields: [(String, String)] = [
            ("path", wt.path.path),
            ("branch", wt.branch),
            ("baseRef", wt.baseRef),
            ("title", wt.title),
            ("createdAt", String(Int(wt.createdAt.timeIntervalSince1970))),
        ]
        for (field, value) in fields {
            _ = try? git.run(in: wt.baseRepo, ["config", MetaKey.key(id, field), value])
        }
    }

    private func clearMeta(repo: URL, id: String) {
        _ = try? git.run(in: repo, ["config", "--remove-section", MetaKey.section(id)])
    }

    /// Every Orchard-created worktree for `repo` that still exists on disk and is still
    /// registered with git. Metadata for worktrees since removed by hand is pruned, so the
    /// config can't accumulate ghosts.
    ///
    /// This is what makes worktrees survive a relaunch: the app rebuilds its list from git
    /// rather than from an app-side store that could disagree with reality.
    public func restore(repo: URL) -> [Worktree] {
        let registered = Set(((try? list(base: repo)) ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard let config = git.query(in: repo, ["config", "--get-regexp", "^\(MetaKey.prefix)\\."])
        else { return [] }

        // Each line is "orchard.worktree.<uuid>.<field> <value>". git preserves the case of
        // the subsection (the uuid) but lowercases the trailing key, so `baseRef` reads back
        // as `baseref` — field names are matched lowercased to survive that round trip.
        var byID: [String: [String: String]] = [:]
        for line in config.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let keyParts = parts[0].split(separator: ".")
            guard keyParts.count == 4 else { continue }
            byID[String(keyParts[2]), default: [:]][keyParts[3].lowercased()] = String(parts[1])
        }

        var out: [Worktree] = []
        for (idString, fields) in byID {
            guard let path = fields["path"], let branch = fields["branch"] else {
                clearMeta(repo: repo, id: idString)
                continue
            }
            let url = URL(fileURLWithPath: path)
            guard registered.contains(url.standardizedFileURL.path),
                  FileManager.default.fileExists(atPath: path) else {
                // Gone from disk or from git's registry — drop the stale metadata.
                clearMeta(repo: repo, id: idString)
                continue
            }
            let created = fields["createdat"].flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:)) ?? Date()
            out.append(Worktree(id: UUID(uuidString: idString) ?? UUID(),
                                baseRepo: repo, path: url, branch: branch,
                                baseRef: fields["baseref"] ?? "",
                                title: fields["title"] ?? branch,
                                createdAt: created))
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Inspect

    /// Git status of a worktree, measured against the commit it forked from.
    public func status(_ wt: Worktree) -> GitWorktreeStatus {
        service.status(worktree: wt.path, baseRef: wt.baseRef.isEmpty ? "HEAD" : wt.baseRef)
    }

    /// What would be lost by deleting `wt`. Callers show `warnings` before destroying anything.
    public func deletionPreflight(_ wt: Worktree) -> WorktreeDeletionPreflight {
        let status = self.status(wt)
        var warnings: [String] = []
        if status.hasUncommittedChanges {
            let n = max(status.stat.fileCount, 1)
            warnings.append("\(n) uncommitted \(n == 1 ? "file" : "files") will be discarded")
        }
        // An unpushed count of nil means "no upstream at all", so every local commit is at risk.
        let atRisk = status.unpushedCommits ?? status.commitsAhead
        if atRisk > 0 {
            warnings.append("\(atRisk) \(atRisk == 1 ? "commit is" : "commits are") not pushed anywhere")
        }
        let merged = isBranchMerged(wt.branch, in: wt.baseRepo)
        return WorktreeDeletionPreflight(worktree: wt, status: status, warnings: warnings,
                                         branchMerged: merged)
    }

    /// Whether `name` is fully merged the way `git branch -d` would decide: ancestor
    /// of its upstream if one exists, otherwise ancestor of `HEAD` in `repo`.
    public func isBranchMerged(_ name: String, in repo: URL) -> Bool {
        let upstream = git.line(in: repo, ["rev-parse", "--abbrev-ref", "\(name)@{upstream}"])
        let target = (upstream?.isEmpty == false) ? upstream! : "HEAD"
        guard let result = try? git.capture(["-C", repo.path, "merge-base", "--is-ancestor",
                                             name, target]) else { return false }
        return result.status == 0
    }

    /// Run the `orchard.yaml` archive script inside `wt`. Returns nil when the project
    /// declares none. Failures are returned rather than thrown — Orca logs a failed
    /// archive hook and still proceeds with deletion (the hook is best-effort
    /// teardown: stop containers, free ports).
    public func runArchiveHook(for wt: Worktree) -> SetupRunner.Result? {
        guard let script = archiveScript(for: wt) else { return nil }
        return SetupRunner.run(script: script, in: wt.path, environment: hookEnvironment(for: wt))
    }

    // MARK: - Remove

    /// Remove a worktree. By default a dirty worktree is preserved (returns false) so the
    /// user can inspect/merge; pass `force: true` to discard uncommitted work.
    ///
    /// The branch is left behind on purpose — removing a checkout shouldn't destroy commits.
    /// `deleteBranch: true` runs `git branch -d` after a successful removal. Unmerged
    /// branches are refused with git's exact unmerged message unless `forceBranch`
    /// (then `git branch -D`). `--force-branch` implies `--delete-branch`.
    @discardableResult
    public func remove(_ wt: Worktree, force: Bool = false, deleteBranch: Bool = false,
                       forceBranch: Bool = false) throws -> Bool {
        try Self.assertRemovable(wt)
        let dropBranch = deleteBranch || forceBranch
        return try queue.sync {
            if dropBranch && !forceBranch && !isBranchMerged(wt.branch, in: wt.baseRepo) {
                throw BranchDeletionError(
                    branch: wt.branch,
                    message: BranchDeletionError.unmergedMessage(for: wt.branch))
            }
            var args = ["-C", wt.baseRepo.path, "worktree", "remove", wt.path.path]
            if force { args.append("--force") }
            do {
                try git.run(args)
            } catch {
                if !force { return false } // likely dirty; keep it
                throw error
            }
            clearMeta(repo: wt.baseRepo, id: wt.id.uuidString)
            // The worktree directory is gone. If this was the last checkout in the
            // per-repo container (`~/Orchard/worktrees/<repo>/`), drop that empty
            // directory too. Never recursive: a sibling worktree or leftover file
            // leaves the container in place. Runs on the branch-delete throw path
            // as well — the checkout is already gone.
            defer { Self.removeEmptyDirectory(self.root) }
            if dropBranch {
                let flag = forceBranch ? "-D" : "-d"
                do {
                    try git.run(in: wt.baseRepo, ["branch", flag, wt.branch])
                } catch let error as GitError {
                    // Worktree is already gone. Surface git's unmerged text rather than
                    // a wrapped `git … failed` prefix, and keep the branch as recovery.
                    let gitText = Self.unmergedText(from: error.message, branch: wt.branch)
                    throw BranchDeletionError(branch: wt.branch, message: gitText)
                }
            }
            return true
        }
    }

    /// Remove `url` only if it is an empty directory. Never recursive: a
    /// non-empty directory, a file, or a missing path is left alone.
    ///
    /// Used after `worktree rm` of the last extra worktree and on `repo remove`
    /// so `~/Orchard/worktrees/<repo>/` does not sit empty.
    public static func removeEmptyDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard standardized.pathComponents.count >= 3, !path.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        // Same class of refusal as `assertRemovable`: never rmdir `/`, `$HOME`,
        // or a directory that contains `$HOME`.
        if path == "/" || path == home || home.hasPrefix(path + "/") { return }
        _ = path.withCString { rmdir($0) }
    }

    /// Pull git's unmerged first line out of a wrapped `GitError` message.
    private static func unmergedText(from wrapped: String, branch: String) -> String {
        let expected = BranchDeletionError.unmergedMessage(for: branch)
        if let range = wrapped.range(of: expected) {
            return String(wrapped[range])
        }
        if wrapped.contains("not fully merged") { return expected }
        return expected
    }

    /// Whether the branch survived a `remove(deleteBranch: true)` because it still holds
    /// unmerged commits — the UI offers "delete it anyway" from here.
    public func branchExists(_ name: String, in repo: URL) -> Bool {
        git.line(in: repo, ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]) != nil
    }

    /// Discard a branch that safe-delete preserved. Separate from `remove` so throwing away
    /// unmerged commits is always its own deliberate action.
    public func forceDeleteBranch(_ name: String, in repo: URL) throws {
        try git.run(in: repo, ["branch", "-D", name])
    }

    /// Refuse to `git worktree remove` a path that isn't a disposable worktree.
    ///
    /// `git worktree remove --force` recursively deletes the directory it is pointed at, so a
    /// bad path here is unrecoverable data loss rather than a failed command. Metadata could
    /// in principle be stale or hand-edited; these checks depend on the path alone.
    static func assertRemovable(_ wt: Worktree) throws {
        let path = wt.path.standardizedFileURL.path
        let repo = wt.baseRepo.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        if path == "/" || path.isEmpty || wt.path.pathComponents.count <= 2 {
            throw GitError("refusing to remove filesystem root: \(path)")
        }
        if path == repo {
            throw GitError("refusing to remove the repository itself: \(path)")
        }
        if repo.hasPrefix(path + "/") {
            throw GitError("refusing to remove \(path): it contains the repository")
        }
        if path == home {
            throw GitError("refusing to remove the home directory")
        }
        if home.hasPrefix(path + "/") {
            throw GitError("refusing to remove \(path): it contains the home directory")
        }
    }

    /// Ensure `pattern` is in the repo's local `.git/info/exclude` (no commit, no change to
    /// the tracked `.gitignore`) so in-repo worktrees never show up in `git status`.
    public func ensureExcluded(_ pattern: String, in repo: URL) {
        guard let gitDir = git.line(in: repo, ["rev-parse", "--git-dir"]) else { return }
        let infoDir = URL(fileURLWithPath: gitDir, relativeTo: repo).appendingPathComponent("info")
        try? FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
        let excludeFile = infoDir.appendingPathComponent("exclude")
        let existing = (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(pattern) { return }
        let appended = existing.isEmpty ? "\(pattern)\n"
            : (existing.hasSuffix("\n") ? "\(existing)\(pattern)\n" : "\(existing)\n\(pattern)\n")
        try? appended.write(to: excludeFile, atomically: true, encoding: .utf8)
    }

    /// Drop stale worktree administrative entries left by crashes.
    public func prune(base: URL) {
        _ = try? queue.sync { try git.run(["-C", base.path, "worktree", "prune"]) }
    }

    /// List worktree paths currently registered for `base`.
    public func list(base: URL) throws -> [String] {
        let out = try git.run(["-C", base.path, "worktree", "list", "--porcelain"])
        return out.split(separator: "\n").compactMap { line in
            line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)) : nil
        }
    }
}
