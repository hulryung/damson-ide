import Foundation

/// A registered remote host. This is a *connection target*, not a claim about what
/// runs there: registering a host proves nothing about reachability, and losing
/// contact with one never removes it (see `HostLivenessVerdict`).
public struct HostRecord: Codable, Equatable, Sendable, Identifiable {
    /// Where the entry came from — which also decides how `ssh` is invoked for it.
    /// `sshConfig` entries connect by their alias so OpenSSH re-resolves the user's own
    /// `~/.ssh/config` (ProxyJump, IdentityFile, and everything else Orchard does not
    /// model); `manual` entries connect by `[user@]hostname` with an explicit `-p`.
    public enum Source: String, Codable, Sendable {
        case manual
        case sshConfig = "ssh-config"
    }

    /// The registry key and the `ssh:<name>` id suffix.
    public var name: String
    public var hostname: String
    public var user: String?
    public var port: Int?
    public var source: Source
    public var addedAt: Date

    public var id: String { name }

    public init(name: String, hostname: String, user: String? = nil, port: Int? = nil,
                source: Source = .manual, addedAt: Date = Date()) {
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.source = source
        self.addedAt = addedAt
    }

    public var executionHostId: ExecutionHostId? { ExecutionHostId.ssh(name) }

    /// How the host reads in a list: `ubuntu@10.0.0.5:2222`, or just the hostname.
    public var displayTarget: String {
        var target = hostname.isEmpty ? name : hostname
        if let user, !user.isEmpty { target = "\(user)@\(target)" }
        if let port, port != 22 { target += ":\(port)" }
        return target
    }
}
