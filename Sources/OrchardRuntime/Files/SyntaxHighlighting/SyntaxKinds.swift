import Foundation

/// Languages the editor highlighter understands. Extension mapping is the
/// only signal — unknown files stay `.plain` so we never guess a grammar.
public enum SyntaxLanguage: String, Sendable, Equatable {
    case swift
    case json
    case yaml
    case markdown
    case shell
    case plain

    public static func infer(fromPath path: String) -> SyntaxLanguage {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "json", "jsonc": return .json
        case "yaml", "yml": return .yaml
        case "md", "markdown", "mdown", "mdwn": return .markdown
        case "sh", "bash", "zsh", "ksh", "command": return .shell
        default: return .plain
        }
    }

    public var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .shell: return "Shell"
        case .plain: return "Plain Text"
        }
    }
}

public enum SyntaxTokenKind: String, Sendable, Equatable {
    case text
    case keyword
    case string
    case comment
    case number
    /// Capitalized identifiers (`URL`, `FileService`) and similar type names.
    case type
}

public struct SyntaxToken: Sendable, Equatable {
    public var kind: SyntaxTokenKind
    public var utf16Location: Int
    public var utf16Length: Int

    public init(kind: SyntaxTokenKind, utf16Location: Int, utf16Length: Int) {
        self.kind = kind
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
    }

    public func contains(utf16Offset: Int) -> Bool {
        utf16Offset >= utf16Location && utf16Offset < utf16Location + utf16Length
    }
}

/// Cross-line lexer memory. Empty frames is a stable normal state: incremental
/// re-highlight can resume there without walking further back.
public struct TokenizerState: Hashable, Sendable, Equatable {
    public var frames: [String]

    public init(frames: [String] = []) {
        self.frames = frames
    }

    public static let normal = TokenizerState(frames: [])

    public var isStable: Bool { frames.isEmpty }
}

public struct SyntaxLine: Sendable, Equatable {
    public var startUTF16: Int
    public var endUTF16: Int
    public var breakUTF16: Int
    public var content: String
}

public struct HighlightResult: Sendable, Equatable {
    public var tokens: [SyntaxToken]
    public var lineEndStates: [TokenizerState]
    public var lineCount: Int
}

public struct HighlightSlice: Sendable, Equatable {
    public var tokens: [SyntaxToken]
    public var lineEndStates: [TokenizerState]
    public var fromLine: Int
    public var throughLine: Int
    public var utf16Location: Int
    public var utf16Length: Int
}

/// Compact stack frames persisted across lines. Kept as strings so heredoc
/// delimiters and fence markers do not need a second type.
enum SyntaxFrame {
    static func blockComment(_ depth: Int) -> String { "c:\(depth)" }
    static func string(multiline: Bool, hashes: Int) -> String {
        "s:\(multiline ? 1 : 0):\(hashes)"
    }
    static func interpolation(_ depth: Int) -> String { "i:\(depth)" }
    static func quote(double: Bool) -> String { double ? "q:d" : "q:s" }
    static func yamlBlock(_ indent: Int) -> String { "y:\(indent)" }
    static func fence(backtick: Bool, length: Int) -> String {
        "f:\(backtick ? "b" : "t"):\(length)"
    }
    static func heredoc(quoted: Bool, delimiter: String) -> String {
        "h:\(quoted ? 1 : 0):\(delimiter)"
    }

    static func blockCommentDepth(_ frame: String) -> Int? {
        guard frame.hasPrefix("c:") else { return nil }
        return Int(frame.dropFirst(2))
    }

    static func stringParts(_ frame: String) -> (multiline: Bool, hashes: Int)? {
        let parts = frame.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "s",
              let multi = Int(parts[1]), let hashes = Int(parts[2]) else { return nil }
        return (multi == 1, hashes)
    }

    static func interpolationDepth(_ frame: String) -> Int? {
        guard frame.hasPrefix("i:") else { return nil }
        return Int(frame.dropFirst(2))
    }

    static func isDoubleQuote(_ frame: String) -> Bool? {
        if frame == "q:d" { return true }
        if frame == "q:s" { return false }
        return nil
    }

    static func yamlIndent(_ frame: String) -> Int? {
        guard frame.hasPrefix("y:") else { return nil }
        return Int(frame.dropFirst(2))
    }

    static func fenceParts(_ frame: String) -> (backtick: Bool, length: Int)? {
        let parts = frame.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "f",
              let length = Int(parts[2]) else { return nil }
        return (parts[1] == "b", length)
    }

    static func heredocParts(_ frame: String) -> (quoted: Bool, delimiter: String)? {
        guard frame.hasPrefix("h:"), frame.count >= 4 else { return nil }
        let rest = frame.dropFirst(2)
        guard let sep = rest.first, sep == "0" || sep == "1",
              rest.dropFirst().first == ":" else { return nil }
        return (sep == "1", String(rest.dropFirst(2)))
    }
}
