import Foundation

/// Which execution host owns a workspace, a terminal, or a PTY.
///
/// Orca stamps `ExecutionHostId = 'local' | 'ssh:<id>' | 'runtime:<id>'` on everything
/// (docs/research/orca-inventory.md §2 "Identity", rebuild checklist #14). Orchard
/// carries the same field but only the first two kinds exist today: `runtime:` names
/// Orca's ephemeral-VM environments, which Orchard has no equivalent for. Parsing an
/// unknown kind fails rather than silently resolving to `local` — quietly downgrading a
/// remote id to local is exactly how work gets executed on the wrong machine.
public enum ExecutionHostKind: String, Codable, Sendable {
    case local
    case ssh
}

public struct ExecutionHostId: Hashable, Sendable, CustomStringConvertible {
    public let kind: ExecutionHostKind
    /// The registered host name for `.ssh`; empty for `.local`.
    public let name: String

    public static let local = ExecutionHostId(kind: .local, name: "")

    private init(kind: ExecutionHostKind, name: String) {
        self.kind = kind
        self.name = name
    }

    public static func ssh(_ name: String) -> ExecutionHostId? {
        guard isValidHostName(name) else { return nil }
        return ExecutionHostId(kind: .ssh, name: name)
    }

    /// `local` or `ssh:<name>` — the string persisted and put on the wire.
    public var rawValue: String {
        switch kind {
        case .local: return "local"
        case .ssh: return "ssh:\(name)"
        }
    }

    public var description: String { rawValue }

    public var isLocal: Bool { kind == .local }

    /// What a user-facing surface calls this host (a tab label, a card chip).
    public var label: String {
        switch kind {
        case .local: return "Local"
        case .ssh: return name
        }
    }

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed == "local" {
            self = .local
            return
        }
        guard trimmed.hasPrefix("ssh:") else { return nil }
        let name = String(trimmed.dropFirst("ssh:".count))
        guard let parsed = ExecutionHostId.ssh(name) else { return nil }
        self = parsed
    }

    /// Host names are OpenSSH aliases (or plain hostnames), so the raw id needs no
    /// escaping: reject anything that would make `ssh:<name>` ambiguous instead of
    /// percent-encoding it, and the id stays greppable in JSON and log lines.
    public static func isValidHostName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        if name.hasPrefix("-") { return false }
        return name.allSatisfy { character in
            character.isLetter || character.isNumber || "._-@".contains(character)
        }
    }
}

extension ExecutionHostId: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = ExecutionHostId(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "not an execution host id: '\(raw)'"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
