import Foundation
import OrchardCore

/// First-class engine for Anthropic's `claude` CLI (Claude Code).
///
/// Claude Code is a long-running full-screen TUI: it never returns to a shell prompt
/// between turns, so `isRunningForegroundJob` stays permanently true and OSC 133 never
/// fires. Readiness therefore MUST be read from the rendered screen — see
/// `ClaudeFingerprints` for the (version-sensitive) string/layout matchers.
public struct ClaudeCodeEngine: AgentEngine {
    public init() {}

    public var id: String { "claude-code" }
    public var displayName: String { "Claude Code" }
    public var agentType: String { "claude" }
    public var usesLongRunningTUI: Bool { true }
    public var promptDelivery: PromptDelivery { .typeWhenIdle }

    /// Resolved absolute path to the `claude` binary (GUI launch has a minimal PATH,
    /// so we search common install locations rather than trusting PATH).
    public var executablePath: String {
        let candidates = [
            "\(NSHomeDirectory())/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "claude" // last resort; relies on login-shell PATH
    }

    public func launchArgv(task: AgentTask, worktree: URL) -> [String] {
        // Interactive session; the prompt is typed in once idle (.typeWhenIdle).
        [executablePath]
    }

    /// Environment variables that mark a process as living *inside* an existing Claude Code
    /// session. They must not reach a spawned agent.
    ///
    /// Orchard is frequently launched from a terminal that is itself running Claude Code, and
    /// these markers are inherited straight through. The child then believes it is a
    /// subprocess of that session and changes behavior — most visibly by disabling transcript
    /// saving ("Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker"). Each
    /// agent Orchard starts is a genuinely independent top-level session, so the slate is
    /// wiped rather than inherited.
    static let inheritedSessionMarkers = [
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_SESSION_ID",
    ]

    public func env(base: [String: String]) -> [String: String] {
        var env = base
        for key in Self.inheritedSessionMarkers { env.removeValue(forKey: key) }
        return env
    }

    /// Remote launch: the bare command name, resolved by the *remote* login shell, with
    /// the same marker set stripped on the far side. `executablePath` deliberately does
    /// not travel — it is a path on this machine.
    public var remoteLaunch: RemoteEngineLaunch? {
        RemoteEngineLaunch(command: "claude",
                           strippedEnvironment: Self.inheritedSessionMarkers)
    }

    public func classify(_ snapshot: ReadinessSnapshot) -> AgentRuntimeState? {
        ClaudeFingerprints.classify(snapshot)
    }

    /// Auto-clear ONLY Claude Code's startup "trust this folder" gate — it appears for every
    /// fresh worktree and is safe to confirm because the worktree is a copy of the repo the
    /// user explicitly chose. Real mid-task approval prompts return nil here so a human must
    /// decide. Pressing Enter accepts the default highlighted "1. Yes, I trust this folder".
    public func autoResponseKeys(_ snapshot: ReadinessSnapshot) -> [String]? {
        ClaudeFingerprints.isTrustPrompt(snapshot.bottomLines(12)) ? ["enter"] : nil
    }

    // MARK: - Tier-1 lifecycle hooks

    /// Claude Code lifecycle events Orchard registers as `command` hooks (each POSTs the
    /// event to the loopback hook server). Kept to the well-documented, stable set:
    /// prompt submit + tool activity (→ working), Notification (→ approval/idle), Stop
    /// (→ turn done), SessionEnd (→ shutdown; process exit is the real authority).
    public var hookEvents: [String]? {
        ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    }

    public func hookSignal(event: String, body: Data) -> AgentRuntimeState? {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            // The agent is mid-turn: it submitted a prompt or is running tools.
            return .working
        case "Stop":
            // The main agent finished responding → back at its input box, ready.
            return .idle
        case "Notification":
            // Notification means Claude wants attention. Distinguish "needs permission /
            // approval" (blocked on the human) from "waiting for your input" (idle) by the
            // payload text, since the exact discriminator field varies across releases.
            let text = String(decoding: body, as: UTF8.self).lowercased()
            if text.contains("permission") || text.contains("approve") || text.contains("proceed") {
                return .awaitingApproval
            }
            if text.contains("waiting for your input") || text.contains("idle") {
                return .idle
            }
            return nil   // unknown notification — don't disturb the current state
        case "SessionEnd":
            return nil    // process exit (onExit) is authoritative for termination
        default:
            return nil
        }
    }
}

/// Version-sensitive fingerprints for Claude Code's TUI. **These are a maintained
/// fingerprint set, NOT a stable protocol** — Claude Code's on-screen strings change
/// across releases. When a new version breaks detection, record a session with
/// `DAMSON_DUMP_OUTPUT`, add it to the replay tests, and update the matchers here.
/// Keeping every matcher in this one file is intentional so drift is easy to fix.
enum ClaudeFingerprints {
    /// Glyphs Claude Code rotates through on its "working" spinner line.
    static let spinnerGlyphs: Set<Character> = ["✶", "✻", "✽", "✢", "·", "*", "✳", "✺", "✱"]

    /// Gerunds Claude Code shows while working (e.g. "✻ Thinking… (12s · esc to interrupt)").
    static let workingWords = [
        "Thinking", "Working", "Forging", "Cogitating", "Pondering",
        "Crafting", "Computing", "Reticulating", "Processing", "Generating",
        "Analyzing", "Synthesizing", "Brewing", "Conjuring", "Deliberating",
    ]

    /// Decisive classifier. Precedence: terminal > approval > working > idle.
    /// Returns nil when uncertain so the detector holds the prior state.
    static func classify(_ snap: ReadinessSnapshot) -> AgentRuntimeState? {
        let bottom = snap.bottomLines(8)

        // 1. Approval / choice prompt MUST win over idle — dispatching here is corrupting.
        if isApprovalPrompt(bottom) {
            return .awaitingApproval
        }

        // 2. Working: spinner present, or a sync frame within the cadence window while
        //    the input box is absent.
        if isWorking(bottom) {
            return .working
        }
        if snap.timeSinceLastSyncFrame < 1.5 && !hasInputBox(bottom) {
            return .working
        }

        // 3. Idle: input box visible AND output has gone quiescent AND no recent frame.
        if hasInputBox(bottom),
           snap.timeSinceLastData > 0.6,
           snap.timeSinceLastSyncFrame > 1.5 {
            return .idle
        }

        // Uncertain — let the detector keep the current state.
        return nil
    }

    /// The bottom-of-screen free-text input affordance, e.g. a bordered "│ > " box.
    static func hasInputBox(_ lines: [String]) -> Bool {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            // Box-drawn prompt row: starts with a vertical border and a ">" affordance.
            if (t.hasPrefix("│") || t.hasPrefix("┃") || t.hasPrefix(">")) && t.contains(">") {
                return true
            }
            // Hint line Claude draws beneath the box when idle.
            if t.contains("? for shortcuts") || t.contains("for shortcuts") {
                return true
            }
        }
        return false
    }

    /// A spinner/working line.
    static func isWorking(_ lines: [String]) -> Bool {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let first = t.first else { continue }
            // Spinner glyph + an elapsed timer in parens like "(12s".
            if spinnerGlyphs.contains(first), containsElapsedTimer(t) {
                return true
            }
            // Gerund + ellipsis ("Thinking…") possibly preceded by a spinner glyph.
            for word in workingWords where t.contains(word) {
                if t.contains("…") || t.contains("...") || containsElapsedTimer(t) {
                    return true
                }
            }
            // Explicit interrupt hint shown only while a turn runs.
            if t.contains("esc to interrupt") || t.contains("to interrupt") {
                return true
            }
        }
        return false
    }

    /// The startup workspace-trust gate, shown for every fresh directory. Distinct from a
    /// mid-task approval so the orchestrator can auto-clear it (the worktree is the user's
    /// own repo) without auto-answering real task approvals.
    static func isTrustPrompt(_ lines: [String]) -> Bool {
        for line in lines {
            if line.contains("trust this folder")
                || line.contains("Do you trust")
                || line.contains("Quick safety check")
                || line.contains("Accessing workspace") {
                return true
            }
        }
        return false
    }

    /// A numbered approval/choice prompt ("❯ 1. Yes", "2. No, …") or the proceed framing.
    static func isApprovalPrompt(_ lines: [String]) -> Bool {
        if lines.contains(where: { $0.contains("Do you want to proceed") }) {
            return true
        }
        var numbered = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if matchesNumberedOption(t) { numbered += 1 }
        }
        return numbered >= 2
    }

    /// "(12s", "(3s ·", etc. — an elapsed-seconds timer.
    static func containsElapsedTimer(_ s: String) -> Bool {
        guard let open = s.firstIndex(of: "(") else { return false }
        var idx = s.index(after: open)
        var sawDigit = false
        while idx < s.endIndex, s[idx].isNumber { sawDigit = true; idx = s.index(after: idx) }
        return sawDigit && idx < s.endIndex && s[idx] == "s"
    }

    /// Matches a selectable option row: optional "❯"/">" cursor, then "1." / "2)" etc.
    static func matchesNumberedOption(_ t: String) -> Bool {
        var s = Substring(t)
        if let first = s.first, first == "❯" || first == ">" || first == "▶" {
            s = s.dropFirst()
            s = s.drop { $0 == " " }
        }
        var digits = 0
        while let c = s.first, c.isNumber { digits += 1; s = s.dropFirst() }
        guard digits >= 1, let sep = s.first, sep == "." || sep == ")" else { return false }
        s = s.dropFirst()
        return s.first == " " || s.isEmpty
    }
}
