import Foundation

/// Headless worktree lifecycle for one repo: create, restore, delete, and setup.
///
/// This is the worktree half of v1's `OrchestratorController`, with the app glue removed:
/// no agent sessions, no task queue, no theme plumbing, no UI callbacks. Consumers observe
/// `events` (an `AsyncStream<OrchardEvent>`) instead of installing closures. The agent
/// half lives in OrchardTerminals' `AgentSupervisor`, so this type — and everything it
/// touches — compiles with zero damson imports.
///
/// The central relationship is unchanged: a **worktree outlives its agent**. Deleting a
/// worktree is always a deliberate, separate act from dismissing the agent that worked in
/// it. That's what makes a finished agent's output reviewable instead of evaporating.
@MainActor
public final class WorktreeService {
    /// Every worktree Orchard manages for this repo, live or dormant. Restored from git on
    /// `start()`, so worktrees created by a previous launch come back.
    public private(set) var worktrees: [WorktreeRecord] = []

    /// Base repo all worktrees fork from, and the ref new worktrees default to.
    public let baseRepo: URL
    public private(set) var baseRef: String = "HEAD"
    /// Branch namespace for agent branches (`<prefix>/<name>`).
    public private(set) var branchPrefix: String = "orchard"
    /// Whether a new worktree runs the project's `orchard.yaml` setup script.
    public var runsSetupScripts = true

    /// The underlying manager, exposed so peer services (the agent supervisor's hook
    /// installer, the runtime's workspace handlers) can reuse repo-level helpers like
    /// `ensureExcluded` without a second git layer.
    public let manager: WorktreeManager

    /// Domain-event feed (single-subscriber; see `OrchardEvent`).
    public let events: AsyncStream<OrchardEvent>
    private let eventSink: AsyncStream<OrchardEvent>.Continuation

    private let worktreesRoot: URL

    public init(baseRepo: URL, worktreesRoot: URL) {
        self.baseRepo = baseRepo
        self.worktreesRoot = worktreesRoot
        self.manager = WorktreeManager(root: worktreesRoot)
        var sink: AsyncStream<OrchardEvent>.Continuation!
        self.events = AsyncStream { sink = $0 }
        self.eventSink = sink
    }

    /// Convenience initializer using the standard out-of-repo worktree root for `repo`.
    public convenience init(baseRepo: URL) {
        self.init(baseRepo: baseRepo, worktreesRoot: WorktreeManager.defaultRoot(for: baseRepo))
    }

    /// Whether the opened directory is actually a git repository.
    ///
    /// A plain folder is still a legitimate thing to open — you get a terminal rooted there
    /// and can run an agent in it — it just can't have worktrees. Refusing to open it at all
    /// would make the product useless for the very common case of "let me poke at this
    /// directory first, I'll init a repo later".
    public private(set) var isGitRepository = true

    /// Why worktree creation is unavailable, or `nil` when it's available.
    public var worktreeUnavailableReason: String? {
        isGitRepository ? nil : "This folder isn't a git repository, so it can't have worktrees."
    }

    // MARK: - Overrides (user preferences)

    /// Replace the detected branch prefix with an explicit one (a user preference).
    public func overrideBranchPrefix(_ prefix: String) {
        let sanitized = WorktreeNaming.sanitize(prefix)
        guard !sanitized.isEmpty else { return }
        branchPrefix = sanitized
    }

    /// Replace the probed default base ref with an explicit one. Ignored when the ref doesn't
    /// resolve in this repo, so a global preference can't break a project that lacks it.
    public func overrideBaseRef(_ ref: String) {
        guard (try? manager.resolveRef(ref, in: baseRepo)) != nil else { return }
        baseRef = ref
    }

    // MARK: - Start / restore

    /// Prepare the project: for a git repo, resolve naming defaults and re-attach worktrees
    /// from previous launches. Call once before creating worktrees.
    public func start() throws {
        // A non-repo is not an error — it's a folder workspace. Everything below this point
        // is git-specific and simply doesn't apply.
        guard (try? manager.detectBaseRepo(from: baseRepo)) != nil else {
            isGitRepository = false
            return
        }
        isGitRepository = true

        try manager.validateReady(baseRepo)
        // If worktrees live inside the repo, hide that dir from the main checkout's
        // `git status` via local exclude (no commit, no change to tracked .gitignore).
        if let rel = relativePathInsideRepo(worktreesRoot) {
            let topComponent = rel.split(separator: "/").first.map(String.init) ?? rel
            manager.ensureExcluded("\(topComponent)/", in: baseRepo)
        }
        manager.prune(base: baseRepo)
        baseRef = manager.defaultBaseRef(in: baseRepo)
        branchPrefix = WorktreeNaming.branchPrefix(gitUserName: manager.gitUserName(in: baseRepo))

        restoreWorktrees()
    }

    /// Rebuild the worktree list from git. Agentless — a restored worktree has no live
    /// session until something starts one in it.
    private func restoreWorktrees() {
        worktrees = manager.restore(repo: baseRepo).map {
            WorktreeRecord(worktree: $0, manager: manager)
        }
        eventSink.yield(.worktreesRestored(count: worktrees.count))
        refreshAllStatuses()
    }

    /// Refresh every worktree's git status (after a create, delete, or agent turn).
    public func refreshAllStatuses() {
        for record in worktrees {
            Task { await record.refresh() }
        }
    }

    /// Relative path of `url` under `baseRepo`, or nil if it's outside the repo.
    private func relativePathInsideRepo(_ url: URL) -> String? {
        let repoPath = baseRepo.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(repoPath + "/") else { return nil }
        return String(target.dropFirst(repoPath.count + 1))
    }

    // MARK: - Naming helpers

    /// Branch/worktree names already in use, so a composer can suggest a free one.
    public var takenNames: Set<String> {
        Set(worktrees.map { $0.path.lastPathComponent })
    }

    public func suggestedName() -> String {
        WorktreeNaming.suggestName(taken: takenNames)
    }

    /// Suggested name that also honors a repo's permanently-retired generated-name pool.
    public func suggestedName(retired: RetiredNameRegistry) -> String {
        WorktreeNaming.suggestName(taken: takenNames, retired: retired)
    }

    public func availableBaseRefs() -> [String] {
        manager.localBranches(in: baseRepo)
    }

    /// Branch currently checked out in the primary checkout, for a project-root row.
    public var currentBranchName: String? {
        isGitRepository ? manager.currentBranch(in: baseRepo) : nil
    }

    /// Working-tree status of the primary checkout, measured against its own HEAD — what the
    /// user has changed by hand, as opposed to what an agent changed in a worktree.
    public func primaryCheckoutStatus() -> GitWorktreeStatus {
        guard isGitRepository else { return .unknown }
        return GitService().status(worktree: baseRepo, baseRef: "HEAD")
    }

    // MARK: - Create

    /// Create a worktree, without starting anything in it.
    @discardableResult
    public func createWorktree(name: String, baseRef ref: String? = nil,
                               title: String? = nil) throws -> WorktreeRecord {
        if let reason = worktreeUnavailableReason { throw GitError(reason) }
        let branch = WorktreeNaming.branchName(prefix: branchPrefix, name: name)
        let wt = try manager.create(base: baseRepo, branch: branch,
                                    from: ref ?? baseRef, title: title ?? name)
        let record = WorktreeRecord(worktree: wt, manager: manager)
        worktrees.append(record)
        eventSink.yield(.worktreeCreated(wt))
        Task { await record.refresh() }
        return record
    }

    // MARK: - Setup

    /// The project's `orchard.yaml` setup command for a worktree, if it declares one.
    public func setupScript(for record: WorktreeRecord) -> String? {
        manager.setupScript(for: record.worktree)
    }

    /// The project's `orchard.yaml` archive command, if it declares one.
    public func archiveScript(for record: WorktreeRecord) -> String? {
        manager.archiveScript(for: record.worktree)
    }

    /// Run the project's `orchard.yaml` setup script in a fresh worktree, honoring the
    /// `runsSetupScripts` toggle.
    ///
    /// This is what makes a worktree usable rather than merely present: without it every
    /// agent's first turn is spent rediscovering `npm install`. It runs asynchronously so a
    /// slow install doesn't block the caller mid-create; progress is surfaced through
    /// `record.setupState` and `setupStateChanged` events.
    public func runSetupScriptIfEnabled(for record: WorktreeRecord) {
        guard runsSetupScripts, let script = manager.setupScript(for: record.worktree) else { return }
        let env = manager.hookEnvironment(for: record.worktree)
        let cwd = record.path
        record.setupState = .running
        eventSink.yield(.setupStateChanged(worktreeID: record.id, state: .running))

        Task.detached(priority: .userInitiated) {
            let result = SetupRunner.run(script: script, in: cwd, environment: env)
            await MainActor.run {
                let state: SetupState = result.succeeded ? .succeeded : .failed(result.output)
                record.setupState = state
                self.eventSink.yield(.setupStateChanged(worktreeID: record.id, state: state))
                if !result.succeeded {
                    self.eventSink.yield(.serviceError(
                        "setup script failed in \(cwd.lastPathComponent): \(result.output)"))
                }
            }
            await record.refresh()
        }
    }

    // MARK: - Delete

    /// What deleting this worktree would destroy. Show it before asking for confirmation.
    public func deletionPreflight(_ record: WorktreeRecord) -> WorktreeDeletionPreflight {
        manager.deletionPreflight(record.worktree)
    }

    /// Outcome of a delete, including the `--run-hooks` warning Orca surfaces when an
    /// archive script exists but wasn't requested. `branchDeleted` is the same flag
    /// `orchard worktree rm --delete-branch` reports, so the app sheet can show the
    /// CLI result rather than guessing.
    public struct DeletionResult: Sendable {
        public let removed: Bool
        /// Archive-hook skip or failure. Empty when there was no archive script, or
        /// it ran successfully.
        public let warning: String?
        public let branch: String
        public let branchMerged: Bool
        public let branchDeleted: Bool
        public init(removed: Bool, warning: String? = nil, branch: String = "",
                    branchMerged: Bool = false, branchDeleted: Bool = false) {
            self.removed = removed
            self.warning = warning
            self.branch = branch
            self.branchMerged = branchMerged
            self.branchDeleted = branchDeleted
        }
    }

    /// Remove a worktree and drop it from the list.
    ///
    /// The caller is responsible for stopping any agent running inside first — git can't
    /// remove a directory a live process is sitting in (in v1 the controller did both; the
    /// agent half now belongs to `AgentSupervisor`).
    ///
    /// Returns `removed: false` when the worktree was dirty and `force` wasn't set, leaving
    /// everything in place; the caller re-asks with `force: true` after showing the
    /// preflight warnings.
    ///
    /// `runHooks` is the `--run-hooks` flag: the `orchard.yaml` archive script runs only
    /// when this is true. A declared-but-skipped script produces a warning rather than
    /// running. A failed archive hook is also a warning — deletion still proceeds
    /// (matching Orca: archive is best-effort teardown).
    @discardableResult
    public func deleteWorktree(_ record: WorktreeRecord, force: Bool = false,
                               deleteBranch: Bool = false,
                               forceBranch: Bool = false,
                               runHooks: Bool = false) throws -> DeletionResult {
        let preflight = deletionPreflight(record)
        let dropBranch = deleteBranch || forceBranch
        var warning: String?
        if let script = manager.archiveScript(for: record.worktree) {
            if runHooks {
                let result = SetupRunner.run(script: script, in: record.path,
                                             environment: manager.hookEnvironment(for: record.worktree))
                if !result.succeeded {
                    warning = "archive hook failed: \(result.output)"
                }
            } else {
                warning = "orchard.yaml archive hook skipped for \(record.path.path); pass --run-hooks to run it."
            }
        }
        let removed = try manager.remove(record.worktree, force: force,
                                         deleteBranch: deleteBranch,
                                         forceBranch: forceBranch)
        let kept = DeletionResult(removed: false, warning: warning,
                                  branch: record.branch, branchMerged: preflight.branchMerged,
                                  branchDeleted: false)
        guard removed else { return kept }
        worktrees.removeAll { $0.id == record.id }
        eventSink.yield(.worktreeRemoved(worktreeID: record.id, branch: record.branch))
        let branchDeleted = dropBranch && !branchStillExists(record.branch)
        return DeletionResult(removed: true, warning: warning,
                              branch: record.branch, branchMerged: preflight.branchMerged,
                              branchDeleted: branchDeleted)
    }

    /// Whether a branch survived a safe delete because it still holds unmerged commits.
    public func branchStillExists(_ name: String) -> Bool {
        manager.branchExists(name, in: baseRepo)
    }

    /// Discard a branch that safe-delete preserved.
    public func forceDeleteBranch(_ name: String) throws {
        try manager.forceDeleteBranch(name, in: baseRepo)
    }

    // MARK: - Shutdown

    /// Tear down (window closed / app quit). Worktrees are left on disk by default so the
    /// next launch restores them.
    public func shutdown(removeWorktrees: Bool = false) {
        if removeWorktrees {
            for record in worktrees {
                _ = try? manager.remove(record.worktree, force: true, deleteBranch: true)
            }
            worktrees.removeAll()
        }
        eventSink.finish()
    }
}
