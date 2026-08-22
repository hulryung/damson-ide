import Foundation
import OrchardCore

/// Engines for the non-Claude CLI agents Orchard can drive (Orca parity: `@codex`,
/// `@grok`, `@cursor` fleets). All three are long-running full-screen TUIs launched
/// bare and fed their prompt by typing once idle — exactly Claude's shape minus the
/// maintained screen fingerprints: none of them ships a fingerprint set yet, so their
/// turn state comes from Tier-1 hooks / Tier-2 OSC when available and otherwise holds
/// (`classify` returns nil). That is deliberate — the checklist forbids inferring turn
/// completion from silence, and a wrong `idle` dispatches into a working agent.

/// Resolves an agent CLI binary the way `ClaudeCodeEngine.executablePath` does: probe
/// the common install locations first because a GUI launch has a minimal PATH, then
/// fall back to the bare name for the login-shell wrap to resolve.
enum ExecutableLocator {
    static func find(_ name: String, extraCandidates: [String] = []) -> String {
        var candidates = extraCandidates
        candidates += [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return name
    }
}

/// OpenAI's `codex` CLI.
public struct CodexEngine: AgentEngine {
    public init() {}

    public var id: String { "codex" }
    public var displayName: String { "Codex" }
    public var usesLongRunningTUI: Bool { true }
    public var promptDelivery: PromptDelivery { .typeWhenIdle }

    public var executablePath: String {
        ExecutableLocator.find("codex", extraCandidates: ["\(NSHomeDirectory())/.codex/bin/codex"])
    }

    public func launchArgv(task: AgentTask, worktree: URL) -> [String] {
        [executablePath]
    }
}

/// xAI's `grok` CLI.
public struct GrokEngine: AgentEngine {
    public init() {}

    public var id: String { "grok" }
    public var displayName: String { "Grok" }
    public var usesLongRunningTUI: Bool { true }
    public var promptDelivery: PromptDelivery { .typeWhenIdle }

    public var executablePath: String {
        ExecutableLocator.find("grok")
    }

    public func launchArgv(task: AgentTask, worktree: URL) -> [String] {
        [executablePath]
    }
}

/// Cursor's `cursor-agent` CLI.
public struct CursorAgentEngine: AgentEngine {
    public init() {}

    public var id: String { "cursor-agent" }
    public var displayName: String { "Cursor Agent" }
    public var agentType: String { "cursor" }
    public var usesLongRunningTUI: Bool { true }
    public var promptDelivery: PromptDelivery { .typeWhenIdle }

    public var executablePath: String {
        ExecutableLocator.find("cursor-agent")
    }

    public func launchArgv(task: AgentTask, worktree: URL) -> [String] {
        [executablePath]
    }
}
