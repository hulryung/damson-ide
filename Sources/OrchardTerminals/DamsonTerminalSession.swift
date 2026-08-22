import Foundation
import Combine
import DamsonTerminal

/// The one production `TerminalSession`: a thin adapter over a live `DamsonSession`.
/// Nothing else in the agent layer touches damson's session API, so swapping terminal
/// engines — or faking one in tests — is a single conformance.
@MainActor
public final class DamsonTerminalSession: TerminalSession {
    /// The wrapped engine session, exposed so the app layer can hand it to
    /// `DamsonTerminalView` for rendering. Engine-agnostic code must not reach for this.
    public let session: DamsonSession

    public var onExit: ((Int32) -> Void)?

    public init(session: DamsonSession) {
        self.session = session
        // DamsonSession.onExit is single-assignment; the adapter claims it and forwards,
        // so protocol consumers get the same contract without racing over the slot.
        session.onExit = { [weak self] code in self?.onExit?(code) }
    }

    /// Spawn a fresh PTY session from a config (argv/cwd/env decide what runs in it).
    public convenience init(config: DamsonConfig) {
        self.init(session: DamsonSession(config: config))
    }

    public func write(_ data: Data) { session.write(data) }

    public var config: DamsonConfig { session.config }
    public func updateConfig(_ config: DamsonConfig) { session.updateConfig(config) }

    public func terminate() { session.terminate() }

    public var processExited: Bool { session.processExited }
    public var exitCode: Int32? { session.exitCode }
    public var bracketedPasteEnabled: Bool { session.bracketedPasteEnabled }
    public var hasRunningForegroundJob: Bool { session.hasRunningForegroundJob }

    public var gridChanged: AnyPublisher<Void, Never> {
        session.gridChanged.eraseToAnyPublisher()
    }

    public var outputEvents: AnyPublisher<TerminalOutputEvent, Never> {
        session.outputEvents
            .compactMap { event -> TerminalOutputEvent? in
                switch event {
                case .text(let s): return .text(s)
                case .execute(let byte): return .control(byte)
                case .osc(let params): return .osc(params)
                case .csi: return nil
                }
            }
            .eraseToAnyPublisher()
    }

    public func gridSnapshot() -> TerminalGridSnapshot {
        let grid = session.grid
        var lines: [String] = []
        lines.reserveCapacity(grid.rows)
        for r in 0..<grid.rows {
            var s = String(grid.row(r).map { $0.char })
            while let last = s.last, last == " " { s.removeLast() }
            lines.append(s)
        }
        return TerminalGridSnapshot(
            lines: lines,
            cursorRow: grid.cursorRow,
            cursorCol: grid.cursorCol,
            cols: grid.cols,
            rows: grid.rows,
            isAltScreen: grid.isAltScreenActive,
            inSyncOutputMode: grid.inSyncOutputMode)
    }
}
