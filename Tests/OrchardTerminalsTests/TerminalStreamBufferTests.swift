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
}
