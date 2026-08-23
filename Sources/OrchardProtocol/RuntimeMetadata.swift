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
    /// The `orchard` CLI command this runtime hands to the workers it spawns — an
    /// absolute path whenever one resolved on this machine (T35). Recorded here so a
    /// second process can reuse the same install path instead of re-deriving it, and
    /// so `status` can report what workers were told to call. Optional for
    /// compatibility with metadata written by an older runtime.
    public let cliCommand: String?

    public init(runtimeId: String, pid: Int32, socketPath: String, authToken: String,
                startedAt: Date = Date(), mode: RuntimeMode = .app,
                cliCommand: String? = nil) {
        self.runtimeId = runtimeId; self.pid = pid; self.socketPath = socketPath
        self.authToken = authToken; self.startedAt = startedAt; self.mode = mode
        self.cliCommand = cliCommand
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeId, pid, socketPath, authToken, startedAt, mode, cliCommand
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runtimeId = try values.decode(String.self, forKey: .runtimeId)
        pid = try values.decode(Int32.self, forKey: .pid)
        socketPath = try values.decode(String.self, forKey: .socketPath)
        authToken = try values.decode(String.self, forKey: .authToken)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        mode = try values.decodeIfPresent(RuntimeMode.self, forKey: .mode) ?? .app
        cliCommand = try values.decodeIfPresent(String.self, forKey: .cliCommand)
    }
}
