import Foundation

/// Decides, one output burst at a time, where the `terminal read` stream takes its
/// lines from — and so what a `terminal_tail` archive holds (T54).
///
/// A burst is one PTY chunk as damson delivers it: `outputBytes` fires, the parser
/// emits that chunk's `outputEvents`, then `gridChanged` fires once. Two kinds of
/// program share that pipe:
///
/// * A program that **prints** flows text through the cursor and breaks lines with
///   CR/LF. Its text events are its lines, byte for byte, and they are appended to the
///   stream unchanged — the contract every pre-T54 test pins.
/// * A program that **paints** (Claude Code, any Ink/ncurses-style TUI) positions the
///   cursor and writes cells. Its text events are not lines: a cell-diffing renderer
///   skips the cells that already hold the right character and steps over blanks with
///   cursor motion, so the events for `paste again to expand` painted over an older
///   row are literally `paste `, `gain to expa`, `d` — and a wide paste over a blank
///   screen arrives with no spaces at all (`Tipsforgettingstarted`). Appending those
///   events is what put the collapsed and torn text in the T50 archive. For a paint
///   burst the truthful record is the rendered frame, so the collector drops the
///   burst's text events and captures the rows that changed from the grid instead.
///
/// The classification is per burst: the first cursor-motion / erase / scroll /
/// screen-switch CSI (`TerminalControlSequence.isPaint`) turns the burst into a paint.
/// A paint inside a DECSET-2026 synchronized-output frame is captured when the frame
/// closes (a frame can span several chunks; capturing mid-frame is how a torn repaint
/// would get in), or at process exit if the frame never closes.
///
/// Frames are diffed by absolute row (`TerminalGridSnapshot.firstRowIndex + r`), so a
/// row that merely scrolled up is not a change and is not re-emitted; rows that
/// scrolled off the screen between two captures are read back from scrollback so a
/// burst larger than the screen still reaches the stream in full. After a print burst
/// the baseline is refreshed *without* emitting, so a following paint (a shell redrawing
/// its prompt after `ls`) emits only what the paint changed — the printed lines are
/// already in the stream and are not duplicated.
struct TerminalCaptureCollector {
    /// The open burst's printed tokens, held until the burst ends. They are appended
    /// verbatim if the burst turns out to be a print and discarded if it is a paint.
    private enum Token { case text(String), control(UInt8) }
    private var pending: [Token] = []
    private var burstOpen = false
    private(set) var burstIsPaint = false
    /// A paint burst ended inside a synchronized-output frame; the frame is captured
    /// when a later burst ends with the frame closed (or at exit).
    private(set) var paintPending = false

    /// What the stream last saw of each screen (primary / alt), by absolute row.
    private struct Baseline {
        var firstRowIndex: Int
        var rows: [Int: String]
    }
    private var baselines: [Bool: Baseline] = [:]

    /// Rows appended from frames over the collector's life (a test/diagnostic counter).
    private(set) var capturedRowCount = 0

    // MARK: - Burst lifecycle

    /// `outputBytes` fired: a chunk is being parsed. Idempotent — a burst whose
    /// `gridChanged` never came (a repaint-only chunk on a fake) is simply continued.
    mutating func beginBurst() {
        burstOpen = true
    }

    /// One parsed event of the open burst.
    mutating func observe(_ event: TerminalOutputEvent) {
        if !burstOpen { beginBurst() }
        switch event {
        case .text(let s):
            if !burstIsPaint { pending.append(.text(s)) }
        case .control(let byte):
            if !burstIsPaint { pending.append(.control(byte)) }
        case .csi(let sequence):
            if sequence.isPaint && !burstIsPaint {
                // The burst is a paint: whatever text it printed so far is cell writes,
                // not lines. The frame carries it.
                burstIsPaint = true
                pending.removeAll()
            }
        case .osc:
            break
        }
    }

    /// `gridChanged` fired after the chunk was applied: close the burst. A print burst
    /// appends its tokens; a paint burst captures the frame (now, or once the sync
    /// frame closes). A `gridChanged` with no burst open — a resize — changes nothing.
    mutating func endBurst(grid: TerminalGridSnapshot,
                           scrolledOff: (Int) -> [String],
                           into buffer: inout TerminalStreamBuffer) {
        guard burstOpen else { return }
        burstOpen = false
        defer { burstIsPaint = false }
        if burstIsPaint || paintPending {
            pending.removeAll()
            paintPending = true
            // Mid-frame: the screen is half painted. Wait for the frame to close.
            if grid.inSyncOutputMode { return }
            captureFrame(grid, scrolledOff: scrolledOff, into: &buffer)
            paintPending = false
        } else {
            flushPending(into: &buffer)
            rebase(on: grid)
        }
    }

    /// The process is gone (or the pane is being replaced): nothing more will close a
    /// frame, so capture whatever is on the screen now and append any held print.
    mutating func flush(grid: TerminalGridSnapshot,
                        scrolledOff: (Int) -> [String],
                        into buffer: inout TerminalStreamBuffer) {
        burstOpen = false
        if burstIsPaint || paintPending {
            pending.removeAll()
            captureFrame(grid, scrolledOff: scrolledOff, into: &buffer)
            paintPending = false
        } else {
            flushPending(into: &buffer)
            rebase(on: grid)
        }
        burstIsPaint = false
    }

    /// The pane got a fresh engine (respawn): its grid counts rows from zero again, so
    /// no earlier baseline may be diffed against it. The stream itself carries over.
    mutating func resetBaselines() {
        baselines.removeAll()
        pending.removeAll()
        burstOpen = false
        burstIsPaint = false
        paintPending = false
    }

    // MARK: - Print

    private mutating func flushPending(into buffer: inout TerminalStreamBuffer) {
        for token in pending {
            switch token {
            case .text(let s): buffer.appendText(s)
            case .control(let byte): buffer.appendControl(byte)
            }
        }
        pending.removeAll()
    }

    /// Record the screen after a print burst without emitting anything: those rows
    /// reached the stream as printed text, and the next paint must not re-emit them.
    private mutating func rebase(on grid: TerminalGridSnapshot) {
        var rows: [Int: String] = [:]
        rows.reserveCapacity(grid.lines.count)
        for (r, text) in grid.lines.enumerated() { rows[grid.firstRowIndex + r] = text }
        baselines[grid.isAltScreen] = Baseline(firstRowIndex: grid.firstRowIndex, rows: rows)
    }

    // MARK: - Paint

    /// Append every row whose text differs from what the stream last saw at that
    /// absolute row: first the rows that scrolled off since the last capture (their
    /// final text, from scrollback), then the visible rows, top to bottom. Blank rows
    /// are never emitted on their own; one blank line separates two emitted rows that
    /// had only blank rows between them, so paragraph structure survives.
    private mutating func captureFrame(_ grid: TerminalGridSnapshot,
                                       scrolledOff: (Int) -> [String],
                                       into buffer: inout TerminalStreamBuffer) {
        let screen = grid.isAltScreen
        // No baseline yet means nothing of this screen has reached the stream: every
        // row since its first (a fresh grid counts from 0) is new, scrollback included.
        let baseline = baselines[screen] ?? Baseline(firstRowIndex: 0, rows: [:])

        var candidates: [(row: Int, text: String)] = []
        if grid.firstRowIndex > baseline.firstRowIndex {
            // The last element is the row just above the screen; align from the end.
            let lines = scrolledOff(baseline.firstRowIndex)
            let first = grid.firstRowIndex - lines.count
            for (i, text) in lines.enumerated() where first + i >= baseline.firstRowIndex {
                candidates.append((first + i, text))
            }
        }
        for (r, text) in grid.lines.enumerated() {
            candidates.append((grid.firstRowIndex + r, text))
        }

        var lastEmittedRow: Int?
        var blanksSinceLastEmitted = 0
        for (row, text) in candidates {
            let previous = baseline.rows[row] ?? ""
            if text.isEmpty {
                if lastEmittedRow != nil { blanksSinceLastEmitted += 1 }
                continue
            }
            if text == previous {
                // Unchanged: its neighbours' blank separation no longer applies.
                lastEmittedRow = nil
                blanksSinceLastEmitted = 0
                continue
            }
            if let last = lastEmittedRow, row > last + 1, blanksSinceLastEmitted == row - last - 1 {
                buffer.appendCapturedRow("")
            }
            buffer.appendCapturedRow(text)
            capturedRowCount += 1
            lastEmittedRow = row
            blanksSinceLastEmitted = 0
        }

        var rows: [Int: String] = [:]
        rows.reserveCapacity(grid.lines.count)
        for (r, text) in grid.lines.enumerated() { rows[grid.firstRowIndex + r] = text }
        baselines[screen] = Baseline(firstRowIndex: grid.firstRowIndex, rows: rows)
    }
}
