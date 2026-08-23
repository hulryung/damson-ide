import Foundation
import OrchardCore

/// T32 — remote worktrees (docs/design/remote-hosts.md stage 2).
///
/// The local worktree stack reads git facts off the filesystem it is standing on. A
/// remote repo has none of that here, so every fact is read over a bounded `ssh` run and
/// remembered in `orchard-data.json`. Two consequences shape this whole extension:
///
/// - **A read that cannot reach the host throws rather than returning less.** The stored
///   set is never trimmed by a listing that did not happen; only a host that actually
///   answered can retire a record.
/// - **Nothing here has a local fallback.** A remote repo whose host is unregistered or
///   unparseable fails typed; it never quietly runs git on this machine.
@MainActor
public extension WorkspaceService {
    /// The registered hosts, read from the same `orchard-data.json` this service owns.
    var hosts: HostRegistry { HostRegistry(store: store) }

    /// Whether a repo's checkout lives on another machine.
    nonisolated static func isRemote(_ repo: RepoRecord) -> Bool {
        repo.hostId != ExecutionHostId.local.rawValue
    }

    nonisolated static func isRemote(_ workspace: Workspace) -> Bool {
        workspace.hostId != ExecutionHostId.local.rawValue
    }

    /// Resolve a repo's host to a registered record, or fail typed.
    ///
    /// An id that does not parse is rejected instead of being read as `local` — that
    /// downgrade is precisely how work ends up executed on the wrong machine (design
    /// §1, rule 1). A host that is simply no longer registered is `unknown_host`: the
    /// stored worktrees stay listed and inspectable, but nothing will run on them.
    func remoteHost(for repo: RepoRecord) throws -> HostRecord {
        guard let id = ExecutionHostId(rawValue: repo.hostId) else {
            throw WorkspaceError("invalid_argument",
                                 "repo '\(repo.displayName)' has an unusable execution host "
                                     + "'\(repo.hostId)'")
        }
        guard !id.isLocal else {
            throw WorkspaceError("invalid_argument",
                                 "repo '\(repo.displayName)' is local, not a remote host")
        }
        do {
            return try hosts.require(host: id)
        } catch let error as HostRegistryError {
            throw WorkspaceError(error.code, error.message)
        }
    }

    func remoteService(for repo: RepoRecord) throws -> RemoteWorktreeService {
        RemoteWorktreeService(runner: SSHRunner(host: try remoteHost(for: repo),
                                                runner: hostCommandRunner,
                                                timeout: remoteCommandTimeout))
    }

    // MARK: - Registration

    /// Register a repo that lives on a registered host (`repo add --host ssh:<name>`).
    ///
    /// The remote path is *probed before the record exists*: a registration nobody
    /// checked is a record that lies for the rest of its life, and every later worktree
    /// verb would fail against a directory that was never a repo. A host that does not
    /// answer leaves nothing registered — "we could not look" is not "it is there".
    @discardableResult
    func addRemoteRepo(path: String, host: ExecutionHostId,
                       displayName: String? = nil,
                       baseRef: String? = nil) async throws -> RepoRecord {
        guard !host.isLocal else {
            throw WorkspaceError("invalid_argument",
                                 "--host local registers through the ordinary repo add")
        }
        let record: HostRecord
        do {
            record = try hosts.require(host: host)
        } catch let error as HostRegistryError {
            throw WorkspaceError(error.code, error.message)
        }
        let normalized = try mapRemote { try RemoteWorktreeService.requireAbsolute(path, what: "repo path") }
        if let existing = store.load().repos.first(where: {
            $0.hostId == host.rawValue && $0.path == normalized
        }) {
            return existing
        }
        let service = RemoteWorktreeService(runner: SSHRunner(host: record,
                                                              runner: hostCommandRunner,
                                                              timeout: remoteCommandTimeout))
        try await mapRemote { try await service.probeRepository(path: normalized) }
        let resolvedBase: String
        if let baseRef, !baseRef.isEmpty {
            resolvedBase = baseRef
        } else {
            resolvedBase = try await mapRemote {
                try await service.resolveDefaultBaseRef(repoPath: normalized)
            }
        }
        var repo = RepoRecord(path: normalized, displayName: displayName, kind: .git,
                              hostId: host.rawValue)
        repo.baseRef = resolvedBase
        try store.modify { $0.repos.append(repo) }
        // Seed the worktree set from the host that just answered, so the repo is usable
        // (and its primary checkout addressable) without a second round trip.
        _ = try? await refreshRemoteWorktrees(repo: repo)
        publishRemoteReposChanged()
        return repo
    }

    // MARK: - List

    /// Re-read the host's worktrees and reconcile the stored set.
    ///
    /// Retirement only happens on the strength of an answer: this method throws when the
    /// listing could not be run, leaving every record intact. That is rule 2 applied to
    /// a listing — an empty result from an unreachable host is the classic false
    /// `exited`, and here it would silently delete the record of an agent's work.
    @discardableResult
    func refreshRemoteWorktrees(repo: RepoRecord) async throws -> [RemoteWorktreeRecord] {
        let service = try remoteService(for: repo)
        let listed = try await mapRemote { try await service.list(repoPath: repo.path) }
        let now = Date()
        var updated: [RemoteWorktreeRecord] = []
        try store.modify { data in
            var byId: [String: RemoteWorktreeRecord] = [:]
            for record in data.remoteWorktrees where record.repoId == repo.id {
                byId[record.id] = record
            }
            var next: [RemoteWorktreeRecord] = []
            for worktree in listed {
                let id = RemoteWorktreeRecord.id(repoId: repo.id, path: worktree.path)
                var record = byId[id] ?? RemoteWorktreeRecord(
                    id: id, repoId: repo.id, hostId: repo.hostId, path: worktree.path,
                    createdAt: now)
                record.hostId = repo.hostId
                record.branch = worktree.branch
                record.head = worktree.head
                record.isPrimary = worktree.isPrimary
                // baseRef is Orchard's own fact (the pinned fork point); a listing does
                // not carry it, so a refresh must never blank it.
                if !worktree.baseRef.isEmpty { record.baseRef = worktree.baseRef }
                record.lastSeenAt = now
                next.append(record)
            }
            let survivingIds = Set(next.map(\.id))
            // Meta and lineage for worktrees the host says are gone go with them: the
            // host answered, so this is evidence of absence, not loss of contact.
            for (id, record) in byId where !survivingIds.contains(id) {
                data.worktreeMeta.removeValue(forKey: record.id)
                data.worktreeLineageById.removeValue(forKey: id)
            }
            data.remoteWorktrees.removeAll { $0.repoId == repo.id }
            data.remoteWorktrees.append(contentsOf: next)
            updated = next
        }
        return updated
    }

    /// Stored remote worktrees for a repo, projected into `Workspace`. Purely local —
    /// this is what an unreachable host's workspaces still look like.
    nonisolated func storedRemoteWorkspaces(for repo: RepoRecord, data: OrchardData) -> [Workspace] {
        data.remoteWorktrees
            .filter { $0.repoId.caseInsensitiveCompare(repo.id) == .orderedSame }
            .map { record in
                var meta = data.worktreeMeta[record.id] ?? WorktreeMeta(
                    instanceId: record.instanceId,
                    displayName: record.path.split(separator: "/").last.map(String.init) ?? record.path,
                    lastActivityAt: record.lastSeenAt,
                    createdAt: record.createdAt)
                // Path reuse on the host: a record with a different instance id is a
                // different occupant, so the previous one's display/lineage must not
                // attach to it.
                if meta.instanceId.caseInsensitiveCompare(record.instanceId) != .orderedSame {
                    meta = WorktreeMeta(instanceId: record.instanceId,
                                        displayName: record.path.split(separator: "/").last
                                            .map(String.init) ?? record.path,
                                        lastActivityAt: record.lastSeenAt,
                                        createdAt: record.createdAt)
                }
                var lineage = data.worktreeLineageById[record.id]
                if let existing = lineage, existing.isStale(currentInstanceId: record.instanceId) {
                    lineage = nil
                }
                return Workspace.from(remote: record, repo: repo, meta: meta, lineage: lineage)
            }
            .sorted { $0.path < $1.path }
    }

    /// Refresh from the host, then project. Used where the caller explicitly scoped the
    /// listing to a remote repo — the host-aware scope design §5 rule 4 asks for.
    func listRemoteWorkspaces(repo: RepoRecord) async throws -> [Workspace] {
        _ = try await refreshRemoteWorktrees(repo: repo)
        return storedRemoteWorkspaces(for: repo, data: store.load())
    }

    // MARK: - Create

    /// Create a worktree on the repo's host and project it into the workspace registry.
    func createRemoteWorktree(repo: RepoRecord,
                              request: WorkspaceCreateRequest) async throws -> Workspace {
        let service = try remoteService(for: repo)
        let data = store.load()
        let taken = Set(data.remoteWorktrees
            .filter { $0.repoId == repo.id }
            .compactMap { $0.path.split(separator: "/").last.map(String.init) })
        let retired = data.retiredWorktreeNamesByRepo[repo.id] ?? .empty
        let name: String
        if let given = request.name, WorktreeNaming.isValid(given) {
            name = WorktreeNaming.sanitize(given)
        } else {
            name = WorktreeNaming.suggestName(taken: taken, retired: retired)
        }
        let prefix = WorktreeNaming.branchPrefix(
            gitUserName: await service.gitUserName(repoPath: repo.path))
        let baseRef = request.baseBranch ?? (repo.baseRef.isEmpty ? "HEAD" : repo.baseRef)

        let created = try await mapRemote {
            try await service.create(repoPath: repo.path, name: name,
                                     branchPrefix: prefix, baseRef: baseRef)
        }

        let id = RemoteWorktreeRecord.id(repoId: repo.id, path: created.path)
        let now = Date()
        let record = RemoteWorktreeRecord(
            id: id, repoId: repo.id, hostId: repo.hostId, path: created.path,
            branch: created.branch, baseRef: created.baseRef, head: created.head,
            createdAt: now, lastSeenAt: now)
        var meta = WorktreeMeta(instanceId: record.instanceId,
                                displayName: request.displayName ?? name,
                                lastActivityAt: now, createdAt: now)
        meta.comment = request.comment ?? ""
        meta.workspaceStatus = request.workspaceStatus
        meta.linkedIssue = request.linkedIssue
        meta.linkedPR = request.linkedPR

        let leaf = (created.path.split(separator: "/").last.map(String.init) ?? name).lowercased()
        try store.modify { data in
            data.remoteWorktrees.removeAll { $0.id == id }
            data.remoteWorktrees.append(record)
            data.worktreeMeta[id] = meta
            if RetiredNames.poolNameTier(leaf, pool: WorktreeNaming.suggestedNameSet) != nil {
                let current = data.retiredWorktreeNamesByRepo[repo.id] ?? .empty
                if let next = RetiredNames.adding([leaf], to: current,
                                                  pool: WorktreeNaming.suggestedNames) {
                    data.retiredWorktreeNamesByRepo[repo.id] = next
                }
            }
        }
        return Workspace.from(remote: record, repo: repo, meta: meta, lineage: nil)
    }

    // MARK: - Remove

    /// Delete a remote worktree, refusing on anything the host would not confirm.
    ///
    /// The preflight counts uncommitted and unpushed work *on the host*. If it cannot be
    /// counted the deletion does not happen: guessing "probably clean" here destroys an
    /// agent's only output on a machine nothing local can recover it from.
    func removeRemoteWorktree(_ workspace: Workspace, force: Bool = false,
                              runHooks: Bool = false) async throws -> WorkspaceRemoveResult {
        let repo = try resolveRepo(workspace.repoId)
        guard let record = store.load().remoteWorktrees.first(where: { $0.id == workspace.id })
        else {
            throw WorkspaceError("unknown_worktree", "no remote worktree \(workspace.id)")
        }
        if record.isPrimary {
            throw WorkspaceError("invalid_argument",
                                 "cannot remove the repo primary checkout; close the project instead")
        }
        let service = try remoteService(for: repo)
        let worktree = RemoteWorktree(path: record.path, branch: record.branch,
                                      head: record.head, baseRef: record.baseRef)
        let preflight = try await mapRemote { try await service.deletionPreflight(worktree) }
        if !preflight.isSafe && !force {
            return WorkspaceRemoveResult(removed: false, warning: nil,
                                         preflightWarnings: preflight.warnings)
        }
        let removed = try await mapRemote {
            try await service.remove(repoPath: repo.path, worktree: worktree, force: force)
        }
        guard removed else {
            return WorkspaceRemoveResult(removed: false, warning: nil,
                                         preflightWarnings: preflight.warnings)
        }
        try store.modify { data in
            data.remoteWorktrees.removeAll { $0.id == workspace.id }
            data.worktreeMeta.removeValue(forKey: workspace.id)
            data.worktreeLineageById.removeValue(forKey: workspace.id)
        }
        // `orchard.yaml` hooks run through the local `SetupRunner`; there is no remote
        // hook runner this wave, so a requested hook is reported as skipped rather than
        // silently ignored.
        let warning = runHooks
            ? "archive hooks are not run on remote hosts yet; nothing was executed on \(record.hostId)."
            : nil
        return WorkspaceRemoveResult(removed: true, warning: warning,
                                     preflightWarnings: preflight.warnings)
    }

    // MARK: - Error mapping

    /// Remote failures reach RPC callers as `WorkspaceError`s carrying the remote code
    /// verbatim (`host_unverifiable`, `remote_not_a_repo`, `remote_unsupported`), so the
    /// distinction between "the host said no" and "the host said nothing" survives the
    /// trip to the wire.
    nonisolated func mapRemote<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as RemoteHostError {
            throw WorkspaceError(error.code, error.message)
        }
    }

    nonisolated func mapRemote<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as RemoteHostError {
            throw WorkspaceError(error.code, error.message)
        }
    }
}
