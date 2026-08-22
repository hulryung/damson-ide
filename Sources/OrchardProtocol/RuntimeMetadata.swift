import Foundation

public struct RuntimeMetadata: Codable, Equatable, Sendable {
    public let runtimeId: String
    public let pid: Int32
    public let socketPath: String
    public let authToken: String
    public let startedAt: Date

    public init(runtimeId: String, pid: Int32, socketPath: String, authToken: String,
                startedAt: Date = Date()) {
        self.runtimeId = runtimeId; self.pid = pid; self.socketPath = socketPath
        self.authToken = authToken; self.startedAt = startedAt
    }
}
