import Foundation
import OrchardCore
import OrchardProtocol

/// `repo list|add|show`, backed by T4's `OrchardDataStore` repo registry (wave-2 seam
/// close: the earlier T2 handler kept a private `{repositories: []}` sidecar that
/// fought T4's `orchard-data.json` schema for the same file). Records are T4's
/// `RepoRecord`, so repo ids here are the ids worktree identities embed.
public struct RepoRegistryHandler: CommandHandler {
    public let verbs = ["repo-list", "repo-add", "repo-show"]
    private let service: WorkspaceService

    public init(service: WorkspaceService) {
        self.service = service
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        let params = request.params?.objectValue ?? [:]
        do {
            switch request.method {
            case "repo-list":
                let repos = await service.listRepos()
                return .success(id: request.id, result: try .object([
                    "repos": JSONBridge.value(repos),
                    "count": .number(Double(repos.count)),
                ]))

            case "repo-add":
                guard let rawPath = params.str("path"), !rawPath.isEmpty else {
                    throw WorkspaceError("invalid_argument", "repo-add requires --path")
                }
                let record = try await service.addRepo(
                    path: URL(fileURLWithPath: rawPath),
                    displayName: params.str("display-name") ?? params.str("displayName"),
                    baseRef: params.str("base-ref") ?? params.str("baseRef"))
                return .success(id: request.id, result: try JSONBridge.value(record))

            case "repo-show":
                guard let selector = params.str("repo") ?? params.str("id") ?? params.str("path") else {
                    throw WorkspaceError("invalid_argument", "repo-show requires --repo <selector>")
                }
                let record = try await service.resolveRepo(selector)
                return .success(id: request.id, result: try JSONBridge.value(record))

            default:
                throw WorkspaceError("unknown_command", request.method)
            }
        } catch let error as WorkspaceError {
            return .failure(id: request.id, error: RPCError(code: error.code, message: error.message))
        } catch {
            return .failure(id: request.id, error: RPCError(
                code: "internal_error", message: String(describing: error)))
        }
    }
}
