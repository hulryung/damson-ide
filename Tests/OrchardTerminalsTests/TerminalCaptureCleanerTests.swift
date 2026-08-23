import XCTest
@testable import OrchardTerminals

/// T35 (dogfood-1 finding 4): the terminal-tail archive must read as text.
///
/// The headline test runs the stripper over the verbatim archive Orchard pinned in
/// dogfood cycle 1 — a real Claude Code session, not a hand-written imitation — and
/// asserts both halves of the contract: the chrome is gone, and every line of real
/// work survives.
final class TerminalCaptureCleanerTests: XCTestCase {

    // MARK: - The real capture

    private func dogfoodCapture() throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/claude-code-tui-capture",
                              withExtension: "txt"),
            "the dogfood-1 capture fixture is missing from the test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // trailing newline, not a line
        return lines
    }

    func testRealDogfoodCaptureBecomesReadableText() throws {
        let raw = try dogfoodCapture()
        XCTAssertEqual(raw.count, 1594, "the fixture must stay the untouched capture")

        let report = TerminalCaptureCleaner.clean(raw)

        // Roughly six out of every seven captured lines are repaint chrome. The bound
        // is loose on purpose — this asserts "the noise is gone", not an exact ratio.
        XCTAssertLessThan(report.lines.count, raw.count / 4,
                          "cleaning removed too little: \(report.lines.count) of \(raw.count)")
        XCTAssertGreaterThan(report.lines.count, 100,
                             "cleaning removed too much to still be a transcript")
        XCTAssertGreaterThan(report.separatorLines, 50)
        XCTAssertGreaterThan(report.spinnerLines, 200)
        XCTAssertGreaterThan(report.duplicateLines, 100)

        let cleaned = report.lines

        // Every substantive thing the worker did survives.
        for expected in [
            "You are working inside Orchard, a multi-agent IDE. You are a dispatched worker.",
            "(eval):1: command not found: orchard",
            "\"code\": \"run_required\",",
            "Cogitated for 1m 51s",
        ] {
            XCTAssertTrue(cleaned.contains { $0.contains(expected) },
                          "cleaning dropped real content: \(expected)")
        }

        // And the chrome does not.
        XCTAssertFalse(cleaned.contains { TerminalCaptureCleaner.isSeparator($0) },
                       "a separator rule survived")
        XCTAssertFalse(cleaned.contains { $0.contains("✻") || $0.contains("✳") || $0.contains("⠋") },
                       "a spinner glyph survived")
        XCTAssertFalse(cleaned.contains { $0.hasPrefix("│") || $0.hasSuffix("│") },
                       "a box border survived")
        XCTAssertFalse(cleaned.contains { $0.contains("\u{1B}") },
                       "an escape byte survived")

        // The repeated footer frame is drawn on every repaint; it must appear a
        // handful of times, not hundreds.
        let footers = cleaned.filter { $0.contains("bypass") && $0.contains("permissions") }
        XCTAssertLessThan(footers.count, 12,
                          "the status footer was not collapsed: \(footers.count) copies")
    }

    /// The counts are receipt material, so they have to add up against the input.
    func testReportAccountsForEveryInputLine() throws {
        let raw = try dogfoodCapture()
        let report = TerminalCaptureCleaner.clean(raw)
        XCTAssertEqual(report.inputLineCount, raw.count)
    }

    // MARK: - Individual passes

    func testStripsEscapeRemnantsAndControlCharacters() {
        let report = TerminalCaptureCleaner.clean([
            "\u{1B}[38;5;244mdimmed text\u{1B}[0m",
            "\u{1B}]0;window title\u{07}building the thing",
            "[?25lhidden cursor marker",
            "bell\u{07}and\u{08}backspace",
        ])
        XCTAssertEqual(report.lines, [
            "dimmed text",
            "building the thing",
            "hidden cursor marker",
            "bell and backspace",
        ])
        XCTAssertEqual(report.escapeRemnantLines, 4)
    }

    /// Stripping a remnant between two printables must not glue them into one word.
    func testStrippingCodesDoesNotJoinAdjacentFragments() {
        let report = TerminalCaptureCleaner.clean([
            "Sent\u{1B}[0mworker_done\u{1B}[0mwith --outcome succeeded",
        ])
        XCTAssertEqual(report.lines, ["Sent worker_done with --outcome succeeded"])
    }

    func testDropsSeparatorRulesAndBoxBorders() {
        let report = TerminalCaptureCleaner.clean([
            "╭──────────────────╮",
            "│ real content     │",
            "──────────────────",
            "──────────────────",
            "╰──────────────────╯",
        ])
        XCTAssertEqual(report.lines, ["real content"])
        XCTAssertEqual(report.separatorLines, 4)
    }

    func testDropsSpinnerRunsAndProgressFragments() {
        let report = TerminalCaptureCleaner.clean([
            "⠋",
            "✳ Levitating… (11s · ↓ 490 tokens)",
            "✢509",
            "Levitating…296",
            "✻ Bash(git status)",
        ])
        XCTAssertEqual(report.lines, ["Bash(git status)"])
        XCTAssertEqual(report.spinnerLines, 4)
    }

    /// A repaint stream stacks the same status bar with only its counters moving, so
    /// chrome lines are deduplicated with digits masked. Plain command output is not:
    /// two lines that differ only in a number are two facts.
    func testCollapsesCounterChurnOnChromeButNotOnCommandOutput() {
        let report = TerminalCaptureCleaner.clean([
            "Opus 5 | …/worktree | ⎇ branch | $0.14",
            "Opus 5 | …/worktree | ⎇ branch | $0.17",
            "Opus 5 | …/worktree | ⎇ branch | $0.20",
            "wrote 3 files",
            "wrote 4 files",
        ])
        XCTAssertEqual(report.lines, [
            "Opus 5 | …/worktree | ⎇ branch | $0.14",
            "wrote 3 files",
            "wrote 4 files",
        ])
        XCTAssertEqual(report.duplicateLines, 2)
    }

    /// The exact-repeat pass is unconditional: a byte-identical line inside the
    /// window is a repaint even with no chrome glyph on it.
    func testCollapsesExactRepeatsOfPlainLines() {
        let report = TerminalCaptureCleaner.clean([
            "Update available! Run: brew upgrade claude-code@latest",
            "checking",
            "Update available! Run: brew upgrade claude-code@latest",
        ])
        XCTAssertEqual(report.lines, [
            "Update available! Run: brew upgrade claude-code@latest",
            "checking",
        ])
        XCTAssertEqual(report.duplicateLines, 1)
    }

    /// A numbered run from a shell worker is content, not chrome, and survives whole.
    func testNumberedCommandOutputSurvives() {
        let input = (1...12).map { "ok \($0) - assertion passed" }
        XCTAssertEqual(TerminalCaptureCleaner.clean(input).lines, input)
    }

    func testCollapsesBlankRunsButKeepsParagraphBreaks() {
        let report = TerminalCaptureCleaner.clean([
            "", "", "first", "", "", "", "second", "", "",
        ])
        XCTAssertEqual(report.lines, ["first", "", "second"])
    }

    /// A window bound means a line repeated far later is content, not chrome.
    func testRepeatsOutsideTheWindowAreKept() {
        var input = ["marker"]
        input.append(contentsOf: (0..<50).map { "filler line \(Self.word($0)) of the run" })
        input.append("marker")
        let report = TerminalCaptureCleaner.clean(input)
        XCTAssertEqual(report.lines.filter { $0 == "marker" }.count, 2)
    }

    /// Distinct filler text, so the window fills with 50 genuinely different lines.
    private static func word(_ index: Int) -> String {
        String(repeating: "ab", count: 3 + index % 7) + "-" + String(index, radix: 36)
    }

    func testCleanTextIsLeftAlone() {
        let input = [
            "$ swift build",
            "Compiling OrchardTerminals TerminalCaptureCleaner.swift",
            "Build complete!",
        ]
        let report = TerminalCaptureCleaner.clean(input)
        XCTAssertEqual(report.lines, input)
        XCTAssertEqual(report.separatorLines, 0)
        XCTAssertEqual(report.spinnerLines, 0)
        XCTAssertEqual(report.duplicateLines, 0)
    }

    func testEmptyCaptureStaysEmpty() {
        let report = TerminalCaptureCleaner.clean([])
        XCTAssertEqual(report.lines, [])
        XCTAssertEqual(report.inputLineCount, 0)
    }

    /// A collapsed TUI paint of the same letters as a well-spaced raw line must
    /// keep the spaced original, not the concatenated one.
    func testPrefersRawCaptureSpacingOverCollapsedRepaint() {
        let report = TerminalCaptureCleaner.clean([
            "Update available! Run: brew upgrade claude-code@latest",
            "Updateavailable!Run:brewupgradeclaude-code@latest",
            "Orchard dogfood T38 completed",
            "OrcharddogfoodT38completed$",
            "/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard send --from",
            "Bash(/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchardsend--from",
        ])
        let joined = report.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Update available! Run: brew upgrade claude-code@latest"), joined)
        XCTAssertFalse(joined.contains("Updateavailable!"), joined)
        XCTAssertTrue(joined.contains("Orchard dogfood T38 completed"), joined)
        XCTAssertFalse(joined.contains("OrcharddogfoodT38completed"), joined)
        XCTAssertTrue(joined.contains("orchard send --from"), joined)
        XCTAssertFalse(joined.contains("orchardsend"), joined)
    }

    func testDropsSwiftDebugJSONValueDump() {
        let report = TerminalCaptureCleaner.clean([
            #"object(["type":OrchardProtocol.JSONValue.string("worker_done"),"count":OrchardProtocol.JSONValue.number(1.0"#,
            #"),"lifecycle":OrchardProtocol.JSONValue.object(["taskId":OrchardProtocol.JSONValue.string("task_a2cfa1d1dcd"#,
            "real work survived",
        ])
        XCTAssertEqual(report.lines, ["real work survived"])
        XCTAssertEqual(report.debugDumpLines, 2)
        XCTAssertEqual(report.inputLineCount, 3)
    }

    // MARK: - Dogfood cycle 2

    private func dogfood2Capture() throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/claude-code-tui-capture-dogfood-2",
                              withExtension: "txt"),
            "the dogfood-2 capture fixture is missing from the test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    func testDogfood2CapturePreservesWordSpacingAndDropsSendDump() throws {
        let raw = try dogfood2Capture()
        XCTAssertEqual(raw.count, 630, "the fixture must stay the untouched capture")

        let report = TerminalCaptureCleaner.clean(raw)
        XCTAssertEqual(report.inputLineCount, raw.count)
        XCTAssertGreaterThan(report.debugDumpLines, 0)

        let cleaned = report.lines.joined(separator: "\n")
        XCTAssertTrue(cleaned.contains("orchard send"), cleaned)
        XCTAssertFalse(cleaned.contains("orchardsend"),
                       "collapsed orchard+send survived: \(cleaned)")
        XCTAssertTrue(cleaned.contains("Orchard dogfood T38 completed"), cleaned)
        XCTAssertFalse(cleaned.contains("OrcharddogfoodT38completed"),
                       "collapsed scratch-file line survived")
        XCTAssertFalse(cleaned.contains("OrchardProtocol.JSONValue"),
                       "Swift debug dump leaked into the readable face")
        XCTAssertFalse(cleaned.contains("object(["),
                       "Swift debug dump leaked into the readable face")
    }
}
