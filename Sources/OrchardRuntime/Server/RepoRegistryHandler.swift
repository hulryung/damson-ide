import Foundation
import OrchardCore
import OrchardProtocol

/// `repo list|add|show|remove`, backed by T4's `OrchardDataStore` repo registry (wave-2 seam
/// close: the earlier T2 handler kept a private `{repositories: []}` sidecar that
/// fought T4's `orchard-data.json` schema for the same file). Records are T4's
/// `RepoRecord`, so repo ids here are the ids worktree identities embed.
///
/// T79: `repo remove --forget` is the registry-only unregister for a *remote*
/// repo. It drops the repo row and the local rows projecting its remote
/// worktrees and never talks to the host. A local repo refuses
/// (`forget_local_refused`) rather than silently dropping worktrees on this
/// machine. There is no `repo forget` subverb.
public struct RepoRegistryHandler: CommandHandler {
    public let verbs = ["repo-list", "repo-add", "repo-show", "repo-remove"]
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

            case "repo-remove":
                // v1 has no --force: extra worktrees or automations that still
                // name this repo are a typed refusal, not a cascade delete.
                // `--forget` is not --force. It is the remote-only way to drop
                // Orchard's view without `worktree rm` on the far side.
                guard let selector = params.str("repo") ?? params.str("id") ?? params.str("path") else {
                    throw WorkspaceError("invalid_argument", "repo-remove requires --repo <selector>")
                }
                let forget = params.flag("forget")
                let record = try await service.resolveRepo(selector)
                if forget, !WorkspaceService.isRemote(record) {
                    return .failure(id: request.id, error: Self.forgetLocalError(for: record))
                }
                let extras = try await extraWorktrees(for: record)
                if let refusal = try await referencingError(
                    for: record, extraWorktrees: forget ? [] : extras)
                {
                    return .failure(id: request.id, error: refusal)
                }
                let removed = try await service.removeRepo(record.id, origin: .cli)
                var object = try JSONBridge.value(removed).objectValue ?? [:]
                object["removed"] = .bool(true)
                if forget {
                    object["forgotten"] = .bool(true)
                    object["hostUntouched"] = .bool(true)
                    object["droppedWorktrees"] = .array(extras.map { ws in
                        .object([
                            "id": .string(ws.id),
                            "displayName": .string(ws.displayName),
                            "path": .string(ws.path),
                        ])
                    })
                }
                return .success(id: request.id, result: .object(object))

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

    /// Extra worktrees that `repo remove` treats as in-use. The primary
    /// checkout is the repo itself and does not block.
    private func extraWorktrees(for repo: RepoRecord) async throws -> [Workspace] {
        let workspaces = try await service.listWorkspaces(repo: repo.id)
        let primaryId = WorktreeIdentity.make(
            repoId: repo.id,
            path: URL(fileURLWithPath: repo.path).standardizedFileURL.path)
        return workspaces.filter {
            $0.id.caseInsensitiveCompare(primaryId) != .orderedSame
        }
    }

    static func forgetLocalError(for repo: RepoRecord) -> RPCError {
        RPCError(
            code: "forget_local_refused",
            message: "cannot forget local repo '\(repo.displayName)': --forget drops the registry "
                + "view of a remote checkout without touching the host. A local repo's worktrees "
                + "live on this machine; remove extra worktrees first, then repo remove.",
            data: .object([
                "repoId": .string(repo.id),
                "hostId": .string(repo.hostId),
            ]))
    }

    /// Extra worktrees (git, folder sessions, remote records) and automations
    /// that target the repo or one of its workspaces block ordinary remove.
    /// `--forget` already filtered extra remote projections out of `worktrees`.
    private func referencingError(for repo: RepoRecord,
                                  extraWorktrees worktrees: [Workspace]) async throws -> RPCError? {
        let automations = await referencingAutomations(for: repo)
        guard !worktrees.isEmpty || !automations.isEmpty else { return nil }

        var named: [String] = []
        if !worktrees.isEmpty {
            named.append("worktrees: " + worktrees.map { "'\($0.displayName)'" }.joined(separator: ", "))
        }
        if !automations.isEmpty {
            named.append("automations: " + automations.map { "'\($0.name)'" }.joined(separator: ", "))
        }
        let message = "cannot remove repo '\(repo.displayName)': still referenced by "
            + named.joined(separator: "; ")
            + ". Remove those first; --force is not accepted."
        let data = JSONValue.object([
            "repoId": .string(repo.id),
            "worktrees": .array(worktrees.map { ws in
                .object([
                    "id": .string(ws.id),
                    "displayName": .string(ws.displayName),
                ])
            }),
            "automations": .array(automations.map { auto in
                .object([
                    "id": .string(auto.id),
                    "name": .string(auto.name),
                ])
            }),
        ])
        return RPCError(code: "repo_in_use", message: message, data: data)
    }

    private func referencingAutomations(for repo: RepoRecord) async -> [Automation] {
        let data = await MainActor.run { service.store.load() }
        var matches: [Automation] = []
        for automation in data.automations {
            if await automationReferences(automation, repo: repo) {
                matches.append(automation)
            }
        }
        return matches
    }

    private func automationReferences(_ automation: Automation, repo: RepoRecord) async -> Bool {
        switch automation.target {
        case .repo(let selector):
            if let resolved = try? await service.resolveRepo(selector),
               resolved.id.caseInsensitiveCompare(repo.id) == .orderedSame {
                return true
            }
            let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.caseInsensitiveCompare(repo.id) == .orderedSame
                || trimmed.caseInsensitiveCompare(repo.displayName) == .orderedSame
        case .workspace(let selector):
            guard let workspace = try? await service.show(selector: selector) else { return false }
            return workspace.repoId.caseInsensitiveCompare(repo.id) == .orderedSame
        }
    }
}
