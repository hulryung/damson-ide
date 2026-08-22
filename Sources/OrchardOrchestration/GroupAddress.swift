import Foundation

/// The slice of terminal state group resolution needs. The terminal service (T3) owns the
/// real registry; the orchestration layer only ever sees this projection, keeping the
/// module free of damson imports.
public struct TerminalDirectoryEntry: Sendable, Equatable {
    public let handle: String
    public let title: String?
    public let worktreeID: String?

    public init(handle: String, title: String? = nil, worktreeID: String? = nil) {
        self.handle = handle
        self.title = title
        self.worktreeID = worktreeID
    }
}

/// Group addresses: broadcast to logical groups of agents, resolved AT SEND TIME to one
/// message row per recipient sharing a thread_id, so each recipient gets independent
/// read-tracking (docs/research/orca-inventory.md §1.4). Ported from
/// ~/dev/orca/src/main/runtime/orchestration/groups.ts.
public enum GroupAddress {
    /// Agent-name groups (`@claude`, `@codex`, …) match members by terminal title.
    public static let agentNameGroups: [String] = [
        "claude", "openclaude", "codex", "opencode", "mimo", "gemini", "droid", "grok", "cursor",
    ]

    public static func isGroupAddress(_ to: String) -> Bool {
        to.hasPrefix("@")
    }

    /// Resolve a group address to member handles; a non-group address resolves to itself.
    /// Unknown groups resolve to empty rather than throwing, so callers can distinguish
    /// "valid group, no current members" from programming errors.
    public static func resolve(
        _ to: String,
        senderHandle: String,
        terminals: [TerminalDirectoryEntry],
        agentStatus: (String) -> String? = { _ in nil }
    ) -> [String] {
        guard isGroupAddress(to) else { return [to] }
        let group = to.lowercased()

        // @all broadcasts to every terminal except the sender — no self-delivery loops.
        if group == "@all" {
            return terminals.map(\.handle).filter { $0 != senderHandle }
        }

        // @idle targets only agents whose TUI reports idle — dispatch to available
        // agents without interrupting busy ones.
        if group == "@idle" {
            return terminals
                .filter { $0.handle != senderHandle && agentStatus($0.handle) == "idle" }
                .map(\.handle)
        }

        if group.hasPrefix("@worktree:") {
            let worktreeID = String(to.dropFirst("@worktree:".count))
            return terminals
                .filter { $0.handle != senderHandle && $0.worktreeID == worktreeID }
                .map(\.handle)
        }

        let agentName = String(group.dropFirst())
        if agentNameGroups.contains(agentName) {
            return terminals
                .filter { $0.handle != senderHandle && titleMatches(agentName: agentName, title: $0.title ?? "") }
                .map(\.handle)
        }

        return []
    }

    /// Whole-token title match (`grok`, `grok.exe`), case-insensitive. `cursor` is also
    /// ordinary vocabulary in another agent's task-summary title ("fix the text cursor
    /// blink"), so it gets an identity predicate instead of token matching — mirroring
    /// orca's GROUP_TITLE_MATCHERS special case.
    static func titleMatches(agentName: String, title: String) -> Bool {
        if agentName == "cursor" {
            let lowered = title.lowercased()
            return lowered == "cursor" || tokenMatch(name: "cursor-agent", in: lowered)
        }
        return tokenMatch(name: agentName, in: title.lowercased())
    }

    private static func tokenMatch(name: String, in title: String) -> Bool {
        let pattern = "(?<![a-z0-9])\(NSRegularExpression.escapedPattern(for: name))(\\.exe)?(?![a-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, range: range) != nil
    }
}
