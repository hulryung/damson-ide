import Foundation

public enum RuntimeMode: String, Codable, Equatable, Sendable {
    case app
    case headless
}

public struct RuntimeMetadata: Codable, Equatable, Sendable {
    public let runtimeId: String
    public let pid: Int32
    public let socketPath: String
    public let authToken: String
    public let startedAt: Date
    public let mode: RuntimeMode

    public init(runtimeId: String, pid: Int32, socketPath: String, authToken: String,
                startedAt: Date = Date(), mode: RuntimeMode = .app) {
        self.runtimeId = runtimeId; self.pid = pid; self.socketPath = socketPath
        self.authToken = authToken; self.startedAt = startedAt; self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeId, pid, socketPath, authToken, startedAt, mode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runtimeId = try values.decode(String.self, forKey: .runtimeId)
        pid = try values.decode(Int32.self, forKey: .pid)
        socketPath = try values.decode(String.self, forKey: .socketPath)
        authToken = try values.decode(String.self, forKey: .authToken)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        mode = try values.decodeIfPresent(RuntimeMode.self, forKey: .mode) ?? .app
    }
}
