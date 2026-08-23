import Darwin
import Foundation
import OrchardProtocol

public struct StatusHandler: CommandHandler {
    public let verbs = ["status"]
    private let runtimeId: String
    private let startedAt: Date
    private let mode: RuntimeMode
    /// The `orchard` command this runtime injects into worker PTYs (T35) — reported
    /// so a caller can verify the workers were handed a runnable absolute path.
    private let cliCommand: String?

    public init(runtimeId: String, startedAt: Date = Date(), mode: RuntimeMode = .app,
                cliCommand: String? = nil) {
        self.runtimeId = runtimeId; self.startedAt = startedAt; self.mode = mode
        self.cliCommand = cliCommand
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        var result: [String: JSONValue] = [
            "runtimeId": .string(runtimeId), "pid": .number(Double(getpid())),
            "startedAt": .string(ISO8601DateFormatter().string(from: startedAt)),
            "status": .string("ready"), "mode": .string(mode.rawValue),
        ]
        if let cliCommand { result["cliCommand"] = .string(cliCommand) }
        return .success(id: request.id, result: .object(result))
    }
}
