import Foundation
import Combine
import DamsonTerminal

/// The exact terminal surface the agent layer consumes — extracted from v1's direct
/// `DamsonSession` usage (~11 members) so `AgentSession` and the readiness stack can be
/// driven by a fake in tests, and so exactly one type (`DamsonTerminalSession`) touches
/// the engine. Everything here mirrors a `DamsonSession` capability 1:1.
///
/// Main-actor bound: damson's session/grid are mutated on the main thread by contract,
/// and the agent layer's timers and Combine subscriptions already live there.
@MainActor
public protocol TerminalSession: AnyObject {
    /// Programmatic input (queued, never dropped).
    func write(_ data: Data)

    /// A point-in-time view of the rendered screen — the input to readiness detection.
    func gridSnapshot() -> TerminalGridSnapshot

    /// The session's current configuration (argv/cwd/env/presentation).
    var config: DamsonConfig { get }
    /// Live-update the configuration (presentation fields; the process is untouched).
    func updateConfig(_ config: DamsonConfig)

    /// Terminate the underlying process.
    func terminate()

    /// Whether the child process has exited, and with what code (nil while running).
    var processExited: Bool { get }
    var exitCode: Int32? { get }

    /// Whether the child enabled bracketed paste (drives prompt-delivery framing).
    var bracketedPasteEnabled: Bool { get }

    /// Whether a foreground job other than the shell is running (PTY `tcgetpgrp`).
    var hasRunningForegroundJob: Bool { get }

    /// Fires on every grid mutation (redraw signal). Multi-subscriber.
    var gridChanged: AnyPublisher<Void, Never> { get }

    /// Parsed output events the agent layer cares about (currently OSC sequences for the
    /// Tier-2 agent-status escape, and text for future consumers). Multi-subscriber.
    var outputEvents: AnyPublisher<TerminalOutputEvent, Never> { get }

    /// Called once when the child process exits. Single-assignment.
    var onExit: ((Int32) -> Void)? { get set }
}

/// An immutable view of the visible grid at one instant. Rows come pre-trimmed of
/// trailing blanks (what every consumer wanted anyway); building it is O(rows × cols),
/// the same cost v1 paid per evaluation.
public struct TerminalGridSnapshot: Sendable {
    /// Visible grid rows as plain text, top to bottom (trailing blanks trimmed per row).
    public let lines: [String]
    public let cursorRow: Int
    public let cursorCol: Int
    public let cols: Int
    public let rows: Int
    public let isAltScreen: Bool
    /// Whether the screen is currently inside a DECSET-2026 synchronized-output frame.
    public let inSyncOutputMode: Bool

    public init(lines: [String], cursorRow: Int, cursorCol: Int, cols: Int, rows: Int,
                isAltScreen: Bool, inSyncOutputMode: Bool) {
        self.lines = lines
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cols = cols
        self.rows = rows
        self.isAltScreen = isAltScreen
        self.inSyncOutputMode = inSyncOutputMode
    }
}

/// The engine-agnostic subset of parsed terminal output the agent layer consumes.
/// Deliberately smaller than damson's `DamsonOutputEvent` (no CSI/execute cases): the
/// agent layer reads semantic signals, not the render stream. T3 extends this as the
/// terminal service grows a real read pipeline.
public enum TerminalOutputEvent: Sendable {
    /// Plain printed text.
    case text(String)
    /// A parsed OSC sequence's parameters (e.g. `["9999", "{...}"]` for agent status).
    case osc([String])
}
