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

    /// Raw pre-parse PTY bytes, multi-subscriber. Fires once per output chunk — including
    /// repaint-only chunks (pure CSI) that produce no `outputEvents` — so it is the
    /// truthful "the child wrote something" signal. Subscribing here never contends with
    /// damson's single-assignment `onOutput` closure, which stays unclaimed.
    var outputBytes: AnyPublisher<Data, Never> { get }

    /// Called once when the child process exits. Single-assignment.
    var onExit: ((Int32) -> Void)? { get set }

    // MARK: - Restart survival (T23 keeper handoff)

    /// Detach the underlying PTY from this session WITHOUT killing the child, for
    /// handoff to the keeper across an app restart. nil when there is nothing
    /// sensible to hand off (process-free test sessions; damson also refuses
    /// tmux-backed panes). Defaulted so existing conformances are untouched.
    func releaseForKeeperHandoff() -> KeeperPTYHandoff?

    /// The escape bytes that recreate this session's tracked terminal state in a
    /// fresh parser — replayed into the adopting session before any buffered/live
    /// output. Empty by default.
    func keeperRestorationPreamble() -> Data

    // MARK: - Capture (T54 frame capture)

    /// Lines that scrolled off the top of the screen and are still held in scrollback,
    /// as plain text, for absolute rows `fromAbsoluteRow ..< gridSnapshot().firstRowIndex`.
    /// The LAST element is always the row just above the current screen (absolute row
    /// `firstRowIndex - 1`); the list is shorter than asked only when its oldest rows
    /// were already evicted from scrollback. Engines without scrollback return `[]`.
    func scrolledOffLines(fromAbsoluteRow: Int) -> [String]
}

public extension TerminalSession {
    func releaseForKeeperHandoff() -> KeeperPTYHandoff? { nil }
    func keeperRestorationPreamble() -> Data { Data() }
    func scrolledOffLines(fromAbsoluteRow: Int) -> [String] { [] }
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
    /// Absolute index of `lines[0]` in the session's line history: how many rows have
    /// scrolled off the top of this screen so far. Lets two snapshots taken across a
    /// scroll be aligned row-for-row (`firstRowIndex + r` names the same row in both),
    /// which is what frame capture diffs on. Engines that don't track scrolling leave
    /// it 0; the alt screen counts from 0 on entry (damson resets it there).
    public let firstRowIndex: Int

    public init(lines: [String], cursorRow: Int, cursorCol: Int, cols: Int, rows: Int,
                isAltScreen: Bool, inSyncOutputMode: Bool, firstRowIndex: Int = 0) {
        self.lines = lines
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cols = cols
        self.rows = rows
        self.isAltScreen = isAltScreen
        self.inSyncOutputMode = inSyncOutputMode
        self.firstRowIndex = firstRowIndex
    }
}

/// The engine-agnostic subset of parsed terminal output the agent layer consumes:
/// semantic signals (OSC) plus the text stream and the control sequences that decide
/// how that text should be captured. Text and C0 controls assemble lines for a program
/// that *prints*; a CSI that moves the cursor, erases, or scrolls says the program is
/// *painting* a grid instead, and the burst's text is then a set of cell writes rather
/// than lines — `TerminalCaptureCollector` captures such a burst from the rendered
/// frame. (Before T54 the CSI case was dropped at the seam, which is how a
/// cursor-addressed TUI's repaint reached the stream as collapsed and torn fragments.)
public enum TerminalOutputEvent: Sendable {
    /// Plain printed text.
    case text(String)
    /// A C0 control byte (LF/CR/TAB/BS…) — the line-structure signal the accumulated
    /// text stream needs; everything else about it is ignored.
    case control(UInt8)
    /// A parsed OSC sequence's parameters (e.g. `["9999", "{...}"]` for agent status).
    case osc([String])
    /// A parsed CSI sequence. Only its paint/print classification is consumed
    /// (`TerminalControlSequence.isPaint`); the sequence has already been applied to
    /// the engine's grid by the time it arrives here.
    case csi(TerminalControlSequence)
}

/// One parsed CSI sequence, mirroring the VT parser's decomposition. Kept as data (not
/// interpreted) so the capture layer can classify it without re-implementing the grid.
public struct TerminalControlSequence: Sendable, Equatable {
    public let params: [Int]
    public let intermediates: [UInt8]
    public let finalByte: UInt8
    public let privateMarker: UInt8?

    public init(params: [Int], intermediates: [UInt8] = [], finalByte: UInt8,
                privateMarker: UInt8? = nil) {
        self.params = params
        self.intermediates = intermediates
        self.finalByte = finalByte
        self.privateMarker = privateMarker
    }

    /// Whether this sequence places, erases, scrolls, or switches what is on the grid —
    /// the mark of a paint (a program positioning text on cells) as opposed to a print
    /// (text flowing through the cursor). Cursor motion (CUU/CUD/CUF/CUB/CNL/CPL/CHA/
    /// CUP/HVP/VPA/HPA/CHT/CBT), erase (ED/EL/ECH), insert/delete (ICH/DCH/IL/DL),
    /// scroll (SU/SD), scroll region (DECSTBM), save/restore cursor (SCOSC/SCORC), and
    /// the alt-screen and synchronized-output private modes qualify. SGR, cursor
    /// visibility/shape, bracketed paste, mouse and focus modes, and reports do not:
    /// a shell colouring its output is still printing.
    public var isPaint: Bool {
        if let marker = privateMarker {
            guard marker == 0x3F /* ? */, finalByte == 0x68 || finalByte == 0x6C /* h l */
            else { return false }
            return params.contains { Self.paintPrivateModes.contains($0) }
        }
        guard intermediates.isEmpty else { return false }
        return Self.paintFinalBytes.contains(finalByte)
    }

    private static let paintPrivateModes: Set<Int> = [47, 1047, 1049, 2026]
    private static let paintFinalBytes: Set<UInt8> = [
        0x40, // @ ICH
        0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, // A–H cursor motion, CUP
        0x49, // I CHT
        0x4A, 0x4B, // J ED, K EL
        0x4C, 0x4D, // L IL, M DL
        0x50, // P DCH
        0x53, 0x54, // S SU, T SD
        0x58, // X ECH
        0x5A, // Z CBT
        0x60, // ` HPA
        0x64, // d VPA
        0x66, // f HVP
        0x72, // r DECSTBM
        0x73, 0x75, // s SCOSC, u SCORC
    ]
}
