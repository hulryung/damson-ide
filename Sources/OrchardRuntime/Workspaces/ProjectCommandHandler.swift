import Foundation
import OrchardCore
import OrchardProtocol

/// RPC verbs for `project list|show|current`.
///
/// A project is a registered repo (the sidebar grouping). This handler is the
/// grouping view; `RepoRegistryHandler` still owns add/remove.
public final class ProjectCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = ["project-list", "project-show", "project-current"]

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
        } catch {
            return .failure(id: request.id, error: RPCError(code: "internal_error",
                                                           message: String(describing: error)))
        }
    }

    private func dispatch(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params ?? .object([:])
        switch request.method {
        case "project-list":
            return try await list()
        case "project-show":
            return try await show(params)
        case "project-current":
            return try await current(params)
        default:
            throw WorkspaceError("unknown_command", "no handler for '\(request.method)'")
        }
    }

    private func list() async throws -> JSONValue {
        let repos = await service.listRepos()
        var projects: [ProjectRow] = []
        projects.reserveCapacity(repos.count)
        for repo in repos {
            let workspaces = try await service.listWorkspaces(repo: repo.id)
            projects.append(ProjectRow(repo: repo, worktreeCount: workspaces.count))
        }
        return try JSONBridge.value(ListResult(projects: projects, count: projects.count))
    }

    private func show(_ params: JSONValue) async throws -> JSONValue {
        guard let selector = params.string("project", "repo", "id", "selector"),
              !selector.isEmpty else {
            throw WorkspaceError("invalid_argument", "project-show requires --project <selector>")
        }
        let repo = try await service.resolveRepo(selector)
        return try await showRepo(repo)
    }

    private func current(_ params: JSONValue) async throws -> JSONValue {
        guard let cwd = params.string("cwd"), !cwd.isEmpty else {
            throw WorkspaceError("invalid_argument", "project-current requires cwd")
        }
        let workspace = try await service.current(cwd: cwd)
        let repo = try await service.resolveRepo(workspace.repoId)
        return try await showRepo(repo)
    }

    private func showRepo(_ repo: RepoRecord) async throws -> JSONValue {
        let workspaces = try await service.listWorkspaces(repo: repo.id)
        return try JSONBridge.value(ShowResult(
            project: ProjectRow(repo: repo, worktreeCount: workspaces.count),
            worktrees: workspaces))
    }
}

private struct ProjectRow: Encodable {
    var id: String
    var displayName: String
    var path: String
    var hostId: String
    var kind: String
    var baseRef: String
    var worktreeCount: Int

    init(repo: RepoRecord, worktreeCount: Int) {
        id = repo.id
        displayName = repo.displayName
        path = repo.path
        hostId = repo.hostId
        kind = repo.kind.rawValue
        baseRef = repo.baseRef
        self.worktreeCount = worktreeCount
    }
}

private struct ListResult: Encodable {
    var projects: [ProjectRow]
    var count: Int
}

private struct ShowResult: Encodable {
    var project: ProjectRow
    var worktrees: [Workspace]
}
