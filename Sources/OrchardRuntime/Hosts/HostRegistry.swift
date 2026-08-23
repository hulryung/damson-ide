import Foundation

public enum HostRegistryError: Error, Equatable, Sendable {
    case invalidName(String)
    case invalidArgument(String)
    case duplicate(String)
    case unknownHost(String)
    /// The name was offered for import but is not in `~/.ssh/config` (any more).
    case notInSSHConfig(String)

    public var code: String {
        switch self {
        case .invalidName, .invalidArgument: return "invalid_argument"
        case .duplicate: return "host_exists"
        case .unknownHost, .notInSSHConfig: return "unknown_host"
        }
    }

    public var message: String {
        switch self {
        case .invalidName(let name):
            return "'\(name)' is not a usable host name (letters, digits, '.', '_', '-', '@')"
        case .invalidArgument(let why): return why
        case .duplicate(let name): return "host '\(name)' is already registered"
        case .unknownHost(let name): return "no registered host named '\(name)'"
        case .notInSSHConfig(let name): return "no Host block named '\(name)' in ~/.ssh/config"
        }
    }
}

/// The registry of remote hosts, persisted in `orchard-data.json`.
///
/// A host record is a *name for a connection target* and nothing more. It is never
/// removed because a probe failed, and its presence is never evidence that anything is
/// reachable — the registry and liveness are separate questions on purpose
/// (`HostLivenessVerdict`).
public struct HostRegistry: Sendable {
    private let store: OrchardDataStore
    private let sshConfig: @Sendable () -> [SSHConfigHost]

    public init(store: OrchardDataStore,
                sshConfig: @escaping @Sendable () -> [SSHConfigHost] = { SSHConfigParser.loadUserConfig() }) {
        self.store = store
        self.sshConfig = sshConfig
    }

    public func list() -> [HostRecord] {
        store.load().hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func find(name: String) -> HostRecord? {
        store.load().hosts.first { $0.name == name }
    }

    public func require(name: String) throws -> HostRecord {
        guard let record = find(name: name) else { throw HostRegistryError.unknownHost(name) }
        return record
    }

    /// Resolve an `ssh:<name>` id to its registered host. An id whose host was never
    /// registered fails typed rather than being connected to blind.
    public func require(host: ExecutionHostId) throws -> HostRecord {
        guard host.kind == .ssh else {
            throw HostRegistryError.invalidArgument("'\(host.rawValue)' is not a remote host")
        }
        return try require(name: host.name)
    }

    @discardableResult
    public func add(name: String, hostname: String?, user: String?, port: Int?,
                    source: HostRecord.Source = .manual) throws -> HostRecord {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard ExecutionHostId.isValidHostName(name) else {
            throw HostRegistryError.invalidName(name)
        }
        if let port, port <= 0 || port > 65535 {
            throw HostRegistryError.invalidArgument("port \(port) is out of range")
        }
        if find(name: name) != nil { throw HostRegistryError.duplicate(name) }
        let record = HostRecord(
            name: name,
            hostname: (hostname?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? name,
            user: user.flatMap { $0.isEmpty ? nil : $0 },
            port: port,
            source: source)
        try store.modify { $0.hosts.append(record) }
        return record
    }

    /// The `~/.ssh/config` names that are not registered yet — what `host add --import`
    /// offers when it is called without a name.
    public func importable() -> [SSHConfigHost] {
        let registered = Set(store.load().hosts.map(\.name))
        return sshConfig().filter { !registered.contains($0.alias) && ExecutionHostId.isValidHostName($0.alias) }
    }

    /// Register one `~/.ssh/config` alias. The parsed HostName/User/Port are stored for
    /// display only — the connection uses the alias so OpenSSH applies the real config.
    @discardableResult
    public func importFromSSHConfig(name: String) throws -> HostRecord {
        guard let entry = sshConfig().first(where: { $0.alias == name }) else {
            throw HostRegistryError.notInSSHConfig(name)
        }
        return try add(name: entry.alias, hostname: entry.hostname, user: entry.user,
                       port: entry.port, source: .sshConfig)
    }
}
