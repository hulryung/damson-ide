import Foundation
import Combine
import DamsonTerminal

/// A deterministic, process-free `TerminalSession` for tests and headless previews:
/// the "terminal" is whatever the caller scripts. Written input is captured, output
/// events and grid content are emitted on demand, and exit is a method call. This is
/// the counterpart to `DamsonTerminalSession` behind the same seam — the terminal
/// service and the readiness stack run against it unmodified, which is what lets the
/// whole T3 surface be exercised without spawning a single PTY.
@MainActor
public final class ScriptedTerminalSession: TerminalSession {
    /// Everything written to the "PTY", in write order.
    public private(set) var written: [Data] = []
    /// Convenience: all written bytes as one UTF-8 string.
    public var writtenText: String {
        String(decoding: written.reduce(Data(), +), as: UTF8.self)
    }

    /// The scripted visible screen, returned by `gridSnapshot()`.
    public var screenLines: [String] = []
    public var isAltScreen = true
    public var inSyncOutputMode = false

    public var config: DamsonConfig
    public private(set) var processExited = false
    public private(set) var exitCode: Int32?
    public var bracketedPasteEnabled = true
    public var hasRunningForegroundJob = true
    public var onExit: ((Int32) -> Void)?

    private let gridChangedSubject = PassthroughSubject<Void, Never>()
    private let outputSubject = PassthroughSubject<TerminalOutputEvent, Never>()

    public init(config: DamsonConfig = DamsonConfig()) {
        self.config = config
    }

    public func write(_ data: Data) {
        written.append(data)
    }

    public func updateConfig(_ config: DamsonConfig) {
        self.config = config
    }

    public func terminate() {
        exit(code: 0)
    }

    public var gridChanged: AnyPublisher<Void, Never> {
        gridChangedSubject.eraseToAnyPublisher()
    }

    public var outputEvents: AnyPublisher<TerminalOutputEvent, Never> {
        outputSubject.eraseToAnyPublisher()
    }

    public func gridSnapshot() -> TerminalGridSnapshot {
        TerminalGridSnapshot(
            lines: screenLines, cursorRow: 0, cursorCol: 0,
            cols: 80, rows: max(screenLines.count, 24),
            isAltScreen: isAltScreen, inSyncOutputMode: inSyncOutputMode)
    }

    // MARK: - Scripting

    /// Emit printed text (splitting embedded newlines into control events, the way the
    /// VT parser would) and signal a grid change.
    public func emitOutput(_ text: String) {
        var chunk = ""
        func flush() {
            if !chunk.isEmpty {
                outputSubject.send(.text(chunk))
                chunk = ""
            }
        }
        for character in text {
            switch character {
            case "\n":
                flush()
                outputSubject.send(.control(0x0A))
            case "\r":
                flush()
                outputSubject.send(.control(0x0D))
            default:
                chunk.append(character)
            }
        }
        flush()
        gridChangedSubject.send()
    }

    /// Emit a parsed OSC sequence (e.g. `["9999", "idle"]` for the Tier-2 status escape).
    public func emitOSC(_ params: [String]) {
        outputSubject.send(.osc(params))
    }

    /// Redraw the scripted screen and fire the grid-change signal.
    public func showScreen(_ lines: [String]) {
        screenLines = lines
        gridChangedSubject.send()
    }

    /// End the "process".
    public func exit(code: Int32) {
        guard !processExited else { return }
        processExited = true
        exitCode = code
        hasRunningForegroundJob = false
        onExit?(code)
    }
}
