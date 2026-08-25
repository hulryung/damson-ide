import XCTest
import OrchardCore
@testable import OrchardTerminals

/// T54: the stream's print-vs-paint capture, exercised through the production path —
/// `TerminalService` → `TerminalRecord.attach` → `TerminalCaptureCollector` →
/// `TerminalStreamBuffer` → `read` — against the scripted session, whose `emitPaint`
/// delivers a chunk with the engine's exact burst framing (`outputBytes`, the parsed
/// events, one `gridChanged`).
@MainActor
final class TerminalCaptureCollectorTests: XCTestCase {

    private var service: TerminalService!
    private var session: ScriptedTerminalSession!
    private var handle = ""

    override func setUp() async throws {
        try await super.setUp()
        // One fresh scripted session per spawn; `session` always names the live one.
        service = TerminalService(factory: { [weak self] _, _ in
            let scripted = ScriptedTerminalSession()
            scripted.isAltScreen = false
            self?.session = scripted
            return scripted
        })
        handle = try service.create(engineID: "shell").handle
    }

    private func stream() throws -> [String] {
        try service.read(handle: handle, cursor: 0, limit: 500).lines
    }

    // MARK: - CSI helpers (what the VT parser would hand the seam)

    private func cup(_ row: Int, _ col: Int) -> TerminalOutputEvent {
        .csi(TerminalControlSequence(params: [row, col], finalByte: 0x48))
    }
    private func cha(_ col: Int) -> TerminalOutputEvent {
        .csi(TerminalControlSequence(params: [col], finalByte: 0x47))
    }
    private func cuf(_ n: Int) -> TerminalOutputEvent {
        .csi(TerminalControlSequence(params: [n], finalByte: 0x43))
    }
    private var eraseLine: TerminalOutputEvent {
        .csi(TerminalControlSequence(params: [], finalByte: 0x4B))
    }
    private func syncOutput(_ on: Bool) -> TerminalOutputEvent {
        .csi(TerminalControlSequence(params: [2026], finalByte: on ? 0x68 : 0x6C,
                                     privateMarker: 0x3F))
    }
    private var sgrReset: TerminalOutputEvent {
        .csi(TerminalControlSequence(params: [0], finalByte: 0x6D))
    }

    // MARK: - Classification

    func testPaintClassificationOfControlSequences() {
        func seq(_ params: [Int], _ final: UInt8, marker: UInt8? = nil) -> TerminalControlSequence {
            TerminalControlSequence(params: params, finalByte: final, privateMarker: marker)
        }
        // Painting: cursor addressing, erase, scroll, screens, synchronized output.
        XCTAssertTrue(seq([3, 7], 0x48).isPaint, "CUP")
        XCTAssertTrue(seq([12], 0x47).isPaint, "CHA")
        XCTAssertTrue(seq([1], 0x43).isPaint, "CUF")
        XCTAssertTrue(seq([2], 0x41).isPaint, "CUU")
        XCTAssertTrue(seq([], 0x4B).isPaint, "EL")
        XCTAssertTrue(seq([2], 0x4A).isPaint, "ED")
        XCTAssertTrue(seq([5], 0x64).isPaint, "VPA")
        XCTAssertTrue(seq([1, 24], 0x72).isPaint, "DECSTBM")
        XCTAssertTrue(seq([2026], 0x68, marker: 0x3F).isPaint, "DECSET 2026")
        XCTAssertTrue(seq([2026], 0x6C, marker: 0x3F).isPaint, "DECRST 2026")
        XCTAssertTrue(seq([1049], 0x68, marker: 0x3F).isPaint, "alt screen")
        // Printing with decoration: colour, cursor visibility, input modes, reports.
        XCTAssertFalse(seq([1, 32], 0x6D).isPaint, "SGR")
        XCTAssertFalse(seq([25], 0x6C, marker: 0x3F).isPaint, "cursor hide")
        XCTAssertFalse(seq([2004], 0x68, marker: 0x3F).isPaint, "bracketed paste")
        XCTAssertFalse(seq([1004], 0x68, marker: 0x3F).isPaint, "focus events")
        XCTAssertFalse(seq([6], 0x6E).isPaint, "DSR")
        XCTAssertFalse(seq([2], 0x71).isPaint, "cursor shape (has intermediate in practice)")
    }

    // MARK: - Print bursts are untouched

    func testPrintedBurstsAppendVerbatim() throws {
        session.emitOutput("hello\nworld\n")
        session.emitOutput("progress 10%\rprogress 90%")
        XCTAssertEqual(try stream(), ["hello", "world", "progress 10%", "progress 90%"])
    }

    func testColouredPrintIsStillAPrint() throws {
        // SGR between text runs does not turn a burst into a paint: the runs join as
        // printed, and nothing is captured from the (unrelated) scripted screen.
        session.screenLines = ["unrelated screen content"]
        session.emitPaint([.text("ok "), sgrReset, .text("PASS"), .control(0x0A)],
                          screen: ["unrelated screen content"])
        XCTAssertEqual(try stream(), ["ok PASS"])
    }

    // MARK: - Paint bursts are captured from the frame

    func testPaintBurstCapturesRowsNotCellWrites() throws {
        // A wide paste painted onto a blank screen: the renderer steps over every
        // blank cell with cursor motion, so the text events carry no spaces at all —
        // the T50 archive's `Tipsforgettingstarted`. The frame has the spaces.
        session.emitPaint(
            [syncOutput(true), cup(1, 1), .text("│"), cuf(1), .text("Tips"), cuf(1),
             .text("for"), cuf(1), .text("getting"), cuf(1), .text("started"), cuf(1),
             .text("│"), syncOutput(false)],
            screen: ["│ Tips for getting started │"])
        XCTAssertEqual(try stream(), ["│ Tips for getting started │"])
    }

    func testCellDiffRepaintEmitsTheWholeChangedRow() throws {
        session.emitPaint([cup(1, 1), .text("Working")],
                          screen: ["Working", "✢ Improvising… (4s · ↓ 181 tokens)"])
        // Only the cells that differ are rewritten: the spinner glyph, one digit of
        // the seconds, two digits of the token count. Before T54 the stream read
        // `✶595` for this frame (compare the archive's `✽59`, `✢63`).
        session.emitPaint([cup(2, 1), .text("✶"), cha(16), .text("5"), cha(25), .text("95")],
                          screen: ["Working", "✶ Improvising… (5s · ↓ 195 tokens)"])
        XCTAssertEqual(try stream(), [
            "Working",
            "✶ Improvising… (5s · ↓ 195 tokens)",
        ], "each frame contributes its changed row in full; spinner ticks coalesce to the latest")
    }

    func testSustainedSpinnerDoesNotEvictRecentRealOutput() throws {
        session.emitPaint([cup(1, 1), .text("REAL: git clone done")],
                          screen: ["REAL: git clone done", "✢ Thinking… (1s · ↓ 10 tokens)"])
        for i in 2...40 {
            let glyph = i % 2 == 0 ? "✶" : "✢"
            session.emitPaint(
                [cup(2, 1), .text(glyph)],
                screen: ["REAL: git clone done",
                         "\(glyph) Thinking… (\(i)s · ↓ \(i * 10) tokens)"])
        }
        session.emitPaint([cup(3, 1), .text("REAL: all tests passed")],
                          screen: ["REAL: git clone done",
                                   "✶ Thinking… (40s · ↓ 400 tokens)",
                                   "REAL: all tests passed"])
        XCTAssertEqual(try stream(), [
            "REAL: git clone done",
            "✶ Thinking… (40s · ↓ 400 tokens)",
            "REAL: all tests passed",
        ])
    }

    func testTornRepaintIsCapturedAsTheWholeRow() throws {
        session.emitPaint([cup(1, 1), .text("[Pasted text #1 +114 lines]")],
                          screen: ["[Pasted text #1 +114 lines]"])
        // The hint replaces the collapsed-paste marker; a cell diff writes only what
        // differs, and the text events for the row are torn fragments.
        session.emitPaint([cup(1, 1), .text("paste "), cha(8), .text("gain to expa"), cha(21), .text("d")],
                          screen: ["paste again to expand"])
        let lines = try stream()
        XCTAssertEqual(lines.last, "paste again to expand")
        XCTAssertFalse(lines.contains("paste gain to expad"))
    }

    func testUnchangedFrameEmitsNothing() throws {
        session.emitPaint([cup(1, 1), .text("status")], screen: ["status", "body"])
        session.emitPaint([cup(1, 1), .text("status")], screen: ["status", "body"])
        session.emitPaint([cup(2, 1)], screen: ["status", "body"])
        XCTAssertEqual(try stream(), ["status", "body"])
    }

    func testBlankRowsSeparateParagraphsButAreNotEmittedAlone() throws {
        session.emitPaint([cup(1, 1), .text("Title")],
                          screen: ["Title", "", "", "Body line", "", "❯"])
        XCTAssertEqual(try stream(), ["Title", "", "Body line", "", "❯"])
        // Clearing a row is not a line; a frame of blank changes contributes nothing.
        session.emitPaint([cup(4, 1), eraseLine], screen: ["Title", "", "", "", "", "❯"])
        XCTAssertEqual(try stream(), ["Title", "", "Body line", "", "❯"])
    }

    // MARK: - Synchronized output frames

    func testSyncFrameIsCapturedWhenItCloses() throws {
        // Chunk 1 ends mid-frame with the row half painted; chunk 2 finishes the row
        // and closes the frame. A mid-frame capture would be the torn repaint.
        session.emitPaint([syncOutput(true), cup(1, 1), .text("paste ")],
                          screen: ["paste"], inSync: true)
        XCTAssertEqual(try stream(), [], "nothing is captured while the frame is open")
        session.emitPaint([.text("again to expand"), syncOutput(false)],
                          screen: ["paste again to expand"], inSync: false)
        XCTAssertEqual(try stream(), ["paste again to expand"])
    }

    func testPrintArrivingInsideAnOpenFrameJoinsTheFrame() throws {
        // A chunk without any CSI while a frame is open is still part of the paint:
        // the frame carries its text, so it is not appended twice.
        session.emitPaint([syncOutput(true), cup(1, 1), .text("line one")],
                          screen: ["line one"], inSync: true)
        session.emitPaint([.text(" and more")], screen: ["line one and more"], inSync: true)
        session.emitPaint([syncOutput(false)], screen: ["line one and more"], inSync: false)
        XCTAssertEqual(try stream(), ["line one and more"])
    }

    func testCollectorFlushCapturesAFrameThatNeverCloses() {
        var collector = TerminalCaptureCollector()
        var buffer = TerminalStreamBuffer()
        collector.beginBurst()
        collector.observe(syncOutput(true))
        collector.observe(cup(1, 1))
        collector.observe(.text("final words"))
        let open = TerminalGridSnapshot(lines: ["final words"], cursorRow: 0, cursorCol: 0,
                                        cols: 80, rows: 1, isAltScreen: false,
                                        inSyncOutputMode: true)
        collector.endBurst(grid: open, scrolledOff: { _ in [] }, into: &buffer)
        XCTAssertTrue(collector.paintPending)
        XCTAssertEqual(buffer.page(cursor: 0, limit: 10).lines, [])
        // Exit: the frame will never close — capture what is on the screen.
        collector.flush(grid: open, scrolledOff: { _ in [] }, into: &buffer)
        XCTAssertFalse(collector.paintPending)
        XCTAssertEqual(buffer.page(cursor: 0, limit: 10).lines, ["final words"])
    }

    // MARK: - Scrolling

    func testScrolledRowsAreAlignedByAbsoluteIndex() throws {
        session.emitPaint([cup(1, 1), .text("A")], screen: ["A", "B", "C"])
        // The screen scrolled by two: A and B left the top, D and E arrived. Rows are
        // matched by absolute index, so C is recognised as unchanged.
        session.firstRowIndex = 2
        session.scrolledOff = ["A", "B"]
        session.emitPaint([cup(3, 1), .text("E")], screen: ["C", "D", "E"])
        XCTAssertEqual(try stream(), ["A", "B", "C", "D", "E"])
    }

    func testRowsThatScrolledOffBetweenCapturesComeFromScrollback() throws {
        session.emitPaint([cup(1, 1), .text("A")], screen: ["A", "B", "C"])
        // One burst pushed more than a screen of new rows through: D and E were
        // painted and scrolled off before the frame closed. Only scrollback has them.
        session.firstRowIndex = 5
        session.scrolledOff = ["A", "B", "C", "D", "E"]
        session.emitPaint([cup(3, 1), .text("H")], screen: ["F", "G", "H"])
        XCTAssertEqual(try stream(), ["A", "B", "C", "D", "E", "F", "G", "H"])
    }

    func testRowEditedBeforeScrollingOffIsCapturedWithItsFinalText() throws {
        session.emitPaint([cup(1, 1), .text("A")], screen: ["A", "B", "C"])
        // B was rewritten (a progress line finishing) and then scrolled off.
        session.firstRowIndex = 3
        session.scrolledOff = ["A", "B done", "C"]
        session.emitPaint([cup(1, 1), .text("D")], screen: ["D", "", ""])
        XCTAssertEqual(try stream(), ["A", "B", "C", "B done", "D"])
    }

    // MARK: - Print followed by paint (the everyday shell)

    func testPaintAfterPrintDoesNotRepeatThePrintedLines() throws {
        // `ls` prints; the shell then repaints its prompt with EL. The printed lines
        // are already in the stream, so the paint must add only the prompt row.
        session.screenLines = ["$ ls", "foo", "bar"]
        session.emitOutput("$ ls\nfoo\nbar\n")
        session.emitPaint([.control(0x0D), eraseLine, .text("❯ ")],
                          screen: ["$ ls", "foo", "bar", "❯ "])
        XCTAssertEqual(try stream(), ["$ ls", "foo", "bar", "❯ "])
    }

    func testOpenPrintedLineIsKeptWhenAPaintBegins() throws {
        session.screenLines = ["half a line"]   // the grid holds what was printed
        session.emitOutput("half a line")
        XCTAssertEqual(try stream(), ["half a line"], "the open line reads while it fills")
        session.emitPaint([cup(2, 1), .text("painted")], screen: ["half a line", "painted"])
        XCTAssertEqual(try stream(), ["half a line", "painted"])
    }

    // MARK: - Screens and respawn

    func testAltAndPrimaryScreensKeepSeparateBaselines() throws {
        session.emitPaint([cup(1, 1), .text("shell history")], screen: ["shell history"])
        session.isAltScreen = true
        session.emitPaint([.csi(TerminalControlSequence(params: [1049], finalByte: 0x68,
                                                        privateMarker: 0x3F)),
                           cup(1, 1), .text("pager page 1")], screen: ["pager page 1"])
        session.isAltScreen = false
        // Leaving the pager restores the primary screen unchanged: nothing to add.
        session.emitPaint([.csi(TerminalControlSequence(params: [1049], finalByte: 0x6C,
                                                        privateMarker: 0x3F))],
                          screen: ["shell history"])
        XCTAssertEqual(try stream(), ["shell history", "pager page 1"])
    }

    func testRespawnKeepsTheStreamAndResetsTheBaseline() throws {
        session.emitPaint([cup(1, 1), .text("first process")], screen: ["first process"])
        let summary = try service.respawn(paneKey: service.list().first!.paneKey)
        handle = summary.handle
        // The new engine's grid counts rows from zero again, so the same text at row 0
        // is new to the stream, not a repeat of the old incarnation's frame.
        session.emitPaint([cup(1, 1), .text("first process")], screen: ["first process"])
        XCTAssertEqual(try stream(), ["first process", "first process"])
    }
}
