import Foundation
import OrchardProtocol
import OrchardTerminals

/// RPC surface for the terminal service: `terminal list|create|read|send|wait|split|
/// close|rename` mapped 1:1 onto `TerminalService`, with the service's typed errors
/// translated to wire error codes. `terminal-split` is a stub until the app-side pane
/// tree exists (T5/wave-2) — the verb is claimed now so the CLI surface is stable.
public struct TerminalCommandHandler: CommandHandler {
    private let service: TerminalService

    public init(service: TerminalService) {
        self.service = service
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
        } catch {
            return .failure(id: request.id, error: RPCError(
                code: "internal_error", message: String(describing: error)))
        }
    }

    private func route(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]
        switch request.method {
        case "terminal-list":
            let summaries = await service.list(worktreeId: params["worktree"]?.stringValue)
            return try .object([
                "terminals": encodeJSON(summaries),
                "totalCount": .number(Double(summaries.count)),
                "truncated": .bool(false),
            ])

        case "terminal-create":
            let summary = try await service.create(
                worktreeId: params["worktree"]?.stringValue,
                cwd: params["cwd"]?.stringValue,
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
}

/// Bridge any Encodable result into the envelope's `JSONValue` (both sides speak
/// Codable, so the round-trip is exact and needs no per-type mapping code).
private func encodeJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private extension JSONValue {
    var intValue: Int? {
        if case let .number(n) = self { return Int(n) }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }
}
