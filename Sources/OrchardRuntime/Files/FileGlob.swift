import Foundation

/// POSIX-style glob used by content-search include/exclude.
///
/// A pattern with no `/` matches at any depth (`*.swift` hits `src/App.swift`).
/// `*` and `?` do not cross `/`; `**` does. Character classes are treated as
/// literals so a hostile pattern can't become a surprising regex.
public struct FileGlob: Equatable, Sendable {
    public let pattern: String
    /// ICU regex `FileGlob` compiled. The remote search transport sends this to the
    /// far side so include/exclude keep the same meaning over ssh.
    let regexPattern: String
    private let regex: NSRegularExpression

    public static func == (lhs: FileGlob, rhs: FileGlob) -> Bool {
        lhs.pattern == rhs.pattern
    }

    public init(_ pattern: String) throws {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileServiceError.invalidArgument("empty glob")
        }
        if trimmed.utf8.count > 8 * 1024 {
            throw FileServiceError.invalidArgument("glob exceeds 8 KB")
        }
        self.pattern = trimmed
        do {
            let compiled = try Self.compile(trimmed)
            self.regexPattern = compiled.pattern
            self.regex = compiled
        } catch {
            throw FileServiceError.invalidArgument("invalid glob '\(trimmed)'")
        }
    }

    public func matches(_ relativePath: String) -> Bool {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    public static func any(_ globs: [FileGlob], matches path: String) -> Bool {
        globs.contains { $0.matches(path) }
    }

    private static func compile(_ pattern: String) throws -> NSRegularExpression {
        var p = pattern.replacingOccurrences(of: "\\", with: "/")
        if p.hasPrefix("/") { p = String(p.dropFirst()) }
        // `*.swift` should hit nested files; don't rewrite patterns that already
        // name a directory or use `**`.
        if !p.contains("/") && p != "**" {
            p = "**/" + p
        }
        var regex = "^"
        var i = p.startIndex
        while i < p.endIndex {
            let ch = p[i]
            if ch == "*" {
                let next = p.index(after: i)
                if next < p.endIndex && p[next] == "*" {
                    let after = p.index(after: next)
                    if after < p.endIndex && p[after] == "/" {
                        regex += "(?:.*/)?"
                        i = p.index(after: after)
                    } else {
                        regex += ".*"
                        i = after
                    }
                } else {
                    regex += "[^/]*"
                    i = next
                }
            } else if ch == "?" {
                regex += "[^/]"
                i = p.index(after: i)
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(ch))
                i = p.index(after: i)
            }
        }
        regex += "$"
        return try NSRegularExpression(pattern: regex)
    }
}