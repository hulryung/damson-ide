import Foundation
import OrchardProtocol
import OrchardTerminals

/// RPC verbs: `workspace-ports` (attributed listeners) and `worktree-ps`
/// (agent/shell terminals plus those listeners, per workspace).
public struct PortCommandHandler: CommandHandler, @unchecked Sendable {
    public let verbs = ["workspace-ports", "worktree-ps"]

    private let ports: PortService
    private let workspaces: WorkspaceService
    private let terminals: TerminalService

    public init(ports: PortService, workspaces: WorkspaceService, terminals: TerminalService) {
        self.ports = ports
        self.workspaces = workspaces
        self.terminals = terminals
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let err as WorkspaceError {
            return .failure(id: request.id, error: RPCError(code: err.code, message: err.message))
        } catch {
            return .failure(id: request.id, error: RPCError(
                code: "internal_error", message: String(describing: error)))
        }
    }

    private func dispatch(_ request: RPCRequest) async throws -> JSONValue {
        switch request.method {
        case "workspace-ports":
            return try await workspacePorts(request.params ?? .object([:]))
        case "worktree-ps":
            return try await worktreePs(request.params ?? .object([:]))
        default:
            throw WorkspaceError("unknown_command", "no handler for '\(request.method)'")
        }
    }

    private func workspacePorts(_ params: JSONValue) async throws -> JSONValue {
        var snapshot = ports.snapshot()
        let repo = params.string("repo")
        let worktree = params.string("worktree", "selector", "id")
        if let worktree, !worktree.isEmpty {
            let workspace = try await workspaces.show(selector: worktree, cwd: params.string("cwd"))
            snapshot.ports = snapshot.ports.filter { $0.worktreeId == workspace.id }
        } else if let repo, !repo.isEmpty {
            let record = try await workspaces.resolveRepo(repo)
            snapshot.ports = snapshot.ports.filter {
                $0.repoId.caseInsensitiveCompare(record.id) == .orderedSame
            }
        }
        return try JSONBridge.value(snapshot)
    }

    private func worktreePs(_ params: JSONValue) async throws -> JSONValue {
        let snapshot = ports.snapshot()
        let repo = params.string("repo")
        let listed = try await workspaces.listWorkspaces(repo: repo)
        let summaries = await terminals.list()
        let byWorktree = Dictionary(grouping: summaries) { $0.worktreeId ?? "" }

        var rows: [WorktreeProcessRow] = listed.map { workspace in
            let processes = (byWorktree[workspace.id] ?? []).map { summary in
                WorktreeProcess(
                    handle: summary.handle,
                    kind: summary.agentState == nil ? "shell" : "agent",
                    engine: summary.engine,
                    title: summary.title,
                    connected: summary.connected,
                    agentState: summary.agentState?.rawValue)
            }
            return WorktreeProcessRow(
                worktreeId: workspace.id,
                repoId: workspace.repoId,
                displayName: workspace.displayName.isEmpty ? workspace.path : workspace.displayName,
                path: workspace.path,
                branch: workspace.branch,
                processes: processes,
                ports: snapshot.ports(forWorktreeId: workspace.id))
        }

        let total = rows.count
        var truncated = false
        if let limit = params.field("limit")?.intValue, limit >= 0, rows.count > limit {
            rows = Array(rows.prefix(limit))
            truncated = true
        }

        return try JSONBridge.value(WorktreeProcessSnapshot(
            worktrees: rows, totalCount: total, truncated: truncated,
            scannedAt: snapshot.scannedAt, platform: snapshot.platform))
    }
}
