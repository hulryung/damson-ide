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

    /// Spawn a fresh PTY session from a config (argv/cwd/env decide what runs in it),
    /// at the given grid size. Sizing at spawn (not 80×24-then-resize) means the
    /// child's very first TIOCGWINSZ already reads the real geometry — no layout at
    /// the wrong size, no reflow on the first SIGWINCH.
    public convenience init(config: DamsonConfig, initialCols: Int, initialRows: Int) {
        self.init(session: DamsonSession(config: config,
                                         initialCols: initialCols,
                                         initialRows: initialRows))
    }

    /// Resurrect a session around a PTY reclaimed from the keeper (T23 restart
    /// survival). The `PTYHost.adopt` path skips forkpty: the child predates this
    /// process, and `replayPreamble` (the previous incarnation's
    /// `stateRestorationPreamble`) plus everything buffered while the app was down is
    /// parsed strictly before any live output.
    public convenience init(adopted: KeeperAdoptedPTY, replayPreamble: Data,
                            config: DamsonConfig, initialCols: Int, initialRows: Int) {
        let host = PTYHost()
        host.adopt(fd: adopted.fd, pid: adopted.pid,
                   startSec: adopted.startSec, startUsec: adopted.startUsec,
                   replay: replayPreamble + adopted.buffer)
        self.init(session: DamsonSession(config: config, restoredScrollback: nil,
                                         backend: host,
                                         initialCols: initialCols,
                                         initialRows: initialRows))
    }

    // MARK: - Restart survival (T23 keeper handoff)

    /// Detach the PTY for keeper handoff — the child keeps running, this session just
    /// stops owning it. nil when damson refuses (tmux-backed panes, non-PTY backends).
    public func releaseForKeeperHandoff() -> KeeperPTYHandoff? {
        guard let handoff = session.releasePTYForHandoff() else { return nil }
        return KeeperPTYHandoff(fd: handoff.fd, pid: handoff.pid,
                                startSec: handoff.startSec, startUsec: handoff.startUsec,
                                cwd: handoff.cwd, tail: handoff.tail)
    }

    public func keeperRestorationPreamble() -> Data {
        session.stateRestorationPreamble()
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

    public var outputBytes: AnyPublisher<Data, Never> {
        session.outputBytes.eraseToAnyPublisher()
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
