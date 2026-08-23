import Foundation

/// Everything a session factory needs to spawn one terminal. The registry mints the
/// identities before spawning so the factory can inject them into the child's
/// environment (`ORCHARD_TERMINAL_HANDLE` / `ORCHARD_PANE_KEY` / …) — that injection is
/// how an agent inside the PTY later finds itself in `orchard` CLI calls.
public struct TerminalCreateSpec: Sendable {
    public let handle: String
    public let paneKey: String
    public let worktreeId: String?
    public let cwd: String?
    public let engineID: String
    /// The task prompt. `.launchArgument` engines burn it into argv; `.typeWhenIdle`
    /// engines get it typed via the injection pipeline on first idle.
    public let prompt: String
    public let title: String?
    /// PTY spawn geometry when the creator already knows the pane size (a visible app
    /// pane, a respawn into a sized pane). nil means the factory falls back to
    /// `TerminalSpawnDefaults` — never to the historical 80×24, which every real
    /// consumer immediately reflowed away from.
    public let initialCols: Int?
    public let initialRows: Int?

    public init(handle: String, paneKey: String, worktreeId: String?, cwd: String?,
                engineID: String, prompt: String, title: String?,
                initialCols: Int? = nil, initialRows: Int? = nil) {
        self.handle = handle
        self.paneKey = paneKey
        self.worktreeId = worktreeId
        self.cwd = cwd
        self.engineID = engineID
        self.prompt = prompt
        self.title = title
        self.initialCols = initialCols
        self.initialRows = initialRows
    }
}

/// Fallback PTY spawn geometry when no pane geometry is known yet (headless RPC
/// creates, the first terminal after app launch). Roomy enough that agent TUIs lay
/// out their real chrome on first paint; a view that attaches later still resizes
/// the session to the actual pane.
public enum TerminalSpawnDefaults {
    public static let cols = 120
    public static let rows = 34
}

/// How new PTYs come to exist — the seam between the registry (identity, lifecycle)
/// and the terminal engine (process). Production installs `DamsonTerminalFactory`;
/// tests install a factory returning `ScriptedTerminalSession`s.
public typealias TerminalSessionFactory = @MainActor (TerminalCreateSpec, AgentEngine) throws -> TerminalSession

/// `RuntimeTerminalSummary`-shaped listing row. Timestamps are ms epoch.
public struct TerminalSummary: Codable, Equatable, Sendable {
    public let handle: String
    public let paneKey: String
    /// PTY respawn counter for this pane (starts at 1; a respawn increments it).
    public let incarnation: Int
    public let worktreeId: String?
    public let title: String?
    public let engine: String
    /// Whether the child process is still attached and running.
    public let connected: Bool
    public let writable: Bool
    public let lastOutputAt: Double?
    /// Newest non-blank stream line, for card/list previews.
    public let preview: String
    /// The runtime agent-state projection (`nil` = no live agent).
    public let agentState: AgentRuntimeProjection?
}

/// `terminal read` result. `source` says which question was answered: `stream` is the
/// accumulated output ring (what happened), `screen` is the rendered grid (what is
/// shown), and `screen-unavailable` means a screen was requested but none could be
/// rendered so the stream came back instead.
public struct TerminalReadResult: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case stream
        case screen
        case screenUnavailable = "screen-unavailable"
    }

    public let handle: String
    public let status: String            // "running" | "exited"
    public let lines: [String]
    public let source: Source
    /// Stream paging (nil for screen reads — a screen has no cursor).
    public let oldestCursor: Int?
    public let nextCursor: Int?
    public let latestCursor: Int?
    public let truncated: Bool
    public let returnedLineCount: Int
}

/// `terminal send` result. A refusal is a *typed answer*, not an error: the write was
/// declined for a reason the caller must branch on (`no-agent`: nothing lives there to
/// receive an agent prompt; `permission`: the agent is parked on an approval and typing
/// into it would corrupt the pending decision).
public struct TerminalSendResult: Codable, Equatable, Sendable {
    public enum RefusedReason: String, Codable, Sendable {
        case noAgent = "no-agent"
        case permission
    }

    public let handle: String
    public let accepted: Bool
    public let bytesWritten: Int
    public let refusedReason: RefusedReason?

    public static func delivered(handle: String, bytesWritten: Int) -> TerminalSendResult {
        TerminalSendResult(handle: handle, accepted: true, bytesWritten: bytesWritten,
                           refusedReason: nil)
    }

    public static func refused(handle: String, reason: RefusedReason) -> TerminalSendResult {
        TerminalSendResult(handle: handle, accepted: false, bytesWritten: 0,
                           refusedReason: reason)
    }
}

/// What `terminal wait` can wait for.
public enum TerminalWaitCondition: String, Codable, Sendable {
    /// The agent TUI settled at its input box. Only `idle` satisfies this —
    /// `permission` does not.
    case tuiIdle = "tui-idle"
    /// The PTY child exited.
    case exit
}

/// `terminal wait` result. A timeout is a checkpoint, not a failure: `satisfied:
/// false, timedOut: true` with the last known state, so a coordinator can decide to
/// keep waiting or look closer.
public struct TerminalWaitResult: Codable, Equatable, Sendable {
    public let handle: String
    public let condition: TerminalWaitCondition
    public let satisfied: Bool
    public let timedOut: Bool
    public let agentState: AgentRuntimeProjection?
    public let exitCode: Int32?
}

/// One pane's PTY ending, reported through `TerminalService.onTerminalExit` (T11).
/// `deliberate` distinguishes a close that went through the service (user close,
/// coordinator worker-stop/release) from the child process dying on its own — the
/// orchestration layer escalates only the latter.
public struct TerminalExitEvent: Sendable {
    public let handle: String
    public let paneKey: String
    public let exitCode: Int32?
    public let deliberate: Bool

    public init(handle: String, paneKey: String, exitCode: Int32?, deliberate: Bool) {
        self.handle = handle
        self.paneKey = paneKey
        self.exitCode = exitCode
        self.deliberate = deliberate
    }
}

/// Typed terminal-service failures; `code` is the machine-readable RPC error code.
public enum TerminalServiceError: Error, Equatable, Sendable {
    /// The handle was never issued (or its terminal was closed).
    case notFound(handle: String)
    /// The handle was superseded by a remint. `replacement` is the live handle for the
    /// same pane — callers must re-list and use only the replacement, never dual-send.
    case handleStale(handle: String, replacement: String?)
    /// The PTY child already exited; there is no process to receive input.
    case exited(handle: String)
    case unknownEngine(String)
    case spawnFailed(String)
    /// The verified injection pipeline typed a prompt but the agent never left idle —
    /// the submission plausibly did not take.
    case promptStalled(handle: String)
    /// The agent moved to a permission prompt mid-injection; the submission is parked
    /// behind a human decision.
    case promptBlocked(handle: String)
    case invalidArgument(String)
    case notImplemented(String)

    public var code: String {
        switch self {
        case .notFound: return "terminal_not_found"
        case .handleStale: return "terminal_handle_stale"
        case .exited: return "terminal_exited"
        case .unknownEngine: return "unknown_engine"
        case .spawnFailed: return "terminal_spawn_failed"
        case .promptStalled: return "agent_prompt_stalled"
        case .promptBlocked: return "agent_prompt_blocked"
        case .invalidArgument: return "invalid_argument"
        case .notImplemented: return "not_implemented"
        }
    }

    public var message: String {
        switch self {
        case .notFound(let h): return "no terminal for handle '\(h)'"
        case .handleStale(let h, let r):
            return "handle '\(h)' was reminted" + (r.map { " — use '\($0)'" } ?? "")
        case .exited(let h): return "terminal '\(h)' process has exited"
        case .unknownEngine(let id): return "unknown engine: \(id)"
        case .spawnFailed(let why): return "terminal spawn failed: \(why)"
        case .promptStalled(let h): return "agent in '\(h)' never left idle after prompt submission"
        case .promptBlocked(let h): return "agent in '\(h)' hit a permission prompt during injection"
        case .invalidArgument(let why): return why
        case .notImplemented(let what): return "\(what) is not implemented yet"
        }
    }
}
