import Foundation

/// One workspace the port sweep can attribute listeners to.
public struct PortWorkspaceProbe: Equatable, Sendable {
    public var id: String
    public var repoId: String
    public var displayName: String
    public var path: String

    public init(id: String, repoId: String, displayName: String, path: String) {
        self.id = id
        self.repoId = repoId
        self.displayName = displayName
        self.path = path
    }
}

/// A listening TCP socket parsed from `lsof -Fn` (or equivalent) before attribution.
public struct RawListeningPort: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var pid: Int32?
    public var processName: String?
    public var cwd: String?

    public init(host: String, port: Int, pid: Int32? = nil,
                processName: String? = nil, cwd: String? = nil) {
        self.host = host
        self.port = port
        self.pid = pid
        self.processName = processName
        self.cwd = cwd
    }
}

/// How a listener was joined to a workspace. T20 attributes by cwd containment;
/// `none` is unused on attributed rows (unattributed listeners are dropped).
public enum PortAttributionConfidence: String, Codable, Equatable, Sendable {
    case cwd
}

/// A listener that belongs to a managed workspace.
public struct WorkspaceListeningPort: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Address reported by the OS. May be a wildcard bind (`*`, `0.0.0.0`, `::`).
    public var bindHost: String
    /// Address a browser should open. Wildcard binds normalize to `localhost`.
    public var connectHost: String
    public var port: Int
    public var pid: Int32?
    public var processName: String?
    public var kind: String
    public var worktreeId: String
    public var repoId: String
    public var displayName: String
    public var path: String
    public var confidence: PortAttributionConfidence

    public init(id: String, bindHost: String, connectHost: String, port: Int,
                pid: Int32? = nil, processName: String? = nil,
                kind: String = "workspace", worktreeId: String, repoId: String,
                displayName: String, path: String,
                confidence: PortAttributionConfidence = .cwd) {
        self.id = id
        self.bindHost = bindHost
        self.connectHost = connectHost
        self.port = port
        self.pid = pid
        self.processName = processName
        self.kind = kind
        self.worktreeId = worktreeId
        self.repoId = repoId
        self.displayName = displayName
        self.path = path
        self.confidence = confidence
    }
}

/// Last completed sweep. `scannedAt` is ms epoch, matching other runtime timestamps.
public struct PortScanSnapshot: Codable, Equatable, Sendable {
    public var platform: String
    public var scannedAt: Double
    public var ports: [WorkspaceListeningPort]
    public var unavailableReason: String?

    public init(platform: String = "darwin", scannedAt: Double = 0,
                ports: [WorkspaceListeningPort] = [], unavailableReason: String? = nil) {
        self.platform = platform
        self.scannedAt = scannedAt
        self.ports = ports
        self.unavailableReason = unavailableReason
    }

    public static let empty = PortScanSnapshot()

    public func ports(forWorktreeId id: String) -> [WorkspaceListeningPort] {
        ports.filter { $0.worktreeId == id }
    }
}

/// One agent or shell terminal living in a workspace, as shown by `worktree ps`.
public struct WorktreeProcess: Codable, Equatable, Sendable {
    public var handle: String
    public var kind: String
    public var engine: String
    public var title: String?
    public var connected: Bool
    public var agentState: String?

    public init(handle: String, kind: String, engine: String, title: String? = nil,
                connected: Bool, agentState: String? = nil) {
        self.handle = handle
        self.kind = kind
        self.engine = engine
        self.title = title
        self.connected = connected
        self.agentState = agentState
    }
}

/// One workspace row in `orchard worktree ps`: terminals plus attributed listeners.
public struct WorktreeProcessRow: Codable, Equatable, Sendable {
    public var worktreeId: String
    public var repoId: String
    public var displayName: String
    public var path: String
    public var branch: String
    public var processes: [WorktreeProcess]
    public var ports: [WorkspaceListeningPort]

    public init(worktreeId: String, repoId: String, displayName: String, path: String,
                branch: String, processes: [WorktreeProcess],
                ports: [WorkspaceListeningPort]) {
        self.worktreeId = worktreeId
        self.repoId = repoId
        self.displayName = displayName
        self.path = path
        self.branch = branch
        self.processes = processes
        self.ports = ports
    }
}

public struct WorktreeProcessSnapshot: Codable, Equatable, Sendable {
    public var worktrees: [WorktreeProcessRow]
    public var totalCount: Int
    public var truncated: Bool
    public var scannedAt: Double
    public var platform: String

    public init(worktrees: [WorktreeProcessRow], totalCount: Int, truncated: Bool,
                scannedAt: Double, platform: String) {
        self.worktrees = worktrees
        self.totalCount = totalCount
        self.truncated = truncated
        self.scannedAt = scannedAt
        self.platform = platform
    }
}
