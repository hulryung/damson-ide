import Foundation
import OrchardCore

/// The two git facts a checks reading needs: which branch, and which commit.
///
/// A seam rather than a direct `GitRunner` call so tests need no repository, and
/// so this stays outside `GitFactsCache` entirely — T88 does not touch the facts
/// cache, and the two readings here (`symbolic-ref`, `rev-parse`) are read-only
/// verbs, so they cannot invalidate anyone else's cached facts either.
public struct ChecksGitFacts: Equatable, Sendable {
    /// nil = detached HEAD.
    public var branch: String?
    /// nil = not a git worktree (or an unborn branch with no commit yet).
    public var headSha: String?
    public var isRepository: Bool

    public init(branch: String?, headSha: String?, isRepository: Bool) {
        self.branch = branch
        self.headSha = headSha
        self.isRepository = isRepository
    }
}

public typealias ChecksGitFactsReader = @Sendable (URL) -> ChecksGitFacts

/// One cached reading, with the two things that make it honest: the commit it was
/// taken against, and when.
struct ChecksCacheEntry {
    var snapshot: ChecksSnapshot
    var headSha: String?
    /// Part of the key, not decoration. Two branches can sit on the same commit,
    /// and detaching HEAD keeps the commit while removing the branch entirely —
    /// in both cases the PR the reading describes changed even though the sha did
    /// not. Found by detaching HEAD in a live worktree and watching the previous
    /// branch's answer come back.
    var branch: String?
    var takenAt: Date
}

/// Reads a workspace's pull request and its checks through `gh`, and caches the
/// answer with an invalidation rule that cannot lie.
///
/// Freshness has exactly two conditions, both necessary:
///
/// 1. **Same commit.** The entry is keyed by the worktree's HEAD sha. A commit,
///    an amend, a rebase, a push of a new head — any of them moves HEAD, the key
///    misses, and the old reading is dropped rather than redrawn against a commit
///    it never described.
/// 2. **Inside the TTL.** Checks change while the commit does not — that is what
///    CI *is* — so a same-commit entry still expires. Past the TTL the entry is
///    not served as current: `cached()` returns nil and the caller re-reads.
///
/// What is never done: serving a stale entry as if it were fresh. Callers that
/// want to show something while a re-read is in flight ask for `lastKnown()`,
/// which is explicitly named and comes with `observedAt` so the UI can (and does)
/// label its age.
public actor ChecksService {
    /// How long a same-commit reading stays current. CI moves in tens of seconds,
    /// and every reading is a network round trip, so this is the balance point
    /// between a stale panel and a machine that spends its life running `gh`.
    public static let defaultTTL: TimeInterval = 45
    /// A `gh` that has not answered in this long is reported as timed out. Long
    /// enough for a slow API call, short enough that a wedged network does not
    /// leave a panel spinning.
    public static let defaultTimeout: TimeInterval = 20
    /// Default tail size for a fetched job log.
    public static let defaultLogLines = 2000

    private let probe: any GitHubCLIProbe
    private let gitFacts: ChecksGitFactsReader
    private let ttl: TimeInterval
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: ChecksCacheEntry] = [:]
    /// In-flight reads by cache key, so five surfaces asking at once cost one `gh`.
    private var inFlight: [String: Task<ChecksSnapshot, Never>] = [:]

    public init(probe: any GitHubCLIProbe = SystemGitHubCLI(),
                gitFacts: @escaping ChecksGitFactsReader = ChecksService.liveGitFacts,
                ttl: TimeInterval = ChecksService.ttlFromEnvironment(),
                timeout: TimeInterval = ChecksService.defaultTimeout,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.probe = probe
        self.gitFacts = gitFacts
        self.ttl = ttl
        self.timeout = timeout
        self.now = now
    }

    public static func ttlFromEnvironment() -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["ORCHARD_CHECKS_TTL_SECONDS"],
              let value = TimeInterval(raw), value > 0 else { return defaultTTL }
        return min(max(value, 2), 3600)
    }

    /// Live reader. Both verbs are in `GitRunner.readOnlyVerbs`, so asking costs
    /// two cheap processes and invalidates nothing.
    public static let liveGitFacts: ChecksGitFactsReader = { root in
        let runner = GitRunner.shared
        guard runner.line(in: root, ["rev-parse", "--is-inside-work-tree"]) == "true" else {
            return ChecksGitFacts(branch: nil, headSha: nil, isRepository: false)
        }
        let branch = runner.line(in: root, ["symbolic-ref", "--short", "-q", "HEAD"])
        let head = runner.line(in: root, ["rev-parse", "HEAD"])
        return ChecksGitFacts(branch: branch, headSha: head, isRepository: true)
    }

    // MARK: - Cache

    static func cacheKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The reading for this workspace **if it is current**: same commit, inside the
    /// TTL. Nil otherwise — a stale entry is never handed back through this door.
    public func cached(path: String, headSha: String?, branch: String?) -> ChecksSnapshot? {
        guard let entry = cache[Self.cacheKey(path)] else { return nil }
        guard entry.headSha == headSha, entry.branch == branch else { return nil }
        guard now().timeIntervalSince(entry.takenAt) <= ttl else { return nil }
        return entry.snapshot
    }

    /// The last reading taken for this workspace, whatever its age, *labelled* with
    /// the commit and time it was taken at. For a UI that wants to keep showing
    /// something while a refresh runs — never for deciding anything.
    public func lastKnown(path: String) -> ChecksSnapshot? {
        cache[Self.cacheKey(path)]?.snapshot
    }

    public func invalidate(path: String) {
        cache[Self.cacheKey(path)] = nil
    }

    public func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Reading

    /// Read this workspace's checks, using the cache unless `refresh` is set.
    ///
    /// `hostId` is the workspace's stamped execution host: a remote workspace is
    /// refused typed rather than answered from this machine's git and this
    /// machine's `gh`, which would describe an entirely different checkout.
    public func snapshot(worktreeId: String, path: String, hostId: String = "local",
                         kind: Workspace.Kind = .worktree,
                         refresh: Bool = false) async -> ChecksSnapshot {
        let key = Self.cacheKey(path)
        if hostId != "local" {
            return ChecksSnapshot(
                worktreeId: worktreeId, worktreePath: path, branch: nil, headSha: nil,
                observedAt: now(),
                unavailable: ChecksUnavailability(.remoteWorkspace,
                    detail: "This workspace's files live on \(hostId)."))
        }
        if kind == .folder {
            return ChecksSnapshot(
                worktreeId: worktreeId, worktreePath: path, branch: nil, headSha: nil,
                observedAt: now(),
                unavailable: ChecksUnavailability(.notAGitWorkspace,
                    detail: "\(path) is a folder workspace, not a git worktree."))
        }

        // The two git reads happen off this actor: they are synchronous processes,
        // and holding the actor across them would make every other workspace's
        // checks query queue behind one `rev-parse`.
        let reader = gitFacts
        let root = URL(fileURLWithPath: path)
        let facts = await Task.detached(priority: .utility) { reader(root) }.value
        if !refresh, let hit = cached(path: path, headSha: facts.headSha,
                                      branch: facts.branch) { return hit }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<ChecksSnapshot, Never> { [weak self] in
            guard let self else {
                return ChecksSnapshot(worktreeId: worktreeId, worktreePath: path,
                                      branch: nil, headSha: nil,
                                      unavailable: ChecksUnavailability(.apiError,
                                          detail: "checks service went away"))
            }
            return await self.read(worktreeId: worktreeId, path: path, facts: facts)
        }
        inFlight[key] = task
        let snapshot = await task.value
        inFlight[key] = nil
        cache[key] = ChecksCacheEntry(snapshot: snapshot, headSha: facts.headSha,
                                      branch: facts.branch, takenAt: now())
        return snapshot
    }

    private func read(worktreeId: String, path: String,
                      facts: ChecksGitFacts) async -> ChecksSnapshot {
        func unavailable(_ value: ChecksUnavailability) -> ChecksSnapshot {
            ChecksSnapshot(worktreeId: worktreeId, worktreePath: path,
                           branch: facts.branch, headSha: facts.headSha,
                           observedAt: now(), unavailable: value)
        }

        guard facts.isRepository else {
            return unavailable(ChecksUnavailability(.notAWorktree,
                detail: "\(path) is not inside a git work tree."))
        }
        // `gh` is asked for before it is run: "is it installed" must not depend on
        // a network call, and must be true for a Dock-launched app whose PATH has
        // no /opt/homebrew/bin.
        guard probe.resolvedExecutable() != nil else {
            return unavailable(ChecksUnavailability(.ghNotInstalled,
                detail: "No gh binary on this machine's PATH or in the usual install locations."))
        }
        guard let branch = facts.branch else {
            return unavailable(ChecksUnavailability(.detachedHead,
                detail: "HEAD is detached at \(facts.headSha?.prefix(8) ?? "an unknown commit")."))
        }

        // `gh pr view [<branch>]` — naming the branch makes the lookup explicit and
        // makes gh's own "no pull requests found for branch X" name the right branch.
        // The one exception: an all-digits branch name would be read as a PR number,
        // so that case falls back to gh's own current-branch resolution in `cwd`.
        var arguments = ["pr", "view"]
        if !branch.allSatisfy(\.isNumber) { arguments.append(branch) }
        arguments += ["--json", Self.prFields]
        let outcome = await probe.run(arguments,
                                      cwd: URL(fileURLWithPath: path), timeout: timeout)
        switch GitHubChecksParser.parsePullRequest(outcome) {
        case .failure(let reason):
            return unavailable(reason)
        case .success(let (pr, checks)):
            return ChecksSnapshot(worktreeId: worktreeId, worktreePath: path,
                                  branch: branch, headSha: facts.headSha,
                                  observedAt: now(),
                                  pullRequest: pr, checks: checks)
        }
    }

    /// One `gh pr view` answers both halves — the PR and its whole check rollup —
    /// so the common path costs exactly one subprocess.
    static let prFields = "number,title,url,state,isDraft,headRefName,headRefOid,statusCheckRollup"

    // MARK: - One check's log

    /// Fetch one check's job log. Never cached: a log is what the user asked to see
    /// right now, and a running job's log changes under it.
    public func log(worktreeId: String, path: String, check: CheckRunSummary,
                    limit: Int = ChecksService.defaultLogLines) async -> CheckLogResult {
        guard probe.resolvedExecutable() != nil else {
            return CheckLogResult(worktreeId: worktreeId, check: check, reason: .apiError,
                                  detail: "gh is not installed on this machine.",
                                  observedAt: now())
        }
        guard let jobId = check.jobId else {
            return CheckLogResult(
                worktreeId: worktreeId, check: check, reason: .notAnActionsJob,
                detail: check.detailsUrl.map { "This check reports at \($0)." }
                    ?? "This check published no details URL.",
                observedAt: now())
        }
        // A job that has not completed has no log to serve; asking anyway and
        // reading gh's refusal is how we distinguish "not ready" from "expired".
        let outcome = await probe.run(["run", "view", "--job", jobId, "--log"],
                                      cwd: URL(fileURLWithPath: path), timeout: timeout)
        guard outcome.status == 0, !outcome.stdout.isEmpty else {
            if outcome.status == 0, check.bucketValue == .pending {
                return CheckLogResult(worktreeId: worktreeId, check: check,
                                      reason: .logPending,
                                      detail: "gh returned an empty log for a job that is still running.",
                                      observedAt: now())
            }
            let (reason, detail) = GitHubChecksParser.logUnavailability(from: outcome)
            return CheckLogResult(worktreeId: worktreeId, check: check, reason: reason,
                                  detail: detail, observedAt: now())
        }
        let tail = GitHubChecksParser.tail(outcome.stdout, limit: limit)
        return CheckLogResult(worktreeId: worktreeId, check: check, log: tail.text,
                              truncated: tail.truncated, totalLines: tail.total,
                              returnedLines: tail.returned, observedAt: now())
    }
}
