import Foundation

/// Everything a session factory needs to spawn one terminal. The registry mints the
/// identities before spawning so the factory can inject them (`ORCHARD_TERMINAL_HANDLE`
/// / `ORCHARD_PANE_KEY` / …) — locally into the child's environment, and for a remote
/// pane into the `ssh` remote command line, because ssh does not forward those
/// variables. That is how an agent inside the PTY later finds itself in `orchard`
/// CLI calls.
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
    /// Which host the work in this pane runs on — `local` or `ssh:<name>` (T29). The
    /// PTY itself is always local; for a remote host its child is the `ssh` client, so
    /// this records *where the work is*, which is not the same question as where the
    /// process table entry is. Kept as the raw id string so this module stays free of
    /// the runtime's host registry.
    public let executionHostId: String
    /// PTY spawn geometry when the creator already knows the pane size (a visible app
    /// pane, a respawn into a sized pane). nil means the factory falls back to
    /// `TerminalSpawnDefaults` — never to the historical 80×24, which every real
    /// consumer immediately reflowed away from.
    public let initialCols: Int?
    public let initialRows: Int?
    /// Verbatim argv for this pane's PTY child, bypassing the engine's own
    /// `launchArgv`. Set only where the engine cannot describe its own launch: a
    /// remote agent pane runs `ssh -tt … <agent>` locally while *being* a Claude Code
    /// pane for readiness, sends and status (T39). nil — the normal case — means the
    /// factory builds argv from the engine as always.
    public let launchArgv: [String]?
    /// Pre-minted lifecycle-hook token, so a hook config can be written *before* the
    /// PTY exists. A remote agent's config has to be on the far side before the agent
    /// reads it at startup, which is strictly earlier than the pane's `AgentSession`
    /// would mint one. nil mints per session, as before.
    public let hookToken: String?
    /// What this pane's agent status can actually be read from, when that differs from
    /// the default for its engine. nil = the default; see `TerminalStatusDetection`.
    public let statusDetection: TerminalStatusDetection?
    /// Where the work happens on the far side, for a pane whose host is not `local`
    /// (T43). Deliberately separate from `cwd`, which is where the *local* `ssh` is
    /// launched from: handing a remote path to a local `chdir` either fails or finds a
    /// same-named local directory. Recorded so a restored or reconnected pane can say
    /// which directory on which machine it belongs to without re-parsing its argv.
    public let remoteCwd: String?
    /// The name this pane's process answers to *on the far side* (T89).
    ///
    /// A remote pane's PTY child is `ssh`, so nothing local can say whether the remote
    /// process is running. The launch writes a small identity record on the host under
    /// this token; asking the host about that token is the only thing that has ever
    /// been entitled to answer `live`. nil — a pane opened before this existed, or on a
    /// host where the record could not be written — means its liveness stays
    /// `unverifiable`, which is the correct answer and not a failure.
    public let remoteIdentityToken: String?
    /// The durable-connection generation this pane was launched under, as its label
    /// (`build#3.7a1c9f02`). Recorded so a reconnect can say *which* span of contact
    /// ended rather than implying the new one continues it. nil when the pane's host
    /// had no durable connection.
    public let remoteGeneration: String?

    public init(handle: String, paneKey: String, worktreeId: String?, cwd: String?,
                engineID: String, prompt: String, title: String?,
                executionHostId: String = "local",
                initialCols: Int? = nil, initialRows: Int? = nil,
                launchArgv: [String]? = nil, hookToken: String? = nil,
                statusDetection: TerminalStatusDetection? = nil,
                remoteCwd: String? = nil,
                remoteIdentityToken: String? = nil,
                remoteGeneration: String? = nil) {
        self.handle = handle
        self.paneKey = paneKey
        self.worktreeId = worktreeId
        self.cwd = cwd
        self.engineID = engineID
        self.prompt = prompt
        self.title = title
        self.executionHostId = executionHostId
        self.initialCols = initialCols
        self.initialRows = initialRows
        self.launchArgv = launchArgv
        self.hookToken = hookToken
        self.statusDetection = statusDetection
        self.remoteCwd = remoteCwd
        self.remoteIdentityToken = remoteIdentityToken
        self.remoteGeneration = remoteGeneration
    }

    /// Whether this pane's work runs on another machine. The raw id is compared
    /// against `local` rather than parsed here: this module deliberately knows nothing
    /// about the host registry, and every id that is not the literal `local` names a
    /// host — including one this build cannot parse, which must never read as local.
    public var isRemote: Bool { executionHostId != "local" }
}

/// What a runtime surface needs in order to ask a host about one remote pane.
///
/// Read off the pane's recorded spec rather than re-derived from its argv: a pane that
/// was restored or reconnected still carries the identity it was launched with, and
/// re-parsing a command line is how the wrong machine gets asked.
public struct RemotePaneFacts: Sendable, Equatable {
    public let paneKey: String
    public let handle: String
    public let incarnation: Int
    /// `ssh:<name>`; never `local` (a local pane has no facts here).
    public let executionHostId: String
    public let remoteCwd: String?
    public let identityToken: String?
    /// The connection generation recorded at launch, as its label.
    public let generation: String?
    public let connected: Bool

    public init(paneKey: String, handle: String, incarnation: Int, executionHostId: String,
                remoteCwd: String?, identityToken: String?, generation: String?,
                connected: Bool) {
        self.paneKey = paneKey
        self.handle = handle
        self.incarnation = incarnation
        self.executionHostId = executionHostId
        self.remoteCwd = remoteCwd
        self.identityToken = identityToken
        self.generation = generation
        self.connected = connected
    }
}

/// Where one pane's agent status comes from, and what it therefore cannot report.
///
/// Local agent panes read status from two tiers at once: lifecycle hooks the CLI POSTs
/// to a loopback server (structured, authoritative) and screen fingerprints (a
/// maintained guess). A remote agent pane only gets the first tier if an SSH reverse
/// tunnel carries the hook channel back, and tunnels fail for ordinary reasons — a
/// sshd with `AllowTcpForwarding no`, every candidate port taken, a config write that
/// could not reach the host.
///
/// When that happens the pane still runs; it just knows less. This type is how it says
/// so, instead of presenting a fingerprint-only guess with the same confidence as a
/// hook-attested fact. `limitation` is one sentence, already written for a human.
public struct TerminalStatusDetection: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Lifecycle hooks reach us; fingerprints still back them up.
        case hooks
        /// Screen fingerprints only — no hook channel to this agent.
        case fingerprintOnly = "fingerprint-only"
    }

    public let mode: Mode
    /// The remote listen port of the reverse tunnel carrying the hook channel, when
    /// one does. Recorded so an operator can see (and, on the host, verify) it.
    public let tunnelPort: Int?
    /// What this pane cannot report, and why. nil when nothing is lost.
    public let limitation: String?

    public init(mode: Mode, tunnelPort: Int? = nil, limitation: String? = nil) {
        self.mode = mode
        self.tunnelPort = tunnelPort
        self.limitation = limitation
    }

    public static func hooks(tunnelPort: Int? = nil) -> TerminalStatusDetection {
        TerminalStatusDetection(mode: .hooks, tunnelPort: tunnelPort, limitation: nil)
    }

    public static func fingerprintOnly(_ limitation: String) -> TerminalStatusDetection {
        TerminalStatusDetection(mode: .fingerprintOnly, tunnelPort: nil,
                                limitation: limitation)
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
    /// `local` or `ssh:<name>` — the host this pane's work runs on (T29). Stamped at
    /// create time and never inferred later: a summary that lost its host would read as
    /// local, and local is the one answer that must never be guessed.
    public let executionHostId: String
    /// Whether the child process is still attached and running.
    public let connected: Bool
    public let writable: Bool
    public let lastOutputAt: Double?
    /// Newest non-blank stream line, for card/list previews.
    public let preview: String
    /// The runtime agent-state projection (`nil` = no live agent).
    public let agentState: AgentRuntimeProjection?
    /// Present when this pane's status detection differs from the default for its
    /// engine — today, a remote agent pane whose hook tunnel could not be established
    /// (T39). Carries the limitation in words, so a coordinator reading the summary
    /// learns what the pane cannot tell it before it trusts an `idle`.
    public let statusDetection: TerminalStatusDetection?
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
    /// The pane's host (T29). Carried on the event because an exit code means
    /// different things on different hosts: locally it is the process's own status,
    /// while on `ssh:<name>` it may be the *connection* failing, which proves nothing
    /// about the remote work. Consumers read it through `HostLiveness.verdictForPTYEnd`.
    public let executionHostId: String

    public init(handle: String, paneKey: String, exitCode: Int32?, deliberate: Bool,
                executionHostId: String = "local") {
        self.handle = handle
        self.paneKey = paneKey
        self.exitCode = exitCode
        self.deliberate = deliberate
        self.executionHostId = executionHostId
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
