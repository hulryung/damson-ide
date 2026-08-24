import Combine
import DamsonTerminal
import Foundation

/// The session behind a remote pane whose held `ssh` child ended while the app was
/// gone: a terminal with no process, no fd and no future output.
///
/// The keeper only tells a claiming app that a held child reached EOF — it has no exit
/// status to hand over, because the status went to the reaper of a process the keeper
/// never forked. For a local pane that is where T23's documented limit applies and the
/// pane simply closes. For an `ssh` pane it is not: closing it would delete the only
/// local record that a connection to a named host, in a named remote directory,
/// existed at all — and the thing that ended is the *connection*, which proves nothing
/// about the work on the far side (docs/design/remote-hosts.md rule 2). So the pane
/// comes back inspectable and disconnected, carrying the spec a reconnect relaunches
/// from.
///
/// `exitCode` stays nil on purpose, and it is the most load-bearing line in this file.
/// A synthesized `0` would read as "the remote command exited cleanly" through
/// `HostLiveness.verdictForPTYEnd` — a death certificate for work nobody observed.
/// Absent status means `unverifiable`, which is the truth.
@MainActor
public final class KeeperEndedSession: TerminalSession {
    public var config: DamsonConfig
    public let processExited = true
    public let exitCode: Int32? = nil
    public let bracketedPasteEnabled = false
    public let hasRunningForegroundJob = false
    public var onExit: ((Int32) -> Void)?

    /// Nothing is ever published: the child is gone, and a pane that re-announced an
    /// exit at boot would report a second ending for one that already happened while
    /// nobody was watching.
    private let gridChangedSubject = PassthroughSubject<Void, Never>()
    private let outputSubject = PassthroughSubject<TerminalOutputEvent, Never>()
    private let outputBytesSubject = PassthroughSubject<Data, Never>()

    /// Grid geometry from the restoration record, so the pane lays out at the size it
    /// had rather than snapping to a default nobody chose.
    private let cols: Int
    private let rows: Int

    public init(config: DamsonConfig = DamsonConfig(), cols: Int, rows: Int) {
        self.config = config
        self.cols = max(1, cols)
        self.rows = max(1, rows)
    }

    public func write(_ data: Data) {}

    public func updateConfig(_ config: DamsonConfig) { self.config = config }

    public func terminate() {}

    public func gridSnapshot() -> TerminalGridSnapshot {
        TerminalGridSnapshot(lines: [], cursorRow: 0, cursorCol: 0, cols: cols, rows: rows,
                             isAltScreen: false, inSyncOutputMode: false)
    }

    public var gridChanged: AnyPublisher<Void, Never> {
        gridChangedSubject.eraseToAnyPublisher()
    }

    public var outputEvents: AnyPublisher<TerminalOutputEvent, Never> {
        outputSubject.eraseToAnyPublisher()
    }

    public var outputBytes: AnyPublisher<Data, Never> {
        outputBytesSubject.eraseToAnyPublisher()
    }
}
