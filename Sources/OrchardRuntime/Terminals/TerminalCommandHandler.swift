import Foundation
import OrchardProtocol
import OrchardTerminals

/// RPC surface for the terminal service: `terminal list|create|read|send|wait|split|
/// close|rename` mapped 1:1 onto `TerminalService`, with the service's typed errors
/// translated to wire error codes. `terminal-split` is a stub until the app-side pane
/// tree exists (T5/wave-2) — the verb is claimed now so the CLI surface is stable.
///
/// When a `WorkspaceService` is attached, `--worktree path:|name:|active` selectors
/// resolve through the workspace registry (including projected repo primary
/// checkouts) so create/list key terminals by `repoId::path`.
///
/// With a `HostRegistry` attached, `terminal-create --host ssh:<name>` opens a remote
/// shell (T29): still a local PTY, but its child is `ssh -tt <host>`, and the summary
/// is stamped with the `ssh:<name>` execution host so nothing downstream mistakes the
/// work for local. An unregistered host fails typed — the runtime never connects to a
/// name it was not given.
public struct TerminalCommandHandler: CommandHandler, @unchecked Sendable {
    private let service: TerminalService
    private let workspaces: WorkspaceService?
    private let hosts: HostRegistry?
    private let hookChannel: AgentHookChannel?
    /// Injected so tests can drive the remote agent path with a scripted `ssh`.
    private let hostRunner: HostCommandRunner

    public init(service: TerminalService, workspaces: WorkspaceService? = nil,
                hosts: HostRegistry? = nil, hookChannel: AgentHookChannel? = nil,
                hostRunner: HostCommandRunner = ProcessHostCommandRunner()) {
        self.service = service
        self.workspaces = workspaces
        self.hosts = hosts
        self.hookChannel = hookChannel
        self.hostRunner = hostRunner
    }

    public var verbs: [String] {
        ["terminal-list", "terminal-create", "terminal-read", "terminal-send",
         "terminal-wait", "terminal-split", "terminal-close", "terminal-rename"]
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            let result = try await route(request)
            return .success(id: request.id, result: result)
        } catch let error as TerminalServiceError {
            return .failure(id: request.id, error: RPCError(
                code: error.code, message: error.message))
        } catch let error as WorkspaceError {
            return .failure(id: request.id, error: RPCError(
                code: error.code, message: error.message))
        } catch let error as HostRegistryError {
            return .failure(id: request.id, error: RPCError(
                code: error.code, message: error.message))
        } catch let error as RemoteHostError {
            return .failure(id: request.id, error: RPCError(
                code: error.code, message: error.message))
        } catch {
            return .failure(id: request.id, error: RPCError(
                code: "internal_error", message: String(describing: error)))
        }
    }

    private func route(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]
        switch request.method {
        case "terminal-list":
            let resolved = try await resolvedWorktree(params)
            let summaries = await service.list(worktreeId: resolved?.id)
            return try .object([
                "terminals": encodeJSON(summaries),
                "totalCount": .number(Double(summaries.count)),
                "truncated": .bool(false),
            ])

        case "terminal-create":
            let resolved = try await resolvedWorktree(params)
            // Canonical first: `--engine Claude` and `--engine claude` must take the
            // same fork as `claude-code`, and an unknown id must reach the engine
            // registry's own typed refusal rather than being read as "not the shell".
            let requestedEngine = params["engine"]?.stringValue ?? "shell"
            let engineID = AgentEngineRegistry.canonicalID(requestedEngine) ?? requestedEngine
            let prompt = params["prompt"]?.stringValue ?? ""
            let host = try executionHost(params)
            // T32: a pane opened in a remote worktree inherits that workspace's host.
            // The host is taken from the workspace record rather than defaulted, so a
            // pane can never end up local while claiming to be in remote files. T80
            // moved that resolution and the launch itself into `RemotePaneLauncher`,
            // shared with `worker-start`'s remote `terminal_create` stage.
            if let workspace = resolved,
               RemoteWorkspacePolicy.isRemote(hostId: workspace.hostId) {
                let workspaceHost = try RemotePaneLauncher.resolveHost(
                    workspaceID: workspace.id, workspaceStamp: workspace.hostId,
                    requested: host)
                guard let workspaceHost else {
                    throw TerminalServiceError.invalidArgument(
                        "worktree \(workspace.id) has an unusable execution host")
                }
                guard let path = workspace.path, !path.isEmpty else {
                    throw TerminalServiceError.invalidArgument(
                        "worktree \(workspace.id) has no remote path to open")
                }
                let summary = try await requireRemotePanes().create(
                    engineID: engineID, host: workspaceHost, workspaceID: workspace.id,
                    path: path, title: params["title"]?.stringValue, prompt: prompt)
                return try encodeJSON(summary)
            }
            if host.isLocal {
                let summary = try await service.create(
                    worktreeId: resolved?.id,
                    cwd: params["cwd"]?.stringValue ?? resolved?.path,
                    engineID: engineID,
                    prompt: prompt,
                    title: params["title"]?.stringValue)
                return try encodeJSON(summary)
            }
            let record = try requireHosts().require(host: host)
            // A remote agent needs a remote *worktree*: its hook config is written into
            // one, and an agent with no repo to work in is not the feature. `--host`
            // alone names a connection, not a workspace, so this stays refused (T39
            // implements the `--worktree <remote id> --engine <agent>` spelling).
            guard engineID == "shell" else {
                throw TerminalServiceError.notImplemented(
                    "running the '\(engineID)' agent on \(host.rawValue) without a "
                        + "remote worktree — pass --worktree <remote worktree id>")
            }
            // The worktree selector still resolves locally: a remote pane has no local
            // workspace, so `cwd` is where `ssh` is launched from, not where the work
            // happens. Remote worktrees are out of scope for this stage.
            let summary = try await service.create(
                worktreeId: resolved?.id,
                cwd: params["cwd"]?.stringValue ?? resolved?.path,
                engineID: "shell",
                prompt: SSHCommand.remoteShellCommandLine(
                    for: record, command: prompt.isEmpty ? nil : prompt),
                title: params["title"]?.stringValue ?? record.name,
                executionHostId: host.rawValue)
            return try encodeJSON(summary)

        case "terminal-read":
            let result = try await service.read(
                handle: try requiredHandle(params),
                cursor: params["cursor"]?.intValue,
                limit: params["limit"]?.intValue ?? 200,
                screen: params["screen"]?.boolValue ?? false)
            return try encodeJSON(result)

        case "terminal-send":
            let result = try await service.send(
                handle: try requiredHandle(params),
                text: params["text"]?.stringValue,
                enter: params["enter"]?.boolValue ?? false,
                interrupt: params["interrupt"]?.boolValue ?? false,
                requireAgent: params["requireAgent"]?.boolValue)
            return try encodeJSON(result)

        case "terminal-wait":
            let conditionName = params["for"]?.stringValue ?? ""
            guard let condition = TerminalWaitCondition(rawValue: conditionName) else {
                throw TerminalServiceError.invalidArgument(
                    "wait requires --for tui-idle|exit (got '\(conditionName)')")
            }
            let result = try await service.wait(
                handle: try requiredHandle(params),
                for: condition,
                timeout: params["timeoutMs"]?.intValue.map { Double($0) / 1000 })
            return try encodeJSON(result)

        case "terminal-split":
            throw TerminalServiceError.notImplemented("terminal split")

        case "terminal-close":
            let handle = try requiredHandle(params)
            try await service.close(handle: handle)
            return .object(["handle": .string(handle), "closed": .bool(true)])

        case "terminal-rename":
            let summary = try await service.rename(
                handle: try requiredHandle(params),
                title: params["title"]?.stringValue)
            return try encodeJSON(summary)

        default:
            throw TerminalServiceError.invalidArgument("unrouted verb '\(request.method)'")
        }
    }

    /// The launcher for panes whose work happens on another machine, or a typed
    /// refusal when this runtime has no host registry wired.
    private func requireRemotePanes() throws -> RemotePaneLauncher {
        let hosts = try requireHosts()
        let channel = hookChannel
        return RemotePaneLauncher(service: service, hosts: hosts,
                                  localHookPort: { channel?.localHookPort ?? 0 },
                                  hostRunner: hostRunner)
    }

    /// `--host` defaults to `local`. An unparseable value is rejected rather than
    /// falling back: "degrade to read-only inspection, never fall back to local
    /// execution" (docs/research/orca-inventory.md §1.8).
    private func executionHost(_ params: [String: JSONValue]) throws -> ExecutionHostId {
        guard let raw = params["host"]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return .local }
        guard let host = ExecutionHostId(rawValue: raw) else {
            throw TerminalServiceError.invalidArgument(
                "--host must be 'local' or 'ssh:<name>' (got '\(raw)')")
        }
        return host
    }

    private func requireHosts() throws -> HostRegistry {
        guard let hosts else {
            throw TerminalServiceError.notImplemented("remote terminals in this runtime")
        }
        return hosts
    }

    private func requiredHandle(_ params: [String: JSONValue]) throws -> String {
        guard let handle = params["terminal"]?.stringValue, !handle.isEmpty else {
            throw TerminalServiceError.invalidArgument("missing required param 'terminal'")
        }
        return handle
    }

    private func resolvedWorktree(_ params: [String: JSONValue]) async throws
        -> (id: String, path: String?, hostId: String?)? {
        guard let selector = params["worktree"]?.stringValue, !selector.isEmpty else { return nil }
        guard let workspaces else { return (selector, nil, nil) }
        let cwd = params["cwd"]?.stringValue
        return try await MainActor.run {
            do {
                let workspace = try workspaces.resolveWorkspace(selector, cwd: cwd)
                // The raw stamp travels, not a parsed-or-nil host: the create path has
                // to be able to tell "local" from "unreadable", and only one of those
                // may open a local shell.
                return (workspace.id, workspace.path, workspace.hostId)
            } catch let error as WorkspaceError {
                if Self.isStrictSelector(selector) { throw error }
                return (selector, nil, nil)
            }
        }
    }

    /// Selectors that must resolve through the workspace registry. Bare ids
    /// still pass through so tests and pre-projection callers keep working.
    private static func isStrictSelector(_ selector: String) -> Bool {
        let trimmed = selector.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower == "active" || lower == "current" { return true }
        for prefix in ["path:", "name:", "branch:", "issue:"] {
            if lower.hasPrefix(prefix) { return true }
        }
        return false
    }
}

/// Bridge any Encodable result into the envelope's `JSONValue` (both sides speak
/// Codable, so the round-trip is exact and needs no per-type mapping code).
private func encodeJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

// JSONValue accessors: boolValue comes from OrchardProtocol, intValue from
// Workspaces/JSONBridge (same module).
