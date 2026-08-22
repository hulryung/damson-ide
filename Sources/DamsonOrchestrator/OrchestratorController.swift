import Foundation
import Combine
import DamsonTerminal

/// The orchestrator brain for one repo: owns the persistent worktrees, the task queue, and
/// the live agent sessions.
///
/// The central relationship is that a **worktree outlives its agent**. Creating a task
/// creates a worktree and spawns an agent inside it; when that agent finishes or is
/// dismissed, the worktree and its branch remain until the user deletes them deliberately.
/// That's what makes a finished agent's output reviewable instead of evaporating, and it's
/// why `worktrees` — not `agents` — is the list the UI is built around.
@MainActor
public final class OrchestratorController: ObservableObject {
    public let runID = UUID()

    /// Every worktree Orchard manages for this repo, live or dormant. Restored from git on
    /// `start()`, so worktrees created by a previous launch come back.
    @Published public private(set) var worktrees: [WorktreeRecord] = []
    /// Live agent sessions. A subset of `worktrees` have one attached.
    @Published public private(set) var agents: [AgentSession] = []

    public let queue = TaskQueue()
    public var maxConcurrency: Int = 3

    /// Base repo all tasks fork from, and the ref new worktrees default to.
    public let baseRepo: URL
    public private(set) var baseRef: String = "HEAD"
    /// Branch namespace for agent branches (`<prefix>/<name>`).
    public private(set) var branchPrefix: String = "orchard"
    /// Whether a new worktree runs the project's `orchard.yaml` setup script.
    public var runsSetupScripts = true

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

    private let manager: WorktreeManager
    private let worktreesRoot: URL
    /// Loopback server that receives agent lifecycle hooks (Tier-1 turn detection).
    /// One per run; each agent's events route back by its `hookToken`.
    private let hookServer = HookServer()
    /// Template config new agents are built from; per-agent argv/cwd/env are overlaid on a
    /// copy. Mutable so the app can re-theme (see `applyTheme`).
    public var configTemplate: DamsonConfig

    /// App hooks: add/remove the agent's terminal tab, and surface state for the dashboard.
    public var onAgentSpawned: ((AgentSession) -> Void)?
    public var onAgentRetired: ((AgentSession) -> Void)?
    public var onError: ((String) -> Void)?
    /// Fired when an agent reaches a state the user would want to know about while looking
    /// elsewhere (turn finished, blocked on approval).
    public var onAgentNeedsAttention: ((WorktreeRecord, WorktreeDisplayState) -> Void)?

    public init(baseRepo: URL, worktreesRoot: URL, configTemplate: DamsonConfig) {
        self.baseRepo = baseRepo
        self.worktreesRoot = worktreesRoot
        self.manager = WorktreeManager(root: worktreesRoot)
        self.configTemplate = configTemplate
    }

    /// Convenience initializer using the standard out-of-repo worktree root for `repo`.
    public convenience init(baseRepo: URL, configTemplate: DamsonConfig) {
        self.init(baseRepo: baseRepo,
                  worktreesRoot: WorktreeManager.defaultRoot(for: baseRepo),
                  configTemplate: configTemplate)
    }

    /// Whether the opened directory is actually a git repository.
    ///
    /// A plain folder is still a legitimate thing to open — you get a terminal rooted there
    /// and can run an agent in it — it just can't have worktrees. Refusing to open it at all
    /// would make the app useless for the very common case of "let me poke at this directory
    /// first, I'll init a repo later".
    public private(set) var isGitRepository = true

    /// Why worktree creation is unavailable, or `nil` when it's available.
    public var worktreeUnavailableReason: String? {
        isGitRepository ? nil : "This folder isn't a git repository, so it can't have worktrees."
    }

    /// Prepare the project: bring up the hook server, and — for a git repo — resolve naming
    /// defaults and re-attach worktrees from previous launches. Call once before enqueuing.
    public func start() throws {
        // Bring up the hook server (best-effort — agents just fall back to fingerprints
        // if it can't bind). Route each event to its agent by token, on the main actor.
        _ = hookServer.start()
        hookServer.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self,
                      let agent = self.agents.first(where: { $0.hookToken == event.token })
                else { return }
                agent.applyExternalSignal(
                    agent.engine.hookSignal(event: event.event, body: event.body))
            }
        }

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
    /// session until the user starts one in it.
    private func restoreWorktrees() {
        worktrees = manager.restore(repo: baseRepo).map {
            WorktreeRecord(worktree: $0, manager: manager)
        }
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

    // MARK: - Naming helpers for the composer

    /// Branch/worktree names already in use, so the composer can suggest a free one.
    public var takenNames: Set<String> {
        Set(worktrees.map { $0.path.lastPathComponent })
    }

    public func suggestedName() -> String {
        WorktreeNaming.suggestName(taken: takenNames)
    }

    public func availableBaseRefs() -> [String] {
        manager.localBranches(in: baseRepo)
    }

    /// Branch currently checked out in the primary checkout, for the project-root row.
    public var currentBranchName: String? {
        isGitRepository ? manager.currentBranch(in: baseRepo) : nil
    }

    /// Working-tree status of the primary checkout, measured against its own HEAD — what the
    /// user has changed by hand, as opposed to what an agent changed in a worktree.
    public func primaryCheckoutStatus() -> GitWorktreeStatus {
        guard isGitRepository else { return .unknown }
        return GitService().status(worktree: baseRepo, baseRef: "HEAD")
    }

    // MARK: - Enqueue

    public func enqueue(_ task: AgentTask) {
        queue.enqueue(task)
        schedule()
    }

    /// Spawn an interactive agent with NO upfront mission — a fresh session in its own
    /// worktree that the user drives by typing directly (Cmd-T "new session"). The empty
    /// prompt means the controller never auto-delivers anything.
    public func newInteractiveAgent(engineID: String) {
        guard let engine = AgentEngineRegistry.engine(id: engineID) else { return }
        enqueue(AgentTask(title: engine.displayName, prompt: "",
                          engineID: engineID, baseRepoPath: baseRepo.path))
    }

    public func setMaxConcurrency(_ n: Int) {
        maxConcurrency = max(1, n)
        schedule()
    }

    /// Apply a color theme to future agents and live-update existing ones.
    public func applyTheme(_ theme: DamsonTheme) {
        configTemplate.theme = theme
        for agent in agents {
            var cfg = agent.damsonSession.config
            cfg.theme = theme
            agent.damsonSession.updateConfig(cfg)
        }
    }

    /// Apply theme *and* font to future agents and live-update existing ones. Only the
    /// presentation fields are copied across — argv, cwd, and env are per-agent and must
    /// survive a settings change untouched.
    public func applyTerminalConfig(_ config: DamsonConfig) {
        configTemplate.theme = config.theme
        configTemplate.fontSize = config.fontSize
        configTemplate.fontFamily = config.fontFamily
        for agent in agents {
            var cfg = agent.damsonSession.config
            cfg.theme = config.theme
            cfg.fontSize = config.fontSize
            cfg.fontFamily = config.fontFamily
            agent.damsonSession.updateConfig(cfg)
        }
    }

    // MARK: - Scheduling

    /// Number of agents occupying a concurrency slot (non-terminal).
    private var activeAgentCount: Int {
        agents.filter { !$0.state.isTerminal }.count
    }

    private func schedule() {
        while queue.hasPending, activeAgentCount < maxConcurrency {
            guard let task = queue.dequeue() else { break }
            do {
                try spawnAgent(for: task)
            } catch {
                onError?("failed to start task \"\(task.title)\": \(error)")
                queue.finish(task.id, status: .failed)
            }
        }
    }

    private func spawnAgent(for task: AgentTask) throws {
        guard let engine = AgentEngineRegistry.engine(id: task.engineID) else {
            throw GitError("unknown engine: \(task.engineID)")
        }
        if let reason = worktreeUnavailableReason { throw GitError(reason) }
        let leaf = task.branchHint.map(WorktreeNaming.sanitize) ?? task.slug
        let branch = WorktreeNaming.branchName(prefix: branchPrefix, name: leaf)
        let wt = try manager.create(base: baseRepo, branch: branch,
                                    from: task.baseRef ?? baseRef, title: task.title)

        let record = WorktreeRecord(worktree: wt, manager: manager)
        record.lastPrompt = task.prompt.isEmpty ? nil : task.prompt
        worktrees.append(record)

        runSetupScript(for: record)

        let agent = try launchAgent(engine: engine, task: task, in: record)
        record.attach(agent)
        Task { await record.refresh() }
    }

    /// Run the project's `orchard.yaml` setup script in a fresh worktree.
    ///
    /// This is what makes a worktree usable rather than merely present: without it every
    /// agent's first turn is spent rediscovering `npm install`. It runs before the agent
    /// starts so the checkout is ready when the first prompt lands, and asynchronously so a
    /// slow install doesn't freeze the UI mid-create.
    private func runSetupScript(for record: WorktreeRecord) {
        guard runsSetupScripts, let script = manager.setupScript(for: record.worktree) else { return }
        let env = manager.hookEnvironment(for: record.worktree)
        let cwd = record.path
        record.setupState = .running

        Task.detached(priority: .userInitiated) {
            let result = SetupRunner.run(script: script, in: cwd, environment: env)
            await MainActor.run {
                record.setupState = result.succeeded
                    ? .succeeded
                    : .failed(result.output)
                if !result.succeeded {
                    self.onError?("setup script failed in \(cwd.lastPathComponent): \(result.output)")
                }
            }
            await record.refresh()
        }
    }

    /// Start an engine process inside an existing worktree and register the session. Used
    /// both for a brand-new worktree and for restarting an agent in a dormant one.
    @discardableResult
    private func launchAgent(engine: AgentEngine, task: AgentTask,
                             in record: WorktreeRecord) throws -> AgentSession {
        var config = configTemplate
        config.cwd = record.path.path
        config.argv = launchArgv(engine: engine, task: task, worktree: record.path)
        // Let the engine shape the child environment. Without this an agent inherits
        // whatever launched Orchard — including, when Orchard is started from inside another
        // agent's session, that session's markers, which silently change how the child
        // behaves (Claude Code disables transcript saving when it thinks it's a subprocess).
        config.env = engine.env(base: config.env)

        let session = DamsonSession(config: config)
        let agent = AgentSession(engine: engine, session: session,
                                 worktree: record.worktree, task: task)
        agent.onStateChange = { [weak self, weak agent, weak record] state in
            guard let self, let agent, let record else { return }
            self.agentStateChanged(agent, record: record, state: state)
        }

        // Tier-1 hooks: give this agent a per-worktree hook config so its CLI POSTs
        // lifecycle events to our loopback server. Best-effort — a write failure or a
        // CLI without hook support just means we lean on fingerprints for this agent.
        if let events = engine.hookEvents, hookServer.port != 0 {
            manager.ensureExcluded(".claude/settings.local.json", in: record.path)
            HookInstaller.install(worktree: record.path, port: hookServer.port,
                                  token: agent.hookToken, events: events)
        }

        agents.append(agent)
        onAgentSpawned?(agent)
        return agent
    }

    /// Start a fresh agent in an existing worktree — the "this one is done, ask it something
    /// else" path, and how a worktree restored from a previous launch gets an agent again.
    public func startAgent(in record: WorktreeRecord, engineID: String, prompt: String = "") {
        guard let engine = AgentEngineRegistry.engine(id: engineID) else { return }
        if let existing = record.agent {
            retire(existing, keepWorktree: true)
        }
        let task = AgentTask(title: record.title, prompt: prompt,
                             engineID: engineID, baseRepoPath: baseRepo.path)
        do {
            let agent = try launchAgent(engine: engine, task: task, in: record)
            record.attach(agent)
            if !prompt.isEmpty { record.lastPrompt = prompt }
        } catch {
            onError?("failed to start agent in \(record.title): \(error)")
        }
    }

    /// Wrap the engine's argv in a login shell (for PATH) unless it already is one.
    private func launchArgv(engine: AgentEngine, task: AgentTask, worktree: URL) -> [String] {
        let inner = engine.launchArgv(task: task, worktree: worktree)
        if engine.launchesOwnShell { return inner }
        let shell = DamsonConfig.loginShellPath()
        let cmd = "exec " + inner.map(Self.shellQuote).joined(separator: " ")
        return [shell, "-l", "-c", cmd]
    }

    private static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Agent state reactions

    private func agentStateChanged(_ agent: AgentSession, record: WorktreeRecord,
                                   state: AgentRuntimeState) {
        // A single agent's `state` is @Published on the agent, not on us, so mutating it
        // doesn't republish `agents`. Nudge our own observers too, so controller-level
        // aggregates (the dashboard status summary) refresh when any agent changes.
        objectWillChange.send()
        record.objectWillChange.send()

        switch state {
        case .idle:
            // Deliver the task prompt exactly once, on the first idle after spawn. Skip
            // interactive agents (empty prompt). Claude Code returns to idle after every
            // turn, so the once-guard stops the prompt being re-typed on each completion.
            if let task = agent.task,
               !task.prompt.isEmpty,
               agent.engine.promptDelivery == .typeWhenIdle,
               !agent.hasDeliveredInitialPrompt {
                agent.deliverPrompt(task.prompt)
            } else if agent.hasDeliveredInitialPrompt {
                // A turn just completed — the diff changed, and the user may be elsewhere.
                Task { await record.refresh() }
                onAgentNeedsAttention?(record, .agentIdle)
            }
        case .awaitingApproval, .awaitingInput:
            onAgentNeedsAttention?(record, record.displayState)
        case .finished, .errored:
            finalize(agent, record: record, success: state == .finished(0))
        default:
            break
        }
    }

    /// An agent reached a terminal state. The worktree is deliberately left alone: its diff
    /// is the whole point of having run the agent, and deleting it here would destroy the
    /// output at the exact moment it became reviewable.
    private func finalize(_ agent: AgentSession, record: WorktreeRecord, success: Bool) {
        if let task = agent.task {
            queue.finish(task.id, status: success ? .completed : .failed)
        }
        Task { await record.refresh() }
        onAgentNeedsAttention?(record, success ? .done : .failed)
        schedule() // a slot freed up
    }

    // MARK: - Agent teardown

    /// Stop an agent and drop it from the live list. The worktree it ran in is untouched by
    /// default — dismissing an agent is about clearing the session, not discarding the work.
    public func retire(_ agent: AgentSession, keepWorktree: Bool = true) {
        let wasActive = !agent.state.isTerminal
        if wasActive, let task = agent.task {
            queue.finish(task.id, status: .interrupted)
        }
        agent.terminate()
        agents.removeAll { $0.id == agent.id }

        if let record = worktrees.first(where: { $0.agent?.id == agent.id }) {
            record.detachAgent()
            Task { await record.refresh() }
            if !keepWorktree {
                _ = try? deleteWorktree(record, force: true, deleteBranch: true)
            }
        }
        onAgentRetired?(agent)
        if wasActive { schedule() } // a concurrency slot freed up
    }

    // MARK: - Worktree lifecycle

    /// Create a worktree without starting an agent in it, and optionally run the project's
    /// `orchard.yaml` setup script first.
    @discardableResult
    public func createWorktree(name: String, baseRef ref: String? = nil,
                               title: String? = nil) throws -> WorktreeRecord {
        if let reason = worktreeUnavailableReason { throw GitError(reason) }
        let branch = WorktreeNaming.branchName(prefix: branchPrefix, name: name)
        let wt = try manager.create(base: baseRepo, branch: branch,
                                    from: ref ?? baseRef, title: title ?? name)
        let record = WorktreeRecord(worktree: wt, manager: manager)
        worktrees.append(record)
        Task { await record.refresh() }
        return record
    }

    /// What deleting this worktree would destroy. Show it before asking for confirmation.
    public func deletionPreflight(_ record: WorktreeRecord) -> WorktreeDeletionPreflight {
        manager.deletionPreflight(record.worktree)
    }

    /// Remove a worktree and drop it from the list. Its agent, if any, is stopped first —
    /// git can't remove a directory a live process is sitting in.
    ///
    /// Returns `false` when the worktree was dirty and `force` wasn't set, leaving everything
    /// in place; the caller re-asks with `force: true` after showing the preflight warnings.
    @discardableResult
    public func deleteWorktree(_ record: WorktreeRecord, force: Bool = false,
                               deleteBranch: Bool = false) throws -> Bool {
        if let agent = record.agent {
            agent.terminate()
            agents.removeAll { $0.id == agent.id }
            record.detachAgent()
            onAgentRetired?(agent)
        }
        let removed = try manager.remove(record.worktree, force: force, deleteBranch: deleteBranch)
        guard removed else { return false }
        worktrees.removeAll { $0.id == record.id }
        schedule()
        return true
    }

    /// Whether a branch survived a safe delete because it still holds unmerged commits.
    public func branchStillExists(_ name: String) -> Bool {
        manager.branchExists(name, in: baseRepo)
    }

    /// Discard a branch that safe-delete preserved.
    public func forceDeleteBranch(_ name: String) throws {
        try manager.forceDeleteBranch(name, in: baseRepo)
    }

    /// The project's `orchard.yaml` setup command for a worktree, if it declares one.
    public func setupScript(for record: WorktreeRecord) -> String? {
        manager.setupScript(for: record.worktree)
    }

    /// Tear down everything (window closed / app quit). Agents are stopped; worktrees are
    /// left on disk so the next launch restores them.
    public func shutdown(removeWorktrees: Bool = false) {
        for agent in agents {
            if let task = agent.task, !agent.state.isTerminal {
                queue.finish(task.id, status: .interrupted)
            }
            agent.terminate()
            onAgentRetired?(agent)
        }
        agents.removeAll()
        if removeWorktrees {
            for record in worktrees {
                _ = try? manager.remove(record.worktree, force: true, deleteBranch: true)
            }
            worktrees.removeAll()
        } else {
            for record in worktrees { record.detachAgent() }
        }
        hookServer.stop()
    }
}
