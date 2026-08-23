import Foundation
import OrchardCore

/// A git worktree that lives on a remote host.
///
/// Deliberately not a `Worktree`: the local type carries `URL`s, and a `URL` for a path
/// on another machine is a lie that `FileManager` will happily act on. Remote paths stay
/// strings that only ever travel back over the connection they came from.
public struct RemoteWorktree: Equatable, Sendable {
    public let path: String
    public let branch: String
    public let head: String
    /// Commit the worktree forked from, when Orchard created it and knows.
    public let baseRef: String
    /// True for the repo's own checkout (the first `git worktree list` entry).
    public let isPrimary: Bool

    public init(path: String, branch: String, head: String,
                baseRef: String = "", isPrimary: Bool = false) {
        self.path = path
        self.branch = branch
        self.head = head
        self.baseRef = baseRef
        self.isPrimary = isPrimary
    }
}

/// What deleting a remote worktree would destroy, counted *on the host that owns it*.
///
/// The counts are only meaningful because they came back through a working connection.
/// There is no "assume clean" path: a preflight that cannot reach the host throws
/// `host_unverifiable` and the deletion does not happen.
public struct RemoteDeletionPreflight: Equatable, Sendable {
    public let worktree: RemoteWorktree
    public let uncommittedFiles: Int
    /// Commits not on the branch's upstream, or — with no upstream — commits not on the
    /// fork point, because then every local commit is at risk.
    public let unpushedCommits: Int
    public let hasUpstream: Bool
    public let warnings: [String]

    public var isSafe: Bool { warnings.isEmpty }
}

/// Git worktree operations against a repo on a remote host, run through `SSHRunner`.
///
/// This is the stage-2 half of docs/design/remote-hosts.md: the same worktree lifecycle
/// as the local `WorktreeManager`, with every git fact read over the connection instead
/// of off the local filesystem. Two rules shape every method here:
///
/// 1. **Loss of contact is not an answer.** Nothing degrades to "no worktrees", "not
///    dirty", or "already gone" when the host does not reply — those all throw
///    `host_unverifiable` instead. An empty result from an unreachable host is the
///    classic false `exited`.
/// 2. **Nothing runs locally as a fallback.** There is no local path in this type at
///    all, which is the only way to be sure a remote operation cannot quietly execute
///    on this machine.
public struct RemoteWorktreeService: Sendable {
    public let runner: SSHRunner
    public var host: HostRecord { runner.host }
    public var hostName: String { runner.hostName }

    public init(runner: SSHRunner) {
        self.runner = runner
    }

    public init(host: HostRecord, runner: HostCommandRunner = ProcessHostCommandRunner(),
                timeout: TimeInterval = SSHRunner.defaultTimeout) {
        self.init(runner: SSHRunner(host: host, runner: runner, timeout: timeout))
    }

    // MARK: - Registration probe

    /// Confirm `path` is a git checkout on the far side before a repo record claims it
    /// is (`test -d <path>/.git`).
    ///
    /// Registering a path nobody checked is how a repo record becomes a permanent lie:
    /// every later worktree verb would fail with a git error against a directory that
    /// was never a repo. A host that does not answer is `unverifiable` — the record is
    /// *not* created, because "we could not look" is not "it is there".
    public func probeRepository(path: String) async throws {
        let path = try Self.requireAbsolute(path, what: "repo path")
        let outcome = await runner.run(
            SSHRunner.commandLine(["test", "-d", path + "/.git"]))
        switch outcome {
        case .unverifiable(let reason):
            throw RemoteHostError.unverifiable(host: hostName,
                                               doing: "checking \(path)", reason: reason)
        case .answered(let code, _, _):
            guard code == 0 else {
                throw RemoteHostError("remote_not_a_repo",
                                      "\(path) on \(hostName) is not a git checkout "
                                          + "(no .git directory)")
            }
        }
    }

    // MARK: - Worktree base

    /// Where worktrees for `repoPath` are created on the host:
    /// `<remote $HOME>/Orchard/worktrees/<repo-name>`.
    ///
    /// Same shape as `WorktreeManager.defaultRoot` and for the same reason — outside the
    /// checkout, so file watchers, test globs and language servers on the far side do
    /// not each scan N copies of the project. `$HOME` is asked for rather than assumed:
    /// `/home/<user>` is wrong on macOS hosts, and a guessed base is a guessed
    /// `rm -rf` target.
    public func resolveWorktreeBase(repoPath: String) async throws -> String {
        let repoPath = try Self.requireAbsolute(repoPath, what: "repo path")
        let home = try runner.line(await runner.run("printf %s \"$HOME\""),
                                   doing: "resolving the home directory")
        guard let home, home.hasPrefix("/") else {
            throw RemoteHostError.remoteGitFailed(
                "\(hostName) did not report a usable home directory")
        }
        let leaf = Self.repoLeafName(repoPath)
        return "\(home)/Orchard/worktrees/\(leaf)"
    }

    // MARK: - List

    /// Every worktree git knows about for `repoPath`, read over the connection.
    ///
    /// git lists the repo's own worktree first, so that entry is the primary checkout —
    /// read *before* filtering, so a bare repo cannot promote the next entry into a
    /// primary it is not (and a delete then refuse the wrong row). Bare and prunable
    /// entries are dropped because they are not places work can happen.
    public func list(repoPath: String) async throws -> [RemoteWorktree] {
        let repoPath = try Self.requireAbsolute(repoPath, what: "repo path")
        let output = try await runner.requireGit(["worktree", "list", "--porcelain"],
                                                 in: repoPath,
                                                 doing: "listing worktrees")
        let all = WorktreePorcelain.parse(output)
        let primaryPath = all.first?.path
        return all
            .filter { !$0.isBare && !$0.isPrunable }
            .map { entry in
                RemoteWorktree(path: entry.path, branch: entry.branch, head: entry.head,
                               isPrimary: entry.path == primaryPath)
            }
    }

    // MARK: - Create

    /// Create a worktree on the host, on a new branch forked from a pinned commit.
    ///
    /// The pin and `--no-track` are not stylistic: resolving `ref` to a SHA first stops
    /// the change set shifting under a reviewer when the base branch moves, and without
    /// `--no-track` git reports the fresh worktree as "behind by N" before the agent has
    /// done anything. Both match `WorktreeManager.create` exactly, so a remote worktree
    /// reads the same as a local one in every later diff.
    public func create(repoPath: String, name: String, branchPrefix: String,
                       baseRef: String) async throws -> RemoteWorktree {
        let repoPath = try Self.requireAbsolute(repoPath, what: "repo path")
        let leaf = WorktreeNaming.sanitize(name)
        guard !leaf.isEmpty else {
            throw RemoteHostError.invalidArgument("'\(name)' is not a usable worktree name")
        }
        let base = try await resolveWorktreeBase(repoPath: repoPath)

        // Pin the fork point before anything is created: `baseRef` may be a branch that
        // moves between now and when the diff is read.
        let sha = try runner.line(await runner.git(["rev-parse", baseRef], in: repoPath),
                                  doing: "resolving \(baseRef)")
        guard let sha, !sha.isEmpty else {
            throw RemoteHostError.remoteGitFailed(
                "\(hostName) could not resolve '\(baseRef)' in \(repoPath)")
        }

        let takenBranches = Set(try await runner.requireGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            in: repoPath, doing: "listing branches")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let branch = Self.uniqueName(WorktreeNaming.branchName(prefix: branchPrefix, name: leaf),
                                     taken: takenBranches)

        // One round trip creates the base and reports what is already in it, so the
        // directory uniquifier does not need a probe per candidate.
        let listing = try runner.require(
            await runner.run("mkdir -p \(SSHCommand.shellQuote(base)) && ls -1a \(SSHCommand.shellQuote(base))"),
            doing: "preparing the worktree directory")
        let takenDirs = Set(listing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let directoryLeaf = Self.uniqueName(branch.split(separator: "/").last.map(String.init) ?? branch,
                                            taken: takenDirs)
        let directory = "\(base)/\(directoryLeaf)"
        // The computed path must land strictly inside the base we just resolved — a name
        // that escaped it would put a worktree, and later a recursive delete, somewhere
        // nobody intended.
        try Self.assertInside(directory, base: base)

        try await runner.requireGit(
            ["worktree", "add", "--no-track", "-b", branch, directory, sha],
            in: repoPath, doing: "creating worktree \(directoryLeaf)")

        // Best-effort, exactly as locally: record the fork point where git itself can
        // see it, so `git config branch.<b>.base` answers outside Orchard too. A failure
        // here does not undo a worktree that already exists.
        _ = await runner.git(["config", "--local", "--replace-all",
                              "branch.\(branch).base", baseRef], in: repoPath)

        return RemoteWorktree(path: directory, branch: branch, head: sha, baseRef: sha)
    }

    // MARK: - Delete

    /// What deleting `worktree` would destroy, counted on the host.
    ///
    /// Every count comes from a command that answered. If any of them cannot be run the
    /// whole preflight throws rather than reporting a smaller number — "we could not
    /// check" must never render as "nothing to lose".
    public func deletionPreflight(_ worktree: RemoteWorktree) async throws -> RemoteDeletionPreflight {
        let path = try Self.requireAbsolute(worktree.path, what: "worktree path")
        let status = try await runner.requireGit(["status", "--porcelain"], in: path,
                                                 doing: "reading worktree status")
        let uncommitted = status.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count

        // No upstream is an ordinary answer, not a failure: git exits nonzero and the
        // meaning is "every commit here is unpushed".
        let upstreamOutcome = await runner.git(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: path)
        if case .unverifiable(let reason) = upstreamOutcome {
            throw RemoteHostError.unverifiable(host: hostName,
                                               doing: "checking \(path) for unpushed work",
                                               reason: reason)
        }
        let upstream = upstreamOutcome.successOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUpstream = (upstream?.isEmpty == false)
        // With no upstream at all, every commit since the fork point is at risk — the
        // same substitution `WorktreeManager.deletionPreflight` makes locally.
        var unpushed = 0
        if hasUpstream || !worktree.baseRef.isEmpty {
            let comparison = hasUpstream ? upstream! : worktree.baseRef
            let counted = try await runner.requireGit(
                ["rev-list", "--count", "\(comparison)..HEAD"], in: path,
                doing: "counting unpushed commits")
            unpushed = Int(counted.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        var warnings: [String] = []
        if uncommitted > 0 {
            warnings.append("\(uncommitted) uncommitted "
                + "\(uncommitted == 1 ? "file" : "files") on \(hostName) will be discarded")
        }
        if unpushed > 0 {
            warnings.append("\(unpushed) \(unpushed == 1 ? "commit is" : "commits are") "
                + "not pushed anywhere")
        }
        return RemoteDeletionPreflight(worktree: worktree, uncommittedFiles: uncommitted,
                                       unpushedCommits: unpushed,
                                       hasUpstream: hasUpstream,
                                       warnings: warnings)
    }

    /// Remove a worktree on the host. Returns false when git refused because the
    /// worktree was dirty and `force` was not set — the caller re-asks after showing the
    /// preflight, exactly like the local path.
    ///
    /// `git worktree remove --force` recursively deletes the directory it is pointed at,
    /// and here it does so on a machine whose filesystem nothing local can inspect
    /// afterwards. So the target is confirmed twice before the command is built: the
    /// path-alone guards below (which hold even if the stored record was hand-edited),
    /// and a listing from the host itself proving this path is a non-primary worktree
    /// *of this repo*. A listing that cannot be run refuses the delete rather than
    /// letting an unconfirmed path through.
    @discardableResult
    public func remove(repoPath: String, worktree: RemoteWorktree, force: Bool) async throws -> Bool {
        let repoPath = try Self.requireAbsolute(repoPath, what: "repo path")
        let path = try Self.requireAbsolute(worktree.path, what: "worktree path")
        try Self.assertRemovable(path: path, repoPath: repoPath)
        let registered = try await list(repoPath: repoPath)
        guard let entry = registered.first(where: { $0.path == path }) else {
            throw RemoteHostError.remoteGitFailed(
                "\(path) is not a registered worktree of \(repoPath) on \(hostName)")
        }
        guard !entry.isPrimary else {
            throw RemoteHostError.invalidArgument(
                "refusing to remove the repository's own checkout: \(path)")
        }

        var args = ["worktree", "remove", path]
        if force { args.append("--force") }
        let outcome = await runner.git(args, in: repoPath)
        switch outcome {
        case .unverifiable(let reason):
            throw RemoteHostError.unverifiable(host: hostName,
                                               doing: "removing \(path)", reason: reason)
        case .answered(let code, _, let stderr):
            if code == 0 { return true }
            // Not forced: a refusal is almost always "it is dirty", and the local path
            // answers that by keeping the worktree and letting the caller decide.
            if !force { return false }
            throw RemoteHostError.remoteGitFailed(
                "removing \(path) on \(hostName) failed: "
                    + (SSHRunner.firstLine(stderr) ?? "git exited \(code)"))
        }
    }

    // MARK: - Repo facts

    /// The branch a new remote worktree should fork from when the caller does not pick
    /// one, probed in the same order as `WorktreeManager.defaultBaseRef`.
    ///
    /// Probed rather than assumed for the same two reasons as locally: forking from
    /// whatever happens to be checked out silently inherits half-finished work, and
    /// hardcoding `main` breaks every repo still on `master`. One `for-each-ref` asks
    /// about all four candidates in a single round trip.
    public func resolveDefaultBaseRef(repoPath: String) async throws -> String {
        let repoPath = try Self.requireAbsolute(repoPath, what: "repo path")
        let candidates = ["refs/remotes/origin/main", "refs/remotes/origin/master",
                          "refs/heads/main", "refs/heads/master"]
        let names = ["origin/main", "origin/master", "main", "master"]
        let present = Set(try await runner.requireGit(
            ["for-each-ref", "--format=%(refname)"] + candidates,
            in: repoPath, doing: "probing default branches")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        for (ref, name) in zip(candidates, names) where present.contains(ref) {
            return name
        }
        let current = try runner.line(
            await runner.git(["rev-parse", "--abbrev-ref", "HEAD"], in: repoPath),
            doing: "reading the current branch")
        return (current == nil || current == "HEAD") ? "HEAD" : current!
    }

    /// The host's `user.name`, so remote agent branches are namespaced the way a team
    /// already reads branch ownership. Best-effort: an unset name is ordinary, and the
    /// caller falls back to the `orchard` prefix.
    public func gitUserName(repoPath: String) async -> String? {
        guard let path = try? Self.requireAbsolute(repoPath, what: "repo path"),
              let name = await runner.git(["config", "user.name"], in: path)
                  .successOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }

    // MARK: - Path safety

    /// Refuse anything that is not an absolute remote path. A relative path would be
    /// resolved against whatever directory the login shell happens to start in.
    static func requireAbsolute(_ path: String, what: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw RemoteHostError.invalidArgument("\(what) must be absolute (got '\(path)')")
        }
        guard !trimmed.contains("\0") else {
            throw RemoteHostError.invalidArgument("\(what) contains a NUL byte")
        }
        // `..` would let a computed path climb back out of the base it was checked
        // against, which is the whole point of checking.
        guard !trimmed.split(separator: "/").contains("..") else {
            throw RemoteHostError.invalidArgument("\(what) must not contain '..' (got '\(path)')")
        }
        return trimmed.count > 1 && trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    /// The remote mirror of `WorktreeManager.assertRemovable`: these checks depend on
    /// the path alone, because stored metadata could be stale or hand-edited and a bad
    /// path here is unrecoverable data loss on a machine we cannot inspect.
    static func assertRemovable(path: String, repoPath: String) throws {
        if path == "/" || path.split(separator: "/").count <= 1 {
            throw RemoteHostError.invalidArgument("refusing to remove '\(path)' on a remote host")
        }
        if path == repoPath {
            throw RemoteHostError.invalidArgument(
                "refusing to remove the repository itself: \(path)")
        }
        if repoPath.hasPrefix(path + "/") {
            throw RemoteHostError.invalidArgument(
                "refusing to remove \(path): it contains the repository")
        }
    }

    static func assertInside(_ path: String, base: String) throws {
        let base = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard path.hasPrefix(base + "/"), path != base else {
            throw RemoteHostError.invalidArgument(
                "refusing to touch \(path): it is outside the worktree base \(base)")
        }
    }

    /// `~/dev/orchard` → `orchard`; `.git` suffixes dropped like the local root helper.
    static func repoLeafName(_ path: String) -> String {
        let leaf = path.split(separator: "/").last.map(String.init) ?? ""
        let name = leaf.hasSuffix(".git") ? String(leaf.dropLast(4)) : leaf
        let sanitized = WorktreeNaming.sanitize(name)
        return sanitized.isEmpty ? "repo" : sanitized
    }

    /// Append `-2`, `-3`… until the name is free, the same uniquifier local worktrees
    /// use — readable names are how a user identifies work in `git branch` and in a
    /// shell prompt, so they are worth keeping over UUID salting.
    static func uniqueName(_ desired: String, taken: Set<String>) -> String {
        guard taken.contains(desired) else { return desired }
        var n = 2
        while taken.contains("\(desired)-\(n)") { n += 1 }
        return "\(desired)-\(n)"
    }
}
