import XCTest
@testable import OrchardTerminals

/// The accumulated-stream half of `terminal read`: line assembly from parsed tokens,
/// absolute-index cursor paging, and the ring's drop-from-front truncation contract.
final class TerminalStreamBufferTests: XCTestCase {

    func testLineAssemblyAndCRLFCountsOnce() {
        var buffer = TerminalStreamBuffer()
        buffer.appendText("hello")
        buffer.appendControl(0x0D)   // CR
        buffer.appendControl(0x0A)   // LF of the same CRLF — one break, not two
        buffer.appendText("world")
        let page = buffer.page(cursor: 0, limit: 10)
        XCTAssertEqual(page.lines, ["hello", "world"])
    }

    func testBareCRStacksRepaintFragments() {
        // A program that repaints one line with bare CRs must show up as stacked
        // fragments — that is the documented stream-vs-screen difference.
        var buffer = TerminalStreamBuffer()
        buffer.appendText("progress 10%")
        buffer.appendControl(0x0D)
        buffer.appendText("progress 90%")
        let page = buffer.page(cursor: 0, limit: 10)
        XCTAssertEqual(page.lines, ["progress 10%", "progress 90%"])
    }

    func testCursorPagingWalksForward() {
        var buffer = TerminalStreamBuffer()
        for i in 1...5 { buffer.appendText("line\(i)"); buffer.appendControl(0x0A) }

        let first = buffer.page(cursor: 0, limit: 2)
        XCTAssertEqual(first.lines, ["line1", "line2"])
        XCTAssertEqual(first.nextCursor, 2)
        XCTAssertFalse(first.truncated)

        let second = buffer.page(cursor: first.nextCursor, limit: 2)
        XCTAssertEqual(second.lines, ["line3", "line4"])

        // Following the cursor past the end returns an empty page, not an error —
        // "nothing new yet" is a normal answer for a live terminal.
        let end = buffer.page(cursor: 100, limit: 2)
        XCTAssertEqual(end.lines, [])
        XCTAssertEqual(end.nextCursor, buffer.latestCursor)
    }

    func testDefaultReadReturnsTail() {
        var buffer = TerminalStreamBuffer()
        for i in 1...10 { buffer.appendText("line\(i)"); buffer.appendControl(0x0A) }
        let page = buffer.page(cursor: nil, limit: 3)
        XCTAssertEqual(page.lines, ["line8", "line9", "line10"])
    }

    func testOpenLineIsVisibleButNeverSkipped() {
        var buffer = TerminalStreamBuffer()
        buffer.appendText("one")
        buffer.appendControl(0x0A)
        buffer.appendText("$ ")   // a prompt with no newline — must be readable
        let page = buffer.page(cursor: 0, limit: 10)
        XCTAssertEqual(page.lines, ["one", "$ "])
        // …but the cursor must not advance past it: its later content would be lost.
        XCTAssertEqual(page.nextCursor, 1)
        buffer.appendText("make")
        XCTAssertEqual(buffer.page(cursor: page.nextCursor, limit: 10).lines, ["$ make"])
    }

    func testRingDropsOldestAndReportsTruncation() {
        var buffer = TerminalStreamBuffer(maxLines: 5)
        for i in 1...20 { buffer.appendText("line\(i)"); buffer.appendControl(0x0A) }
        XCTAssertEqual(buffer.oldestCursor, 16, "16 of 21 lines (incl. open line) dropped")

        // A cursor below the ring's floor is served from the floor, flagged truncated.
        let page = buffer.page(cursor: 0, limit: 10)
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.lines.first, "line17")

        // A cursor inside the retained window is not truncated.
        let ok = buffer.page(cursor: buffer.oldestCursor, limit: 2)
        XCTAssertFalse(ok.truncated)
    }

    func testPreviewTailSkipsBlankLines() {
        var buffer = TerminalStreamBuffer()
        buffer.appendText("real output")
        buffer.appendControl(0x0A)
        buffer.appendControl(0x0A)
        XCTAssertEqual(buffer.previewTail, "real output")
    }

    func testPerLineLengthCap() {
        var buffer = TerminalStreamBuffer(maxLines: 10, maxLineLength: 8)
        buffer.appendText("0123456789abcdef")
        buffer.appendText("more")
        let page = buffer.page(cursor: 0, limit: 1)
        XCTAssertEqual(page.lines, ["01234567"])
    }

    // MARK: - T58 paint-tick coalescing

    /// Uncoalesced fill times T54 §6 quoted: 10 fps into the default ring, and into
    /// the 2_000-line `terminal_tail` archive WorkerVerbs takes at release.
    func testPaintHeavyFillTimeWithoutCoalesce() {
        let fps = 10
        XCTAssertEqual(10_000 / fps, 1_000, "default ring fills in 1_000 s ≈ 16.7 min")
        XCTAssertEqual(2_000 / fps, 200, "terminal_tail of 2_000 lines fills in 200 s ≈ 3.3 min")
    }

    func testSustainedSpinnerDoesNotEvictRecentRealOutput() {
        // A ring that 50 ticks would overflow if each tick appended.
        var buffer = TerminalStreamBuffer(maxLines: 20)
        buffer.appendCapturedRow("REAL: git clone done")
        for i in 1...50 {
            buffer.appendCapturedRow("✶ Thinking… (\(i)s · ↓ \(i * 10) tokens)")
        }
        buffer.appendCapturedRow("REAL: all tests passed")

        let page = buffer.page(cursor: 0, limit: 50)
        XCTAssertFalse(page.truncated, "spinner ticks must not push real output off the ring")
        XCTAssertEqual(page.lines.first, "REAL: git clone done")
        XCTAssertEqual(page.lines.last, "REAL: all tests passed")
        XCTAssertEqual(page.lines.filter { $0.contains("Thinking") }.count, 1)
        XCTAssertEqual(page.lines, [
            "REAL: git clone done",
            "✶ Thinking… (50s · ↓ 500 tokens)",
            "REAL: all tests passed",
        ])
        XCTAssertEqual(buffer.coalescedTickCount, 49)
        XCTAssertEqual(buffer.oldestCursor, 0)
    }

    func testSpinnerGerundRotationStillCoalesces() {
        // Claude Code rotates the gerund as well as the glyph; those are still one
        // thinking phase, not 10 new lines per second.
        var buffer = TerminalStreamBuffer(maxLines: 8)
        buffer.appendCapturedRow("prompt")
        buffer.appendCapturedRow("✢ Thinking… (1s · ↓ 10 tokens)")
        buffer.appendCapturedRow("✶ Improvising… (2s · ↓ 25 tokens)")
        buffer.appendCapturedRow("✻ Levitating… (3s · ↓ 63 tokens)")
        let page = buffer.page(cursor: 0, limit: 10)
        XCTAssertEqual(page.lines, ["prompt", "✻ Levitating… (3s · ↓ 63 tokens)"])
        XCTAssertEqual(buffer.coalescedTickCount, 2)
        XCTAssertFalse(page.truncated)
    }

    func testSpinnerAfterRealOutputStartsANewSlot() {
        var buffer = TerminalStreamBuffer()
        buffer.appendCapturedRow("✢ Thinking… (4s · ↓ 181 tokens)")
        buffer.appendCapturedRow("wrote src/main.swift")
        buffer.appendCapturedRow("✶ Thinking… (1s · ↓ 10 tokens)")
        buffer.appendCapturedRow("✻ Thinking… (2s · ↓ 25 tokens)")
        XCTAssertEqual(buffer.page(cursor: 0, limit: 10).lines, [
            "✢ Thinking… (4s · ↓ 181 tokens)",
            "wrote src/main.swift",
            "✻ Thinking… (2s · ↓ 25 tokens)",
        ])
        XCTAssertEqual(buffer.coalescedTickCount, 1)
    }

    func testSpinnerCoalesceWalksBackThroughBlanks() {
        var buffer = TerminalStreamBuffer()
        buffer.appendCapturedRow("real")
        buffer.appendCapturedRow("✢ Thinking… (1s · ↓ 10 tokens)")
        buffer.appendCapturedRow("")
        buffer.appendCapturedRow("✶ Thinking… (2s · ↓ 25 tokens)")
        XCTAssertEqual(buffer.page(cursor: 0, limit: 10).lines, [
            "real",
            "✶ Thinking… (2s · ↓ 25 tokens)",
            "",
        ])
        XCTAssertEqual(buffer.coalescedTickCount, 1)
    }

    func testPrintedCRProgressStillStacks() {
        // Coalesce is paint-capture only. A program that prints progress with bare
        // CR still stacks fragments — the documented stream-vs-screen difference.
        var buffer = TerminalStreamBuffer(maxLines: 5)
        buffer.appendText("progress 10%")
        buffer.appendControl(0x0D)
        buffer.appendText("progress 90%")
        buffer.appendControl(0x0D)
        buffer.appendText("progress 100%")
        XCTAssertEqual(buffer.page(cursor: 0, limit: 10).lines, [
            "progress 10%", "progress 90%", "progress 100%",
        ])
        XCTAssertEqual(buffer.coalescedTickCount, 0)
    }

    func testNonSpinnerCapturedRowsDoNotCoalesce() {
        var buffer = TerminalStreamBuffer()
        buffer.appendCapturedRow("wrote 3 files")
        buffer.appendCapturedRow("wrote 4 files")
        buffer.appendCapturedRow("paste again to expand")
        XCTAssertEqual(buffer.page(cursor: 0, limit: 10).lines, [
            "wrote 3 files", "wrote 4 files", "paste again to expand",
        ])
        XCTAssertEqual(buffer.coalescedTickCount, 0)
    }

    func testCoalesceDoesNotShiftCursors() {
        var buffer = TerminalStreamBuffer()
        buffer.appendCapturedRow("real")
        buffer.appendCapturedRow("✢ Thinking… (1s · ↓ 10 tokens)")
        let afterFirst = buffer.latestCursor
        buffer.appendCapturedRow("✶ Thinking… (2s · ↓ 25 tokens)")
        XCTAssertEqual(buffer.latestCursor, afterFirst, "in-place replace must not mint a new index")
        let page = buffer.page(cursor: 0, limit: 10)
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.lines, ["real", "✶ Thinking… (2s · ↓ 25 tokens)"])
    }

    func testSustainedSpinnerOnTinyRingKeepsTranscript() {
        // 10 fps for well longer than the ring: 200 ticks into 6 slots.
        var buffer = TerminalStreamBuffer(maxLines: 6)
        buffer.appendCapturedRow("start of session")
        buffer.appendCapturedRow("running swift test")
        for i in 1...200 {
            buffer.appendCapturedRow("✶ Working… (\(i)s · ↓ \(i) tokens)")
        }
        buffer.appendCapturedRow("Test Suite 'All tests' passed")
        let page = buffer.page(cursor: 0, limit: 20)
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.lines.first, "start of session")
        XCTAssertTrue(page.lines.contains("running swift test"))
        XCTAssertEqual(page.lines.last, "Test Suite 'All tests' passed")
        XCTAssertEqual(page.lines.filter { $0.contains("Working") }.count, 1)
    }
}
