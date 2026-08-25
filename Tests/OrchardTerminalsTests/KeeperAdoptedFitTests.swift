import Combine
import DamsonTerminal
import Foundation
import XCTest
@testable import OrchardTerminals

/// T59: the fit decisions a keeper-adopted pane feeds into `TerminalFitHost`,
/// driven headlessly. A real `DamsonSession` (parser + grid) runs over a fake IO
/// backend that plays `PTYHost.adopt` + `spawn`: no fork, and the replay (mode
/// preamble + bytes buffered while the app was down) is delivered on the next
/// main-queue turn, strictly before live output — the same ordering the app sees.
///
/// What is extractable without a Metal surface: the grid the replay parses into,
/// what the attach-time resize does to it, the content-row count and top/bottom
/// decision the host derives, and the moment `AttachFit` re-runs the surface's
/// fit pass. What is not: Damson's scroll position inside the surface — that is
/// the human visual pass in docs/reports/t59-adopted-fit.md.
@MainActor
final class KeeperAdoptedFitTests: XCTestCase {

    private final class AdoptedBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        /// Handed to the session's parser on the main-queue turn after `spawn`.
        var replay = Data()
        var foregroundJob = false
        private(set) var spawnedSize: (cols: Int, rows: Int)?
        private(set) var resizes: [(cols: Int, rows: Int)] = []

        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { foregroundJob }

        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {
            spawnedSize = (cols, rows)
            let bytes = replay
            replay = Data()
            guard !bytes.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onData?(bytes) }
        }

        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) { resizes.append((cols, rows)) }
        func terminate() {}

        /// Live output after adoption (the child's post-SIGWINCH repaint).
        func feed(_ text: String) { onData?(Data(text.utf8)) }
    }

    private let cell = TerminalPaneFit.Metrics(
        cellWidth: 8, cellHeight: 16, padding: CGSize(width: 4, height: 4))

    /// Let the replay turn run, the way the app's runloop would.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func adoptedSession(recordedCols: Int, recordedRows: Int,
                                backend: AdoptedBackend) -> DamsonSession {
        var config = DamsonConfig()
        config.argv = ["/bin/zsh"]
        return DamsonSession(config: config, restoredScrollback: nil, backend: backend,
                             initialCols: recordedCols, initialRows: recordedRows)
    }

    // MARK: - Shell pane

    /// A shell held at its prompt: the record is the previous window's larger
    /// grid, the keeper hands back only the mode preamble, the workbench fits
    /// fewer rows. The adopted grid must shrink without inventing scrollback, the
    /// prompt repaint must count as the first paint, and the decision must be
    /// top-aligned with row 0 fully visible — identical to a fresh shell.
    func testAdoptedShellFitsTopAlignedAfterTheAttachResizeAndPromptRepaint() {
        let backend = AdoptedBackend()
        backend.replay = Data("\u{1b}[?2004h".utf8)
        let session = adoptedSession(recordedCols: 200, recordedRows: 60, backend: backend)

        XCTAssertEqual(backend.spawnedSize?.cols, 200)
        XCTAssertEqual(backend.spawnedSize?.rows, 60,
                       "adoption keeps the recorded geometry until the surface reports its own")
        XCTAssertEqual(session.grid.rows, 60)
        XCTAssertFalse(TerminalPaneFit.hasContent(session.grid),
                       "before the replay turn the parser is empty — the fit sees a fresh pane")

        drainMainQueue()
        XCTAssertTrue(session.bracketedPasteEnabled, "the preamble replayed on the next turn")
        XCTAssertFalse(TerminalPaneFit.hasContent(session.grid),
                       "a mode-only preamble paints nothing")

        // Surface attach: framed first, then its size report resizes the session.
        var fit = TerminalPaneFit.AttachFit()
        var paintsSeen: [Bool] = []
        let sub = session.gridChanged.sink { [weak session] in
            guard let session else { return }
            paintsSeen.append(TerminalPaneFit.hasContent(session.grid))
        }
        defer { sub.cancel() }
        XCTAssertFalse(fit.note(.frame(ready: true)))

        session.resize(cols: 120, rows: 34)
        XCTAssertEqual(session.grid.cols, 120)
        XCTAssertEqual(session.grid.rows, 34)
        XCTAssertEqual(backend.resizes.last?.cols, 120)
        XCTAssertEqual(backend.resizes.last?.rows, 34, "the child is told the fit size (SIGWINCH)")
        XCTAssertEqual(session.grid.scrollback.count, 0,
                       "shrinking an empty adopted grid must not push blank rows into scrollback")
        XCTAssertEqual(paintsSeen, [false], "the resize's own grid-change carries no paint")
        XCTAssertFalse(fit.note(.gridChange(hasContent: false)),
                       "so it must not spend the attach latch")

        // The child's post-SIGWINCH prompt repaint — the first real paint.
        backend.feed("\r\u{1b}[Jrepo on main\r\n❯ ")
        XCTAssertEqual(paintsSeen.last, true)
        XCTAssertTrue(fit.note(.gridChange(hasContent: true)),
                      "the first paint after attach re-runs the surface fit pass")
        XCTAssertFalse(fit.isPending)

        let contentRows = TerminalPaneFit.contentRows(in: session.grid)
        XCTAssertEqual(contentRows, 2, "two prompt rows, no scrollback")
        XCTAssertTrue(TerminalPaneFit.shouldTopAlign(contentRows: contentRows, viewportRows: 34))
        let container = CGSize(width: 8 * 120 + 8, height: 16 * 34 + 8 + 5)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        XCTAssertEqual(layout.rows, 34)
        let frame = TerminalPaneFit.surfaceFrame(
            container: container, layout: layout, contentRows: contentRows)
        XCTAssertEqual(frame.origin.y, 0, "row 0 sits fully visible at the top")
        XCTAssertEqual(frame.height, layout.contentSize.height,
                       "the surface is a whole number of cells — no partial row inside it")
    }

    /// Same record, same window: no shrink at all. The size report still fires a
    /// contentless grid-change (Damson notifies on every `resize`), and the fit
    /// must still wait for the repaint.
    func testAdoptedShellAtTheSameGeometryStillWaitsForTheRepaint() {
        let backend = AdoptedBackend()
        backend.replay = Data("\u{1b}[?2004h".utf8)
        let session = adoptedSession(recordedCols: 120, recordedRows: 34, backend: backend)
        drainMainQueue()

        var fit = TerminalPaneFit.AttachFit()
        var changes = 0
        let sub = session.gridChanged.sink { changes += 1 }
        defer { sub.cancel() }
        XCTAssertFalse(fit.note(.frame(ready: true)))
        session.resize(cols: 120, rows: 34)
        XCTAssertEqual(changes, 1, "Damson notifies even when the grid did not change")
        XCTAssertFalse(fit.note(.gridChange(hasContent: TerminalPaneFit.hasContent(session.grid))))
        XCTAssertTrue(fit.isPending)

        backend.feed("❯ ")
        XCTAssertTrue(fit.note(.gridChange(hasContent: TerminalPaneFit.hasContent(session.grid))))
        XCTAssertEqual(TerminalPaneFit.contentRows(in: session.grid), 1)
    }

    // MARK: - TUI pane

    /// A full-screen TUI (Claude Code shape: sync-output frames, cursor-addressed
    /// paint) whose buffered frame was painted for the recorded 60-row grid, then
    /// fitted into 34 rows while the app owns the screen. The frame must survive
    /// the shrink as scrollback + viewport (nothing lost), the content overflows
    /// the viewport so the host bottom-aligns, and Damson's own follow policy for
    /// such a grid is the grid-top anchor (`hasUsedSyncOutput` is sticky) — the
    /// combination that keeps row alignment whole-cell after relaunch.
    func testAdoptedTUIFrameSurvivesTheFitShrinkAndOverflowBottomAligns() {
        let backend = AdoptedBackend()
        backend.foregroundJob = true
        var replay = "\u{1b}[?2026h\u{1b}[?2026l"   // preamble: re-arm sticky sync-output
        replay += "\u{1b}[?2026h"
        for r in 1...60 { replay += "\u{1b}[\(r);1Hrow \(r)" }
        replay += "\u{1b}[?2026l"
        backend.replay = Data(replay.utf8)
        let session = adoptedSession(recordedCols: 200, recordedRows: 60, backend: backend)

        // Content landed before the surface has a frame: the latch waits.
        var fit = TerminalPaneFit.AttachFit()
        drainMainQueue()
        XCTAssertTrue(session.grid.hasUsedSyncOutput, "the preamble re-armed the sticky bit")
        XCTAssertTrue(TerminalPaneFit.hasContent(session.grid))
        XCTAssertEqual(TerminalPaneFit.contentRows(in: session.grid), 60)
        XCTAssertFalse(fit.note(.gridChange(hasContent: true)),
                       "painted but unframed — nothing to fit against yet")

        // Surface attach at the live workbench geometry.
        session.resize(cols: 120, rows: 34)
        XCTAssertEqual(session.grid.rows, 34)
        let contentRows = TerminalPaneFit.contentRows(in: session.grid)
        XCTAssertEqual(contentRows, 60,
                       "the shrink moves the excess into scrollback; nothing is dropped")
        XCTAssertEqual(session.grid.scrollback.count + session.grid.rows, 60)
        XCTAssertTrue(fit.note(.frame(ready: true)),
                      "the frame completes the pair and re-fits the replayed frame")

        XCTAssertFalse(TerminalPaneFit.shouldTopAlign(contentRows: contentRows, viewportRows: 34))
        let container = CGSize(width: 8 * 120 + 8, height: 16 * 34 + 8 + 7)
        let layout = TerminalPaneFit.layout(container: container, metrics: cell)
        let frame = TerminalPaneFit.surfaceFrame(
            container: container, layout: layout, contentRows: contentRows)
        XCTAssertEqual(frame.maxY, container.height, "overflow bottom-aligns the surface")
        XCTAssertEqual(frame.origin.y, layout.leftover.height,
                       "the leftover pixels sit above the surface, not inside a row")
        XCTAssertEqual(
            (frame.height - cell.padding.height * 2).truncatingRemainder(dividingBy: cell.cellHeight),
            0, "whole cells only")
    }
}
