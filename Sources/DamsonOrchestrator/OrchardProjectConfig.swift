import Foundation

/// Per-repo configuration read from `orchard.yaml` at the root of a worktree.
///
/// Committing this file is how a project says "here is what a fresh checkout needs before
/// an agent can work in it" — installing dependencies, seeding a `.env`, generating code.
/// Without it, every agent's first turn is wasted rediscovering the same setup steps.
///
/// ```yaml
/// scripts:
///   setup: |
///     npm install
///     cp .env.example .env
///   archive: |
///     docker compose down
/// sharedPaths:
///   - node_modules
///   - .env
/// ```
public struct OrchardProjectConfig: Equatable, Sendable {
    /// Shell script run once in a newly-created worktree, before the agent starts.
    public var setup: String?
    /// Shell script run just before a worktree is deleted (stop containers, free ports).
    public var archive: String?
    /// Paths copied (or symlinked) from the primary checkout into each new worktree.
    /// For the things a fresh clone can't produce and shouldn't re-download per agent:
    /// `node_modules`, `.env`, build caches.
    public var sharedPaths: [String]

    public init(setup: String? = nil, archive: String? = nil, sharedPaths: [String] = []) {
        self.setup = setup
        self.archive = archive
        self.sharedPaths = sharedPaths
    }

    public static let empty = OrchardProjectConfig()
    public var isEmpty: Bool { setup == nil && archive == nil && sharedPaths.isEmpty }

    public static let fileName = "orchard.yaml"

    /// Read `orchard.yaml` from a directory. A missing or unparseable file is not an error —
    /// it just means the project has no setup requirements.
    public static func load(from directory: URL) -> OrchardProjectConfig {
        let url = directory.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return parse(text)
    }

    /// Parse the small, fixed YAML subset above.
    ///
    /// Deliberately hand-rolled rather than pulling in a YAML dependency: the schema is three
    /// keys, and the alternative is a package that would have to be vendored, pinned, and
    /// audited to read a config most repos won't even have. Anything outside the documented
    /// shape is ignored rather than rejected, so a richer file written for a future version
    /// still yields the keys this version understands.
    public static func parse(_ text: String) -> OrchardProjectConfig {
        var config = OrchardProjectConfig()
        let lines = text.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            i += 1
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard indent(of: line) == 0, let colon = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let inlineValue = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "scripts":
                let (scripts, next) = parseScripts(lines, from: i)
                config.setup = scripts["setup"]
                config.archive = scripts["archive"]
                i = next
            case "sharedPaths", "symlinkPaths":
                let (items, next) = parseList(lines, from: i, inline: inlineValue)
                config.sharedPaths = items
                i = next
            default:
                continue
            }
        }
        return config
    }

    // MARK: - Parsing helpers

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// Nested `setup:` / `archive:` entries, each either inline or a `|` block scalar.
    private static func parseScripts(_ lines: [String], from start: Int) -> ([String: String], Int) {
        var scripts: [String: String] = [:]
        var i = start
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            // Dedented back to the top level — this block is over.
            if indent(of: line) == 0 { break }
            guard let colon = trimmed.firstIndex(of: ":") else { i += 1; continue }

            let name = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            i += 1

            if value == "|" || value == "|-" || value == ">" {
                let (block, next) = parseBlockScalar(lines, from: i, parentIndent: indent(of: line))
                scripts[name] = block
                i = next
            } else if !value.isEmpty {
                scripts[name] = unquote(value)
            }
        }
        return (scripts, i)
    }

    /// Lines more-indented than the key that introduced them, with that common indent removed.
    private static func parseBlockScalar(_ lines: [String], from start: Int,
                                         parentIndent: Int) -> (String, Int) {
        var body: [String] = []
        var i = start
        var blockIndent: Int?

        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line inside the block is content; a trailing one is not.
                body.append("")
                i += 1
                continue
            }
            let ind = indent(of: line)
            if ind <= parentIndent { break }
            if blockIndent == nil { blockIndent = ind }
            body.append(String(line.dropFirst(min(blockIndent ?? ind, ind))))
            i += 1
        }
        while let last = body.last, last.isEmpty { body.removeLast() }
        return (body.joined(separator: "\n"), i)
    }

    /// A `- item` list, or an inline `[a, b]` flow sequence.
    private static func parseList(_ lines: [String], from start: Int,
                                  inline: String) -> ([String], Int) {
        if inline.hasPrefix("["), inline.hasSuffix("]") {
            let inner = inline.dropFirst().dropLast()
            let items = inner.split(separator: ",")
                .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            return (items, start)
        }
        var items: [String] = []
        var i = start
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            if indent(of: line) == 0 { break }
            guard trimmed.hasPrefix("- ") || trimmed == "-" else { break }
            let value = unquote(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
            if !value.isEmpty { items.append(value) }
            i += 1
        }
        return (items, i)
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
