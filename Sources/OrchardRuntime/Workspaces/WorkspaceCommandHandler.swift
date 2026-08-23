import Foundation
import OrchardCore
import OrchardProtocol

/// RPC verbs for worktree list|show|current|create|set|rm.
///
/// Method names are hyphenated (`worktree-list`) to match the T0 envelope
/// example; T2's CLI can map `worktree list` onto the same verbs.
public final class WorkspaceCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = [
        "worktree-list", "worktree-show", "worktree-current",
        "worktree-create", "worktree-set", "worktree-rm",
    ]

    private let service: WorkspaceService

    public init(service: WorkspaceService) {
        self.service = service
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let err as WorkspaceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as AgentLaunchError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch let err as GitError {
            return .failure(id: request.id, error: RPCError(code: "git_error", message: err.message))
        } catch {
            return .failure(id: request.id, error: RPCError(code: "internal_error",
                                                           message: String(describing: error)))
        }
    }

    private func dispatch(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params ?? .object([:])
        switch request.method {
        case "worktree-list":
            return try await list(params)
        case "worktree-show":
            return try await show(params)
        case "worktree-current":
            return try await current(params)
        case "worktree-create":
            return try await create(params)
        case "worktree-set":
            return try await set(params)
        case "worktree-rm":
            return try await rm(params)
        default:
            throw WorkspaceError("unknown_command", "no handler for '\(request.method)'")
        }
    }

    private func list(_ params: JSONValue) async throws -> JSONValue {
        let repo = params.string("repo")
        let warning = await refreshRemoteScope(repo)
        let workspaces = try await service.listWorkspaces(repo: repo)
        let limited = applyLimit(workspaces, params: params)
        return try JSONBridge.value(ListResult(worktrees: limited.items,
                                               totalCount: limited.total,
                                               truncated: limited.truncated,
                                               warning: warning))
    }

    /// Re-read a remote repo's worktrees when the caller scoped the listing to one.
    ///
    /// Host-aware scope, per docs/design/remote-hosts.md §5 rule 4: an unscoped
    /// `worktree list` does not go probing every registered host. When the host cannot
    /// be reached the listing still returns — the last-known set, plus a warning saying
    /// so — because degrading to read-only inspection is right and reporting an empty
    /// list is the classic false `exited`.
    private func refreshRemoteScope(_ selector: String?) async -> String? {
        guard let selector,
              let repo = try? await service.resolveRepo(selector),
              WorkspaceService.isRemote(repo)
        else { return nil }
        do {
            _ = try await service.refreshRemoteWorktrees(repo: repo)
            return nil
        } catch let error as WorkspaceError {
            return "\(repo.hostId): \(error.message) Showing the last known worktrees."
        } catch {
            return "\(repo.hostId): \(error). Showing the last known worktrees."
        }
    }

    private func show(_ params: JSONValue) async throws -> JSONValue {
        let selector = try requiredSelector(params)
        let cwd = params.string("cwd")
        let workspace = try await service.show(selector: selector, cwd: cwd)
        return try JSONBridge.value(ShowResult(worktree: workspace))
    }

    private func current(_ params: JSONValue) async throws -> JSONValue {
        guard let cwd = params.string("cwd"), !cwd.isEmpty else {
            throw WorkspaceError("invalid_argument",
                                 "worktree-current requires cwd")
        }
        let workspace = try await service.current(cwd: cwd)
        return try JSONBridge.value(ShowResult(worktree: workspace))
    }

    private func create(_ params: JSONValue) async throws -> JSONValue {
        guard let repo = params.string("repo"), !repo.isEmpty else {
            throw WorkspaceError("invalid_argument", "missing repo selector")
        }
        let request = WorkspaceCreateRequest(
            repo: repo,
            name: params.string("name"),
            displayName: params.string("displayName", "display-name"),
            baseBranch: params.string("baseBranch", "base-branch"),
            comment: params.string("comment"),
            linkedIssue: params.string("linkedIssue", "issue"),
            linkedPR: params.string("linkedPR", "pr"),
            workspaceStatus: params.string("workspaceStatus", "workspace-status"),
            parentWorktree: params.string("parentWorktree", "parent-worktree"),
            noParent: params.bool("noParent", "no-parent") ?? false,
            origin: LineageOrigin(rawValue: params.string("origin") ?? "") ?? .cli,
            cwd: params.string("cwd"),
            agent: params.string("agent", "startupAgent"),
            prompt: params.string("prompt", "startupPrompt") ?? "",
            runSetup: params.bool("runHooks", "run-hooks"))
        let created = try await service.create(request)
        return try JSONBridge.value(CreateResult(
            worktree: created.workspace,
            lineage: created.lineage,
            agentTerminalHandle: created.agentTerminalHandle,
            warning: created.warning))
    }

    private func set(_ params: JSONValue) async throws -> JSONValue {
        let selector = try requiredSelector(params)
        let update = WorkspaceUpdateRequest(
            displayName: params.string("displayName", "display-name"),
            comment: params.string("comment"),
            workspaceStatus: params.string("workspaceStatus", "workspace-status"),
            linkedIssue: params.string("linkedIssue", "issue"),
            linkedPR: params.string("linkedPR", "pr"),
            isPinned: params.bool("isPinned", "pinned"),
            isUnread: params.bool("isUnread", "unread"),
            isArchived: params.bool("isArchived", "archived"),
            sortOrder: params.int("sortOrder", "sort-order"),
            parentWorktree: params.string("parentWorktree", "parent-worktree"),
            noParent: params.bool("noParent", "no-parent") ?? false)
        let workspace = try await service.update(selector: selector,
                                                 cwd: params.string("cwd"),
                                                 update)
        return try JSONBridge.value(ShowResult(worktree: workspace))
    }

    private func rm(_ params: JSONValue) async throws -> JSONValue {
        let selector = try requiredSelector(params)
        let cwd = params.string("cwd")
        let force = params.bool("force") ?? false
        let runHooks = params.bool("runHooks", "run-hooks") ?? false
        let workspace = try await service.show(selector: selector, cwd: cwd)
        // A remote delete needs its preflight counted on the host first, so it takes
        // the async remote path. Failing to reach the host refuses the delete rather
        // than guessing the worktree was clean (T32).
        let result: WorkspaceRemoveResult
        if WorkspaceService.isRemote(workspace) {
            result = try await service.removeRemoteWorktree(workspace, force: force,
                                                            runHooks: runHooks)
        } else {
            result = try await service.remove(
                selector: selector, cwd: cwd, force: force, runHooks: runHooks)
        }
        if !result.removed && !result.preflightWarnings.isEmpty {
            throw WorkspaceError(
                "worktree_dirty",
                result.preflightWarnings.joined(separator: "; "))
        }
        return try JSONBridge.value(RemoveResult(removed: result.removed,
                                                 warning: result.warning))
    }

    private func requiredSelector(_ params: JSONValue) throws -> String {
        if let s = params.string("worktree", "selector", "id"), !s.isEmpty { return s }
        throw WorkspaceError("invalid_argument", "missing worktree selector")
    }

    private func applyLimit(_ items: [Workspace], params: JSONValue)
        -> (items: [Workspace], total: Int, truncated: Bool) {
        let total = items.count
        if let limit = params.int("limit"), limit >= 0 {
            let sliced = Array(items.prefix(limit))
            return (sliced, total, sliced.count < total)
        }
        return (items, total, false)
    }
}

private struct ListResult: Encodable {
    var worktrees: [Workspace]
    var totalCount: Int
    var truncated: Bool
    /// Set when a remote repo's host could not be re-read: the rows are the last known
    /// set, not a fresh answer.
    var warning: String?
}

private struct ShowResult: Encodable {
    var worktree: Workspace
}

private struct CreateResult: Encodable {
    var worktree: Workspace
    var lineage: WorktreeLineage?
    var agentTerminalHandle: String?
    var warning: String?
}

private struct RemoveResult: Encodable {
    var removed: Bool
    var warning: String?
}

private extension JSONValue {
    func int(_ keys: String...) -> Int? {
        guard let obj = objectValue else { return nil }
        for key in keys {
            if let n = obj[key]?.intValue { return n }
        }
        return nil
    }
}
