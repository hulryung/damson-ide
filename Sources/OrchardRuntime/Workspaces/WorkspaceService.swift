import Foundation
import OrchardCore

/// Workspace & worktree service: git worktrees plus folder workspaces, projected
/// into one `Workspace` shape, with user-authored meta / lineage / name
/// retirement living in `orchard-data.json`.
///
/// Git facts (path, branch, baseRef, instance UUID) stay in v1's git-config
/// persistence via `WorktreeService` / `WorktreeManager`. This type is the
/// join: repo registry + meta + lineage + folder peers + RPC-facing selectors.
@MainActor
public final class WorkspaceService {
    public let store: OrchardDataStore
    public var agentLauncher: (any AgentLaunching)?
    /// Readiness wait for agent-first create / worker-start (Orca default 60s).
    public var readinessTimeout: TimeInterval = workerStartReadinessTimeout
    /// Override the on-disk worktree root (tests). `nil` uses
    /// `WorktreeManager.defaultRoot(for:)` per repo.
    public var worktreesRoot: URL?
    /// T32: how remote git facts are read. Every remote worktree operation goes through
    /// this seam, so tests script `ssh` output instead of needing a host — the same
    /// trick the T29 probe tests use.
    public var hostCommandRunner: HostCommandRunner = ProcessHostCommandRunner()
    /// Ceiling on one remote git command (see `SSHRunner.defaultTimeout`).
    public var remoteCommandTimeout: TimeInterval = SSHRunner.defaultTimeout
    /// T89: the runtime's durable per-host connections. When set, remote git reads
    /// share one multiplexed `ssh` instead of paying a connect, a key exchange and an
    /// authentication each — a `worktree list` on a remote repo is several commands.
    /// nil keeps the historical behaviour (one `ssh` per call), which is what the
    /// scripted-runner tests pin.
    public var remoteConnections: RemoteConnectionPool?

    private var gitServices: [String: WorktreeService] = [:]
    private var repoChangeContinuations: [UUID: AsyncStream<[RepoRecord]>.Continuation] = [:]

    public init(store: OrchardDataStore, agentLauncher: (any AgentLaunching)? = nil,
                worktreesRoot: URL? = nil) {
        self.store = store
        self.agentLauncher = agentLauncher
        self.worktreesRoot = worktreesRoot
    }

    public convenience init(dataURL: URL, agentLauncher: (any AgentLaunching)? = nil,
                            worktreesRoot: URL? = nil) {
        self.init(store: OrchardDataStore(url: dataURL), agentLauncher: agentLauncher,
                  worktreesRoot: worktreesRoot)
    }

    // MARK: - Repos

    public func listRepos() -> [RepoRecord] { store.load().repos }

    public func repo(id: String) -> RepoRecord? {
        store.load().repos.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Lookup by standardized filesystem path.
    public func repo(path: URL) -> RepoRecord? {
        let standardized = path.standardizedFileURL.path
        return store.load().repos.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardized
        }
    }

    /// Live snapshots of the repo registry. Emits the current `listRepos()`
    /// immediately, then again after each successful add or remove. Multi-subscriber.
    public func repoChanges() -> AsyncStream<[RepoRecord]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(listRepos())
            repoChangeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.repoChangeContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Register a repo (or folder) by filesystem path. Idempotent on the same
    /// standardized path: a re-add returns the existing record rather than
    /// minting a second id (worktree ids embed the repo id).
    @discardableResult
    public func addRepo(path: URL, displayName: String? = nil,
                        baseRef: String? = nil,
                        kind: RepoRecord.Kind? = nil) throws -> RepoRecord {
        let standardized = path.standardizedFileURL
        let inferredKind: RepoRecord.Kind
        if let kind {
            inferredKind = kind
        } else {
            inferredKind = isGitRepo(standardized) ? .git : .folder
        }
        if let existing = repo(path: standardized) {
            // Re-add of a pre-T15 record still projects the primary checkout.
            try ensurePrimaryWorkspace(for: existing)
            return existing
        }
        var record = RepoRecord(path: standardized.path, displayName: displayName,
                                kind: inferredKind)
        if inferredKind == .git {
            let manager = WorktreeManager(root: WorktreeManager.defaultRoot(for: standardized))
            record.baseRef = baseRef ?? manager.defaultBaseRef(in: standardized)
        } else if let baseRef {
            record.baseRef = baseRef
        }
        try store.modify { $0.repos.append(record) }
        try ensurePrimaryWorkspace(for: record)
        publishReposChanged()
        return record
    }

    /// Drop a registered repo. Git worktrees on disk are left intact (Close
    /// Project, not delete). Folder rows, meta, lineage, and retired names
    /// owned by this repo id are removed so a later re-add starts clean.
    /// The empty per-repo worktree container (`~/Orchard/worktrees/<repo>/`,
    /// or the test override) is rmdir'd when empty; never recursively.
    @discardableResult
    public func removeRepo(_ selector: String) throws -> RepoRecord {
        let record = try resolveRepo(selector)
        try store.modify { data in
            data.repos.removeAll {
                $0.id.caseInsensitiveCompare(record.id) == .orderedSame
            }
            data.folderWorkspaces.removeAll {
                $0.repoId.caseInsensitiveCompare(record.id) == .orderedSame
            }
            data.retiredWorktreeNamesByRepo = data.retiredWorktreeNamesByRepo.filter {
                $0.key.caseInsensitiveCompare(record.id) != .orderedSame
            }
            data.worktreeMeta = data.worktreeMeta.filter { key, _ in
                !Self.worktreeKey(key, belongsToRepo: record.id)
            }
            data.worktreeLineageById = data.worktreeLineageById.filter { key, _ in
                !Self.worktreeKey(key, belongsToRepo: record.id)
            }
            // Remote worktrees are Orchard's own record of what is on the host. Closing
            // the project drops the record, exactly as it drops folder rows and meta;
            // the worktrees themselves are left alone on the far side.
            data.remoteWorktrees.removeAll {
                $0.repoId.caseInsensitiveCompare(record.id) == .orderedSame
            }
        }
        let cached = gitServices.keys.filter {
            $0.caseInsensitiveCompare(record.id) == .orderedSame
        }
        for key in cached {
            gitServices.removeValue(forKey: key)?.shutdown(removeWorktrees: false)
        }
        WorktreeManager.removeEmptyDirectory(worktreeContainerURL(for: record))
        publishReposChanged()
        return record
    }

    public func resolveRepo(_ selector: String) throws -> RepoRecord {
        let data = store.load()
        let trimmed = Self.stripPrefix(selector, "id:")
        if let exact = data.repos.first(where: {
            $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exact
        }
        if trimmed.hasPrefix("path:") || trimmed.hasPrefix("/") || trimmed.hasPrefix(".") {
            let path = trimmed.hasPrefix("path:") ? String(trimmed.dropFirst(5)) : trimmed
            if let byPath = repo(path: URL(fileURLWithPath: path)) {
                return byPath
            }
        }
        if trimmed.hasPrefix("name:") {
            let name = String(trimmed.dropFirst(5))
            if let byName = data.repos.first(where: {
                $0.displayName.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return byName
            }
        }
        if let byName = data.repos.first(where: {
            $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return byName
        }
        throw WorkspaceError("unknown_repo", "no repo matching '\(selector)'")
    }

    // MARK: - List / show / current

    public func listWorkspaces(repo selector: String? = nil) throws -> [Workspace] {
        let data = store.load()
        let repos: [RepoRecord]
        if let selector {
            repos = [try resolveRepo(selector)]
        } else {
            repos = data.repos
        }
        // Every local git repo's `git worktree list --porcelain` up front, in parallel.
        // Serial-per-repo was half the cost of a listing; the other half was asking git
        // for branch and HEAD one worktree at a time, which this read already answers.
        let facts = gitFactsByRepo(repos)
        var out: [Workspace] = []
        for repo in repos {
            // A remote repo's worktrees are the last-known set, never a live local git
            // read: running `git -C <remote path>` here would either fail or — worse —
            // succeed against a same-named local directory (T32).
            if Self.isRemote(repo) {
                out.append(contentsOf: storedRemoteWorkspaces(for: repo, data: data))
                continue
            }
            switch repo.kind {
            case .git:
                out.append(contentsOf: try gitWorkspaces(for: repo, data: data,
                                                         facts: facts[repo.id] ?? [:]))
            case .folder:
                out.append(contentsOf: folderWorkspaces(for: repo, data: data))
            }
        }
        return out.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// One porcelain read per local git repo, all repos concurrently, keyed by repo id.
    ///
    /// The `WorktreeService` for each repo is resolved first and on the main actor —
    /// that is where a cold repo pays its one-time `start()` — so the parallel part is
    /// purely the `git` spawns, which touch nothing shared.
    private func gitFactsByRepo(_ repos: [RepoRecord]) -> [String: [String: WorktreeGitFacts]] {
        var ids: [String] = []
        var roots: [URL] = []
        for repo in repos where !Self.isRemote(repo) && repo.kind == .git {
            guard let service = try? gitService(for: repo), service.isGitRepository else { continue }
            ids.append(repo.id)
            roots.append(service.baseRepo)
        }
        let read = WorktreeFactsReader.facts(forRepos: roots)
        return Dictionary(uniqueKeysWithValues: zip(ids, read))
    }

    public func show(selector: String, cwd: String? = nil) throws -> Workspace {
        try resolveWorkspace(selector, cwd: cwd)
    }

    /// Longest enclosing managed workspace from `cwd`. A nested worktree wins
    /// over its parent checkout; a folder workspace wins only when no git
    /// worktree is a longer prefix.
    public func current(cwd: String) throws -> Workspace {
        let standardized = URL(fileURLWithPath: cwd).standardizedFileURL.path
        // `cwd` is a path on *this* machine, so only a local workspace can enclose it.
        // A remote worktree whose path happens to read the same (`/Users/x/repo` on both
        // sides) would otherwise capture `active`, and the next verb would run there.
        let matches = try listWorkspaces().filter { ws in
            guard !Self.isRemote(ws) else { return false }
            let root = URL(fileURLWithPath: ws.path).standardizedFileURL.path
            return standardized == root || standardized.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        guard let best = matches.max(by: { $0.path.count < $1.path.count }) else {
            throw WorkspaceError("not_in_worktree",
                                 "no managed workspace encloses \(cwd)")
        }
        return best
    }

    // MARK: - Create

    public func create(_ request: WorkspaceCreateRequest) async throws -> WorkspaceCreateResult {
        let repo = try resolveOrAddRepo(request.repo)
        try validateStatus(request.workspaceStatus)

        // `--no-parent` ⊥ `--base-branch`: parent resolution is skipped entirely
        // when noParent is set, even if cwd / parentWorktree would otherwise infer.
        let parent: (workspace: Workspace, capture: LineageCapture)?
        if request.noParent {
            parent = nil
        } else {
            parent = try resolveCreateParent(request)
        }

        let created: Workspace
        let gitWorktree: Worktree?
        // A remote repo has no local checkout to fork from, so its worktree is created
        // over the connection (T32). There is deliberately no local fallback: creating
        // it here would put the branch on the wrong machine.
        if Self.isRemote(repo) {
            created = try await createRemoteWorktree(repo: repo, request: request)
            gitWorktree = nil
        } else {
            switch repo.kind {
            case .git:
                let pair = try createGitWorktree(repo: repo, request: request)
                created = pair.workspace
                gitWorktree = pair.worktree
            case .folder:
                created = try createFolderWorkspace(repo: repo, request: request)
                gitWorktree = nil
            }
        }

        let lineage = WorktreeLineage(
            worktreeId: created.id,
            worktreeInstanceId: created.instanceId,
            parentWorktreeId: parent?.workspace.id,
            parentWorktreeInstanceId: parent?.workspace.instanceId,
            origin: request.origin,
            capture: parent?.capture ?? LineageCapture(
                source: request.noParent ? .explicitCLIFlag : .manualAction,
                confidence: request.noParent ? .explicit : .inferred),
            createdAt: created.createdAt)
        try store.modify { $0.worktreeLineageById[created.id] = lineage }

        var result = WorkspaceCreateResult(workspace: withLineage(created, lineage),
                                           lineage: lineage)

        if let agent = request.agent, !agent.isEmpty {
            let handle = try await spawnAgent(
                engineID: agent, prompt: request.prompt,
                workspace: result.workspace, gitWorktree: gitWorktree)
            result.agentTerminalHandle = handle
        }
        return result
    }

    /// worker-start-shaped composition: create a worktree (agent-first when
    /// `agent` is set), wait for idle, return `{worktreeId, agentTerminalHandle}`.
    public func startWorker(_ request: WorkspaceCreateRequest) async throws -> WorkerStartResult {
        var req = request
        if req.origin == .cli { req.origin = .orchestration }
        if req.captureSource == nil {
            req.captureSource = .orchestrationContext
        }
        let created = try await create(req)
        return WorkerStartResult(
            worktreeId: created.workspace.id,
            instanceId: created.workspace.instanceId,
            agentTerminalHandle: created.agentTerminalHandle,
            workspace: created.workspace,
            warning: created.warning)
    }

    // MARK: - Set / rm

    public func update(selector: String, cwd: String? = nil,
                       _ request: WorkspaceUpdateRequest) throws -> Workspace {
        var workspace = try resolveWorkspace(selector, cwd: cwd)
        try validateStatus(request.workspaceStatus)

        if request.noParent && request.parentWorktree != nil {
            throw WorkspaceError("invalid_argument",
                                 "Choose either --parent-worktree or --no-parent, not both.")
        }

        switch workspace.kind {
        case .worktree:
            try store.modify { data in
                var meta = data.worktreeMeta[workspace.id] ?? WorktreeMeta(
                    instanceId: workspace.instanceId, displayName: workspace.displayName)
                apply(request, to: &meta)
                data.worktreeMeta[workspace.id] = meta
            }
        case .folder:
            try store.modify { data in
                guard let idx = data.folderWorkspaces.firstIndex(where: { $0.id == workspace.id })
                else { return }
                apply(request, to: &data.folderWorkspaces[idx])
            }
        }

        if request.noParent {
            try store.modify { data in
                if var lineage = data.worktreeLineageById[workspace.id] {
                    lineage.parentWorktreeId = nil
                    lineage.parentWorktreeInstanceId = nil
                    lineage.capture = LineageCapture(source: .explicitCLIFlag, confidence: .explicit)
                    data.worktreeLineageById[workspace.id] = lineage
                }
            }
        } else if let parentSel = request.parentWorktree {
            let parent = try resolveWorkspace(parentSel, cwd: cwd)
            try store.modify { data in
                var lineage = data.worktreeLineageById[workspace.id] ?? WorktreeLineage(
                    worktreeId: workspace.id,
                    worktreeInstanceId: workspace.instanceId,
                    parentWorktreeId: parent.id,
                    parentWorktreeInstanceId: parent.instanceId,
                    origin: .cli,
                    capture: LineageCapture(source: .explicitCLIFlag, confidence: .explicit))
                lineage.parentWorktreeId = parent.id
                lineage.parentWorktreeInstanceId = parent.instanceId
                lineage.capture = LineageCapture(source: .explicitCLIFlag, confidence: .explicit)
                data.worktreeLineageById[workspace.id] = lineage
            }
        }

        workspace = try resolveWorkspace(idSelector(workspace.id), cwd: cwd)
        return workspace
    }

    public func remove(selector: String, cwd: String? = nil,
                       force: Bool = false, runHooks: Bool = false,
                       deleteBranch: Bool = false,
                       forceBranch: Bool = false) throws -> WorkspaceRemoveResult {
        let workspace = try resolveWorkspace(selector, cwd: cwd)
        if isPrimaryCheckout(workspace) {
            throw WorkspaceError("invalid_argument",
                                 "cannot remove the repo primary checkout; close the project instead")
        }
        // Removing a remote worktree needs a bounded round trip (preflight, then the
        // delete), so it cannot happen on this synchronous path. Failing here is
        // deliberate: silently doing nothing would read as a successful delete.
        if Self.isRemote(workspace) {
            throw WorkspaceError("remote_unsupported",
                                 "remote worktrees are removed through removeRemoteWorktree; "
                                     + "this path cannot reach \(workspace.hostId)")
        }
        switch workspace.kind {
        case .folder:
            try store.modify { data in
                data.folderWorkspaces.removeAll { $0.id == workspace.id }
                data.worktreeMeta.removeValue(forKey: workspace.id)
                data.worktreeLineageById.removeValue(forKey: workspace.id)
            }
            return WorkspaceRemoveResult(removed: true, warning: nil, preflightWarnings: [])
        case .worktree:
            let repo = try resolveRepo(workspace.repoId)
            let service = try gitService(for: repo)
            guard let record = service.worktrees.first(where: {
                $0.worktree.id.uuidString.caseInsensitiveCompare(workspace.instanceId) == .orderedSame
            }) else {
                throw WorkspaceError("unknown_worktree", "git worktree vanished: \(workspace.id)")
            }
            let preflight = service.deletionPreflight(record)
            var warnings = preflight.warnings
            warnings.append(preflight.branchStatusMessage)
            let dropBranch = deleteBranch || forceBranch
            // More specific than dirty: --delete-branch on an unmerged branch is
            // refused with git's exact line before anything is removed.
            if dropBranch && !forceBranch && !preflight.branchMerged {
                throw WorkspaceError(
                    "branch_not_merged",
                    BranchDeletionError.unmergedMessage(for: preflight.worktree.branch))
            }
            if !preflight.isSafe && !force {
                return WorkspaceRemoveResult(removed: false,
                                             warning: nil,
                                             preflightWarnings: warnings,
                                             branch: preflight.worktree.branch,
                                             branchMerged: preflight.branchMerged)
            }
            do {
                let deletion = try service.deleteWorktree(record, force: force,
                                                          deleteBranch: dropBranch,
                                                          forceBranch: forceBranch,
                                                          runHooks: runHooks)
                try store.modify { data in
                    data.worktreeMeta.removeValue(forKey: workspace.id)
                    data.worktreeLineageById.removeValue(forKey: workspace.id)
                }
                let branchGone = dropBranch && deletion.removed
                    && !service.branchStillExists(preflight.worktree.branch)
                return WorkspaceRemoveResult(removed: deletion.removed,
                                             warning: deletion.warning,
                                             preflightWarnings: warnings,
                                             branch: preflight.worktree.branch,
                                             branchMerged: preflight.branchMerged,
                                             branchDeleted: dropBranch ? branchGone : false)
            } catch let error as BranchDeletionError {
                throw WorkspaceError("branch_not_merged", error.message)
            }
        }
    }

    /// Add a custom board-column. Defaults cannot be removed; custom ids must
    /// not collide with the four defaults.
    public func addStatusDefinition(_ definition: WorkspaceStatusDefinition) throws {
        guard !WorkspaceStatusDefinition.defaultIDs.contains(definition.id) else {
            throw WorkspaceError("invalid_argument",
                                 "status id '\(definition.id)' is a built-in default")
        }
        try store.modify { data in
            if data.workspaceStatusVocabulary.contains(where: { $0.id == definition.id }) {
                data.workspaceStatusVocabulary.removeAll { $0.id == definition.id }
            }
            data.workspaceStatusVocabulary.append(definition)
        }
    }

    public func statusVocabulary() -> [WorkspaceStatusDefinition] {
        let stored = store.load().workspaceStatusVocabulary
        if stored.isEmpty { return WorkspaceStatusDefinition.defaults }
        var seen = Set<String>()
        var out: [WorkspaceStatusDefinition] = []
        for item in WorkspaceStatusDefinition.defaults + stored {
            if seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }

    // MARK: - Selectors

    public func resolveWorkspace(_ selector: String, cwd: String? = nil) throws -> Workspace {
        let trimmed = selector.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            throw WorkspaceError("invalid_argument", "missing worktree selector")
        }
        if trimmed == "active" || trimmed == "current" {
            guard let cwd else {
                throw WorkspaceError("invalid_argument",
                                     "active/current requires a cwd")
            }
            return try current(cwd: cwd)
        }

        let body = Self.stripPrefix(trimmed, "id:")

        // An `id:<repoId>::<path>` selector already names its repo and its path. Resolving
        // it by enumerating every repo was the single most expensive thing a workspace
        // switch did — the pane needed one workspace and paid for all of them. This
        // answers it from the named repo alone, and falls through to the full listing only
        // when the direct read cannot find it.
        if let identity = WorktreeIdentity.parse(body),
           let direct = try? workspace(identity: identity) {
            return direct
        }

        let all = try listWorkspaces()

        if WorktreeIdentity.parse(body) != nil,
           let exact = all.first(where: { $0.id == body }) {
            return exact
        }

        if trimmed.hasPrefix("name:") {
            return try unique(all.filter {
                $0.displayName.caseInsensitiveCompare(String(trimmed.dropFirst(5))) == .orderedSame
                    || URL(fileURLWithPath: $0.path).lastPathComponent.caseInsensitiveCompare(
                        String(trimmed.dropFirst(5))) == .orderedSame
            }, selector: trimmed)
        }
        if trimmed.hasPrefix("path:") {
            let path = URL(fileURLWithPath: String(trimmed.dropFirst(5))).standardizedFileURL.path
            return try unique(all.filter {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
            }, selector: trimmed)
        }
        if trimmed.hasPrefix("branch:") {
            let branch = String(trimmed.dropFirst(7))
            return try unique(all.filter { $0.branch == branch }, selector: trimmed)
        }
        if trimmed.hasPrefix("issue:") {
            let issue = String(trimmed.dropFirst(6))
            return try unique(all.filter { $0.linkedIssue == issue }, selector: trimmed)
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix(".") {
            let path = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            if let byPath = all.first(where: {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
            }) {
                return byPath
            }
        }

        if let byName = all.first(where: {
            $0.displayName.caseInsensitiveCompare(body) == .orderedSame
                || URL(fileURLWithPath: $0.path).lastPathComponent == body
        }) {
            return byName
        }

        throw WorkspaceError("unknown_worktree", "no worktree matching '\(selector)'")
    }

    /// One workspace, read from the repo its id names — no enumeration of any other repo,
    /// and for a git repo exactly one `git worktree list --porcelain`.
    ///
    /// Throws `unknown_worktree` when the id does not name something this repo holds, so
    /// the caller can fall back to the full listing rather than treating a miss as fatal.
    private func workspace(identity: WorktreeIdentity) throws -> Workspace {
        guard let repo = repo(id: identity.repoId) else {
            throw WorkspaceError("unknown_worktree", "no repo '\(identity.repoId)'")
        }
        let data = store.load()
        let raw = WorktreeIdentity.make(repoId: repo.id, path: identity.path)

        if Self.isRemote(repo) {
            guard let match = storedRemoteWorkspaces(for: repo, data: data).first(where: { $0.id == raw })
            else { throw WorkspaceError("unknown_worktree", "no worktree matching '\(raw)'") }
            return match
        }
        if repo.kind == .folder {
            guard let match = folderWorkspaces(for: repo, data: data).first(where: { $0.id == raw })
            else { throw WorkspaceError("unknown_worktree", "no worktree matching '\(raw)'") }
            return match
        }

        // A folder workspace can also live inside a git repo (the peer projection).
        if let folder = folderWorkspaces(for: repo, data: data).first(where: { $0.id == raw }) {
            return folder
        }

        let service = try gitService(for: repo)
        let facts = WorktreeFactsReader.facts(forRepo: service.baseRepo)
        let wanted = WorktreeFactsReader.key(identity.path)
        if wanted == WorktreeFactsReader.key(repo.path) {
            return try primaryGitWorkspace(for: repo, service: service, data: data, facts: facts)
        }
        guard let record = service.worktrees.first(where: {
            WorktreeFactsReader.key($0.worktree.path) == wanted
        }) else {
            throw WorkspaceError("unknown_worktree", "no worktree matching '\(raw)'")
        }
        return gitWorkspace(record: record, repo: repo, data: data,
                            head: facts[wanted]?.head ?? "")
    }

    // MARK: - Git create

    private func createGitWorktree(repo: RepoRecord, request: WorkspaceCreateRequest)
        throws -> (workspace: Workspace, worktree: Worktree) {
        let service = try gitService(for: repo)
        if let ref = request.baseBranch {
            service.overrideBaseRef(ref)
        }
        let retired = store.load().retiredWorktreeNamesByRepo[repo.id] ?? .empty
        let name: String
        if let given = request.name, WorktreeNaming.isValid(given) {
            name = WorktreeNaming.sanitize(given)
        } else {
            name = service.suggestedName(retired: retired)
        }
        if let runSetup = request.runSetup {
            service.runsSetupScripts = runSetup
        }
        let record = try service.createWorktree(name: name, baseRef: request.baseBranch,
                                                title: request.displayName ?? name)
        if service.runsSetupScripts {
            service.runSetupScriptIfEnabled(for: record)
        }

        let worktreeId = record.worktree.workspaceId(repoId: repo.id)
        var meta = WorktreeMeta.defaults(for: record.worktree)
        meta.displayName = request.displayName ?? name
        meta.comment = request.comment ?? ""
        meta.workspaceStatus = request.workspaceStatus
        meta.linkedIssue = request.linkedIssue
        meta.linkedPR = request.linkedPR
        record.meta = meta

        let leaf = record.path.lastPathComponent.lowercased()
        try store.modify { data in
            data.worktreeMeta[worktreeId] = meta
            // Only generated-pool names are retired. User-typed names like
            // `fix-parser` are not pool members, so a watermark must never cover
            // them; collision suffixes on pool names (`apricot-2`) are retired.
            if RetiredNames.poolNameTier(leaf, pool: WorktreeNaming.suggestedNameSet) != nil {
                let current = data.retiredWorktreeNamesByRepo[repo.id] ?? .empty
                if let next = RetiredNames.adding([leaf], to: current,
                                                  pool: WorktreeNaming.suggestedNames) {
                    data.retiredWorktreeNamesByRepo[repo.id] = next
                }
            }
        }

        let head = service.manager.headCommit(record.worktree)
        let workspace = Workspace.from(worktree: record.worktree, repo: repo,
                                       meta: meta, head: head, lineage: nil)
        return (workspace, record.worktree)
    }

    private func createFolderWorkspace(repo: RepoRecord, request: WorkspaceCreateRequest)
        throws -> Workspace {
        let data = store.load()
        let existing = data.folderWorkspaces.filter { $0.repoId == repo.id }
        let name = request.displayName ?? request.name ?? repo.displayName
        let instanceId = UUID().uuidString
        let id: String
        let folderPath: String
        if existing.isEmpty {
            folderPath = repo.path
            id = WorktreeIdentity.make(repoId: repo.id, path: repo.path)
        } else {
            // Multiple sessions on one folder: `repoId::workspace:<uuid>`.
            folderPath = repo.path
            id = WorktreeIdentity.make(repoId: repo.id, path: "workspace:\(instanceId.lowercased())")
        }
        let record = FolderWorkspaceRecord(
            id: id, repoId: repo.id, instanceId: instanceId,
            folderPath: folderPath, name: name,
            comment: request.comment ?? "",
            workspaceStatus: request.workspaceStatus,
            linkedIssue: request.linkedIssue,
            linkedPR: request.linkedPR)
        try store.modify { $0.folderWorkspaces.append(record) }
        return Workspace.from(folder: record, repo: repo, lineage: nil)
    }

    private func ensurePrimaryFolderWorkspace(for repo: RepoRecord, name: String) throws -> FolderWorkspaceRecord {
        let data = store.load()
        let id = primaryWorkspaceId(for: repo)
        if let existing = data.folderWorkspaces.first(where: { $0.id == id }) {
            return existing
        }
        let record = FolderWorkspaceRecord(id: id, repoId: repo.id,
                                           folderPath: repo.path, name: name)
        try store.modify { $0.folderWorkspaces.append(record) }
        return record
    }

    /// Project the repo root as `repoId::path` so path:/name:/active selectors
    /// resolve it without a runtime-created worktree (Orca's primary checkout).
    private func ensurePrimaryWorkspace(for repo: RepoRecord) throws {
        switch repo.kind {
        case .folder:
            _ = try ensurePrimaryFolderWorkspace(for: repo, name: repo.displayName)
        case .git:
            _ = try ensurePrimaryGitMeta(for: repo, existing: store.load().worktreeMeta)
        }
    }

    @discardableResult
    private func ensurePrimaryGitMeta(for repo: RepoRecord,
                                      existing: [String: WorktreeMeta]) throws -> WorktreeMeta {
        let id = primaryWorkspaceId(for: repo)
        if let meta = existing[id] { return meta }
        let meta = WorktreeMeta(instanceId: UUID().uuidString,
                                displayName: repo.displayName,
                                lastActivityAt: repo.addedAt,
                                createdAt: repo.addedAt)
        try store.modify { $0.worktreeMeta[id] = meta }
        return meta
    }

    private func primaryWorkspaceId(for repo: RepoRecord) -> String {
        WorktreeIdentity.make(
            repoId: repo.id,
            path: URL(fileURLWithPath: repo.path).standardizedFileURL.path)
    }

    private func isPrimaryCheckout(_ workspace: Workspace) -> Bool {
        guard let repo = repo(id: workspace.repoId) else { return false }
        return workspace.id.caseInsensitiveCompare(primaryWorkspaceId(for: repo)) == .orderedSame
    }

    // MARK: - Agent spawn

    private func spawnAgent(engineID: String, prompt: String,
                            workspace: Workspace, gitWorktree: Worktree?) async throws -> String {
        // Stage 3, not this wave: an agent engine's argv, config, hooks and transcript
        // all assume a local filesystem, so launching one "for" a remote workspace would
        // run it on *this* machine under the remote host's name
        // (docs/design/remote-hosts.md §6).
        if Self.isRemote(workspace) {
            throw WorkspaceError("remote_unsupported",
                                 "agents cannot run on \(workspace.hostId) yet; "
                                     + "open a remote shell in the worktree instead")
        }
        guard let launcher = agentLauncher else {
            throw WorkspaceError("agent_unavailable",
                "agent-first create requires an AgentLaunching seam (AgentSupervisor / T3 terminal service)")
        }
        let worktree: Worktree
        if let gitWorktree {
            worktree = gitWorktree
        } else {
            let path = URL(fileURLWithPath: workspace.path)
            worktree = Worktree(
                id: UUID(uuidString: workspace.instanceId) ?? UUID(),
                baseRepo: path, path: path, branch: "",
                baseRef: "", title: workspace.displayName)
        }
        let launched = try await launcher.launch(engineID: engineID, prompt: prompt,
                                                 worktree: worktree,
                                                 title: workspace.displayName,
                                                 worktreeId: workspace.id)
        try await launched.waitUntilReady(readinessTimeout)
        return launched.terminalHandle
    }

    // MARK: - Projection

    private func gitWorkspaces(for repo: RepoRecord, data: OrchardData,
                               facts: [String: WorktreeGitFacts]) throws -> [Workspace] {
        let service = try gitService(for: repo)
        let primary = try primaryGitWorkspace(for: repo, service: service, data: data, facts: facts)
        let primaryPath = URL(fileURLWithPath: primary.path).standardizedFileURL.path
        let extra = service.worktrees.compactMap { record -> Workspace? in
            let path = record.worktree.path.standardizedFileURL.path
            if path == primaryPath { return nil }
            return gitWorkspace(record: record, repo: repo, data: data,
                                head: facts[WorktreeFactsReader.key(record.worktree.path)]?.head ?? "")
        }
        return [primary] + extra
    }

    /// Project one restored worktree. `head` comes from the repo's single porcelain read;
    /// it used to be a `rev-parse HEAD` spawn of its own, per worktree, per listing.
    private func gitWorkspace(record: WorktreeRecord, repo: RepoRecord,
                              data: OrchardData, head: String) -> Workspace {
        let id = record.worktree.workspaceId(repoId: repo.id)
        var meta = data.worktreeMeta[id] ?? .defaults(for: record.worktree)
        // Path reuse: git-config UUID is the instance. Stale meta (different
        // instanceId) is ignored so lineage/display from the previous occupant
        // cannot attach to the new one.
        if meta.instanceId.caseInsensitiveCompare(record.worktree.id.uuidString) != .orderedSame {
            meta = .defaults(for: record.worktree)
        }
        record.meta = meta
        var lineage = data.worktreeLineageById[id]
        if let existing = lineage, existing.isStale(currentInstanceId: record.worktree.id.uuidString) {
            lineage = nil
        }
        return Workspace.from(worktree: record.worktree, repo: repo,
                              meta: meta, head: head, lineage: lineage)
    }

    private func primaryGitWorkspace(for repo: RepoRecord, service: WorktreeService,
                                     data: OrchardData,
                                     facts: [String: WorktreeGitFacts]) throws -> Workspace {
        let meta = try ensurePrimaryGitMeta(for: repo, existing: data.worktreeMeta)
        let path = URL(fileURLWithPath: repo.path).standardizedFileURL.path
        // Branch and head both come from the porcelain read. A detached primary checkout
        // reports an empty branch, which is what `currentBranch` returned for it too.
        let fact = facts[WorktreeFactsReader.key(path)]
        let id = primaryWorkspaceId(for: repo)
        var lineage = data.worktreeLineageById[id]
        if let existing = lineage, existing.isStale(currentInstanceId: meta.instanceId) {
            lineage = nil
        }
        return Workspace.fromPrimaryCheckout(repo: repo, meta: meta,
                                             branch: fact?.branch ?? "", head: fact?.head ?? "",
                                             lineage: lineage)
    }

    private func folderWorkspaces(for repo: RepoRecord, data: OrchardData) -> [Workspace] {
        data.folderWorkspaces
            .filter { $0.repoId == repo.id }
            .map { folder in
                var lineage = data.worktreeLineageById[folder.id]
                if let existing = lineage, existing.isStale(currentInstanceId: folder.instanceId) {
                    lineage = nil
                }
                return Workspace.from(folder: folder, repo: repo, lineage: lineage)
            }
    }

    /// Per-repo container: `~/Orchard/worktrees/<repo>/` in production, or
    /// `worktreesRoot/<repo-id>/` when tests override the root.
    func worktreeContainerURL(for repo: RepoRecord) -> URL {
        if let worktreesRoot {
            return worktreesRoot.appendingPathComponent(repo.id, isDirectory: true)
        }
        return WorktreeManager.defaultRoot(for: URL(fileURLWithPath: repo.path))
    }

    private func gitService(for repo: RepoRecord) throws -> WorktreeService {
        if let existing = gitServices[repo.id] { return existing }
        let url = URL(fileURLWithPath: repo.path)
        let root = worktreeContainerURL(for: repo)
        let service = WorktreeService(baseRepo: url, worktreesRoot: root)
        try service.start()
        if repo.baseRef != "HEAD" {
            service.overrideBaseRef(repo.baseRef)
        }
        gitServices[repo.id] = service
        return service
    }

    private func resolveOrAddRepo(_ selector: String) throws -> RepoRecord {
        if let existing = try? resolveRepo(selector) { return existing }
        let pathBody = Self.stripPrefix(Self.stripPrefix(selector, "id:"), "path:")
        let url = URL(fileURLWithPath: pathBody)
        if FileManager.default.fileExists(atPath: url.path) {
            return try addRepo(path: url)
        }
        throw WorkspaceError("unknown_repo", "no repo matching '\(selector)'")
    }

    private func resolveCreateParent(_ request: WorkspaceCreateRequest)
        throws -> (workspace: Workspace, capture: LineageCapture)? {
        if let explicit = request.parentWorktree {
            let ws = try resolveWorkspace(explicit, cwd: request.cwd)
            return (ws, LineageCapture(source: .explicitCLIFlag, confidence: .explicit))
        }
        if let cwd = request.cwd, let inferred = try? current(cwd: cwd) {
            return (inferred, LineageCapture(source: .cwdContext, confidence: .inferred))
        }
        return nil
    }

    private func validateStatus(_ id: String?) throws {
        guard let id else { return }
        let vocab = statusVocabulary()
        guard vocab.contains(where: { $0.id == id }) else {
            throw WorkspaceError("invalid_argument",
                                 "unknown workspace-status '\(id)'")
        }
    }

    private func apply(_ request: WorkspaceUpdateRequest, to meta: inout WorktreeMeta) {
        if let v = request.displayName { meta.displayName = v }
        if let v = request.comment { meta.comment = v }
        if let v = request.workspaceStatus { meta.workspaceStatus = v }
        // `--link-kind` types the issue slot; the PR slot is already unambiguous.
        if let v = request.linkedIssue {
            meta.setSlot(.issue, to: v.isEmpty ? nil : v, explicitKind: request.linkKind)
        }
        if let v = request.linkedPR { meta.linkedPR = v.isEmpty ? nil : v }
        if let v = request.isPinned { meta.isPinned = v }
        if let v = request.isUnread { meta.isUnread = v }
        if let v = request.isArchived { meta.isArchived = v }
        if let v = request.sortOrder { meta.sortOrder = v }
        meta.lastActivityAt = Date()
    }

    private func apply(_ request: WorkspaceUpdateRequest, to folder: inout FolderWorkspaceRecord) {
        if let v = request.displayName { folder.name = v }
        if let v = request.comment { folder.comment = v }
        if let v = request.workspaceStatus { folder.workspaceStatus = v }
        // Folder workspaces keep the same typed links as worktrees, so `--link-kind`
        // means the same thing on both.
        if request.linkedIssue != nil || request.linkedPR != nil {
            var links = folder.links ?? WorkspaceLinks.typed(issue: folder.linkedIssue,
                                                             pr: folder.linkedPR)
            if let v = request.linkedIssue {
                folder.linkedIssue = v.isEmpty ? nil : v
                links.removeAll { !$0.kind.isPullRequest }
                if let link = WorktreeLinkInference.link(from: v, slot: .issue,
                                                         explicitKind: request.linkKind) {
                    links.append(link)
                }
            }
            if let v = request.linkedPR {
                folder.linkedPR = v.isEmpty ? nil : v
                links.removeAll { $0.kind.isPullRequest }
                if let link = WorktreeLinkInference.link(from: v, slot: .pullRequest) {
                    links.append(link)
                }
            }
            folder.links = links
        }
        if let v = request.isPinned { folder.isPinned = v }
        if let v = request.isUnread { folder.isUnread = v }
        if let v = request.isArchived { folder.isArchived = v }
        if let v = request.sortOrder { folder.sortOrder = v }
        folder.lastActivityAt = Date()
    }

    private func withLineage(_ workspace: Workspace, _ lineage: WorktreeLineage) -> Workspace {
        var next = workspace
        next.lineage = lineage
        next.parentWorktreeId = lineage.parentWorktreeId
        return next
    }

    private func unique(_ matches: [Workspace], selector: String) throws -> Workspace {
        guard let first = matches.first else {
            throw WorkspaceError("unknown_worktree", "no worktree matching '\(selector)'")
        }
        if matches.count > 1 {
            throw WorkspaceError("ambiguous_worktree",
                                 "selector '\(selector)' matched \(matches.count) workspaces")
        }
        return first
    }

    private func idSelector(_ id: String) -> String { "id:\(id)" }

    private func isGitRepo(_ url: URL) -> Bool {
        (try? WorktreeManager(root: url).detectBaseRepo(from: url)) != nil
    }

    /// Republish after a remote repo add — T32's extension cannot reach the private
    /// continuation table from another file.
    func publishRemoteReposChanged() { publishReposChanged() }

    private func publishReposChanged() {
        let snapshot = listRepos()
        for continuation in repoChangeContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private static func worktreeKey(_ key: String, belongsToRepo repoId: String) -> Bool {
        guard let parsed = WorktreeIdentity.parse(key) else { return false }
        return parsed.repoId.caseInsensitiveCompare(repoId) == .orderedSame
    }

    static func stripPrefix(_ raw: String, _ prefix: String) -> String {
        if raw.lowercased().hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
    }
}

public struct WorkspaceError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { message }
}
