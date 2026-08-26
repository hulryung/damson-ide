import Foundation
import OrchardProtocol
import OrchardTerminals

/// How the app starts an agent on a remote workspace: the same `terminal-create`
/// verb the CLI has used since T39 (`--worktree <remote> --engine <agent>`),
/// with failures carried as `code: message` so a sheet or card can show them
/// inline instead of swallowing them.
public struct RemoteAgentStartError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        RemoteAgentStart.inlineFailure(code: code, message: message)
    }
}

/// Handle the app binds after `terminal-create` answers. The PTY is already in
/// the runtime registry; this is just the identity the tab and host chip need.
public struct RemoteAgentPaneRef: Equatable, Sendable {
    public let handle: String
    public let paneKey: String
    public let engineID: String
    public let executionHostId: String

    public init(handle: String, paneKey: String, engineID: String, executionHostId: String) {
        self.handle = handle
        self.paneKey = paneKey
        self.engineID = engineID
        self.executionHostId = executionHostId
    }
}

public enum RemoteAgentStart: Sendable {
    /// Params the CLI `orchard terminal create --worktree … --engine …` sends.
    public static func terminalCreateParams(worktreeId: String, engineID: String,
                                            title: String? = nil) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "worktree": .string(worktreeId),
            "engine": .string(engineID),
        ]
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["title"] = .string(title)
        }
        return params
    }

    /// Read a successful `terminal-create` envelope, or throw the typed error
    /// the handler already produced. Missing identity fields become
    /// `invalid_argument` rather than a silent empty pane.
    public static func paneRef(from response: RPCResponse) throws -> RemoteAgentPaneRef {
        if !response.ok {
            throw RemoteAgentStartError(
                code: response.error?.code ?? "internal_error",
                message: response.error?.message ?? "terminal create failed")
        }
        let object = response.result?.objectValue ?? [:]
        guard let handle = object["handle"]?.stringValue, !handle.isEmpty else {
            throw RemoteAgentStartError(
                code: "invalid_argument",
                message: "terminal create returned no handle")
        }
        let paneKey = object["paneKey"]?.stringValue ?? ""
        let engineID = object["engine"]?.stringValue ?? ""
        let host = object["executionHostId"]?.stringValue ?? ""
        return RemoteAgentPaneRef(
            handle: handle, paneKey: paneKey, engineID: engineID, executionHostId: host)
    }

    /// Call the in-process `terminal-create` handler — the same registry the
    /// CLI socket uses — and decode the pane identity.
    public static func createPane(using server: InMemoryRuntimeServer,
                                  worktreeId: String, engineID: String,
                                  title: String? = nil) async throws -> RemoteAgentPaneRef {
        let request = RPCRequest(
            method: "terminal-create",
            params: .object(terminalCreateParams(
                worktreeId: worktreeId, engineID: engineID, title: title)))
        return try paneRef(from: await server.perform(request))
    }

    /// `code: message` for a sheet or card. Never empty: a catch site that
    /// stringifies this always has something to show.
    public static func inlineFailure(code: String, message: String) -> String {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty && message.isEmpty { return "internal_error: the runtime returned no result" }
        if code.isEmpty { return message }
        if message.isEmpty { return code }
        if message.contains(code) { return message }
        return "\(code): \(message)"
    }

    public static func describe(_ error: Error) -> String {
        if let error = error as? RemoteAgentStartError {
            return inlineFailure(code: error.code, message: error.message)
        }
        if let error = error as? WorkspaceError {
            return inlineFailure(code: error.code, message: error.message)
        }
        if let error = error as? RemoteHostError {
            return inlineFailure(code: error.code, message: error.message)
        }
        if let error = error as? TerminalServiceError {
            return inlineFailure(code: error.code, message: error.message)
        }
        if let error = error as? HostRegistryError {
            return inlineFailure(code: error.code, message: error.message)
        }
        let text = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "internal_error: \(error)" : text
    }
}
