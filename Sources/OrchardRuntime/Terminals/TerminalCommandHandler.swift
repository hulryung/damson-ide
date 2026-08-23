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
public struct TerminalCommandHandler: CommandHandler, @unchecked Sendable {
    private let service: TerminalService
    private let workspaces: WorkspaceService?

    public init(service: TerminalService, workspaces: WorkspaceService? = nil) {
        self.service = service
        self.workspaces = workspaces
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
            let summary = try await service.create(
                worktreeId: resolved?.id,
                cwd: params["cwd"]?.stringValue ?? resolved?.path,
                engineID: params["engine"]?.stringValue ?? "shell",
                prompt: params["prompt"]?.stringValue ?? "",
                title: params["title"]?.stringValue)
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

    private func requiredHandle(_ params: [String: JSONValue]) throws -> String {
        guard let handle = params["terminal"]?.stringValue, !handle.isEmpty else {
            throw TerminalServiceError.invalidArgument("missing required param 'terminal'")
        }
        return handle
    }

    private func resolvedWorktree(_ params: [String: JSONValue]) async throws -> (id: String, path: String?)? {
        guard let selector = params["worktree"]?.stringValue, !selector.isEmpty else { return nil }
        guard let workspaces else { return (selector, nil) }
        let cwd = params["cwd"]?.stringValue
        return try await MainActor.run {
            do {
                let workspace = try workspaces.resolveWorkspace(selector, cwd: cwd)
                return (workspace.id, workspace.path)
            } catch let error as WorkspaceError {
                if Self.isStrictSelector(selector) { throw error }
                return (selector, nil)
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
