import Foundation

/// One concrete `Host` block from an OpenSSH config file.
public struct SSHConfigHost: Equatable, Sendable {
    public let alias: String
    public var hostname: String?
    public var user: String?
    public var port: Int?

    public init(alias: String, hostname: String? = nil, user: String? = nil, port: Int? = nil) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
    }
}

/// Reads `~/.ssh/config` well enough to *offer names for import* — nothing more.
///
/// Deliberately not a resolver: Orchard never re-implements OpenSSH's matching rules,
/// because an imported host connects by its alias and `ssh` applies the user's real
/// config itself. So only the directives shown in the picker are read (HostName, User,
/// Port), wildcard/negated patterns are skipped (`Host *` is a defaults block, not a
/// host), and `Match` blocks end the current block because their bodies are conditional.
public enum SSHConfigParser {
    public static func parse(_ content: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: [Int] = []      // indices into `hosts` for the open Host block

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (key, rawValue) = directive(line) else { continue }

            switch key {
            case "host":
                current = []
                for pattern in splitArguments(rawValue) where isConcretePattern(pattern) {
                    // A repeated alias keeps its first block: OpenSSH takes the first
                    // obtained value for every single-valued parameter.
                    if let existing = hosts.firstIndex(where: { $0.alias == pattern }) {
                        current.append(existing)
                        continue
                    }
                    hosts.append(SSHConfigHost(alias: pattern))
                    current.append(hosts.count - 1)
                }
            case "match":
                current = []
            case "hostname":
                let value = scalar(rawValue)
                for index in current where hosts[index].hostname == nil {
                    hosts[index].hostname = value
                }
            case "user":
                let value = scalar(rawValue)
                for index in current where hosts[index].user == nil {
                    hosts[index].user = value
                }
            case "port":
                guard let value = Int(scalar(rawValue)), value > 0, value <= 65535 else { continue }
                for index in current where hosts[index].port == nil {
                    hosts[index].port = value
                }
            default:
                continue
            }
        }
        return hosts
    }

    /// Parse the user's `~/.ssh/config`. A missing or unreadable file is "no hosts to
    /// offer", never an error — most machines have no SSH config at all.
    public static func loadUserConfig(
        fileManager: FileManager = .default,
        path: String = NSHomeDirectory() + "/.ssh/config"
    ) -> [SSHConfigHost] {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              let content = String(data: data, encoding: .utf8)
        else { return [] }
        return parse(content)
    }

    // MARK: - Lexing

    /// `Key value`, `Key=value`, and `Key = value` are all the same directive.
    private static func directive(_ line: String) -> (key: String, rawValue: String)? {
        guard let split = line.firstIndex(where: { $0 == "=" || $0.isWhitespace }) else { return nil }
        let key = String(line[line.startIndex..<split]).lowercased()
        var rest = String(line[line.index(after: split)...])
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return key.isEmpty ? nil : (key, rest)
    }

    private static func scalar(_ input: String) -> String {
        splitArguments(input).first ?? ""
    }

    /// Wildcards and negations are patterns, not hosts: `ssh <pattern>` would not
    /// connect anywhere, so importing one would register a target that can never work.
    private static func isConcretePattern(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.hasPrefix("!")
            && !pattern.contains("*") && !pattern.contains("?")
    }

    /// OpenSSH argument splitting: whitespace separated, `"` quoting, `#` starts a
    /// comment outside quotes.
    private static func splitArguments(_ input: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var inQuotes = false
        for character in input {
            if character == "\"" { inQuotes.toggle(); continue }
            if !inQuotes && character == "#" { break }
            if !inQuotes && character.isWhitespace {
                if !current.isEmpty { arguments.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { arguments.append(current) }
        return arguments
    }
}
