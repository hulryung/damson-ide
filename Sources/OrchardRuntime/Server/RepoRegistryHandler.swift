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
                let displayName = params.str("display-name") ?? params.str("displayName")
                let baseRef = params.str("base-ref") ?? params.str("baseRef")
                // T32: `--host ssh:<name>` registers a checkout on a registered host.
                // The path is probed over a bounded ssh run *before* the record exists,
                // and an unparseable host id is rejected rather than read as local —
                // that downgrade is how work ends up on the wrong machine.
                if let host = try Self.executionHost(params) {
                    let record = try await service.addRemoteRepo(
                        path: rawPath, host: host, displayName: displayName, baseRef: baseRef)
                    return .success(id: request.id, result: try JSONBridge.value(record))
                }
                let record = try await service.addRepo(
                    path: URL(fileURLWithPath: rawPath),
                    displayName: displayName,
                    baseRef: baseRef)
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
        } catch let error as RemoteHostError {
            return .failure(id: request.id, error: RPCError(code: error.code, message: error.message))
        } catch {
            return .failure(id: request.id, error: RPCError(
                code: "internal_error", message: String(describing: error)))
        }
    }

    /// `--host`, or nil for the ordinary local add. `local` is accepted and means the
    /// same thing as omitting it; anything that does not parse is a typed refusal.
    static func executionHost(_ params: [String: JSONValue]) throws -> ExecutionHostId? {
        guard let raw = params.str("host")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        guard let host = ExecutionHostId(rawValue: raw) else {
            throw WorkspaceError("invalid_argument",
                                 "--host must be 'local' or 'ssh:<name>' (got '\(raw)')")
        }
        return host.isLocal ? nil : host
    }
}
