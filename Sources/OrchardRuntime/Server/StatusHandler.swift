import Darwin
import Foundation
import OrchardProtocol

public struct StatusHandler: CommandHandler {
    public let verbs = ["status"]
    private let runtimeId: String
    private let startedAt: Date
    private let mode: RuntimeMode

    public init(runtimeId: String, startedAt: Date = Date(), mode: RuntimeMode = .app) {
        self.runtimeId = runtimeId; self.startedAt = startedAt; self.mode = mode
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        .success(id: request.id, result: .object([
            "runtimeId": .string(runtimeId), "pid": .number(Double(getpid())),
            "startedAt": .string(ISO8601DateFormatter().string(from: startedAt)),
            "status": .string("ready"), "mode": .string(mode.rawValue)
        ]))
    }
}
