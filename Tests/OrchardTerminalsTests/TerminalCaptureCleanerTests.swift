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
    /// keep the spaced original, not the concatenated one. The two lines have to
    /// hold *exactly* the same characters — that equality is the proof that the
    /// spaces being restored are ones the terminal really painted.
    func testPrefersRawCaptureSpacingOverCollapsedRepaint() {
        let report = TerminalCaptureCleaner.clean([
            "Update available! Run: brew upgrade claude-code@latest",
            "Updateavailable!Run:brewupgradeclaude-code@latest",
        ])
        XCTAssertEqual(report.lines, ["Update available! Run: brew upgrade claude-code@latest"])
        XCTAssertEqual(report.duplicateLines, 1)
        XCTAssertEqual(report.respacedLines, 1)
    }

    /// The order does not matter: the collapsed paint is repaired even when it is the
    /// first one captured, because the spacing index is built over the whole capture.
    func testRespacesACollapsedLineThatIsCapturedFirst() {
        let report = TerminalCaptureCleaner.clean([
            "Updateavailable!Run:brewupgradeclaude-code@latest",
            "checking",
            "Update available! Run: brew upgrade claude-code@latest",
        ])
        XCTAssertEqual(report.lines,
                       ["Update available! Run: brew upgrade claude-code@latest", "checking"])
    }

    /// T52 (dogfood-3, Vault reader). Corrected from the T38-era expectation that a
    /// collapsed line should be repaired from a *similar* line: `orchardsend--from`
    /// and `OrcharddogfoodT38completed$` have no equally-lettered paint anywhere in
    /// the capture — only lines that contain them, or that they contain. Splicing
    /// those neighbours in is a guess about where the missing spaces went, and the
    /// same machinery that guessed `orchard send --from` right also produced
    /// `term_f 91112 a 8-b 4 ac-…` and `dogfood-t 50-20260825` in the live archives.
    /// A capture that lost its spaces stays hard to read; it must not become easy to
    /// read and wrong. `worker-read --raw` was always the evidence path, and now the
    /// cleaned face is evidence too.
    func testCollapsedLineWithNoEquallyLetteredPaintIsPassedThrough() {
        let input = [
            "Orchard dogfood T38 completed",
            "OrcharddogfoodT38completed$",
            "/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchard send --from",
            "Bash(/Users/dkkang/Library/Caches/orchard/Orchard.app/Contents/Helpers/orchardsend--from",
        ]
        let report = TerminalCaptureCleaner.clean(input)
        XCTAssertEqual(report.lines, input)
        XCTAssertEqual(report.respacedLines, 0)
    }

    /// Word boundaries are never invented, however tempting the shape of the run:
    /// an identifier, a path, or a version string collapsed by the TUI stays one
    /// token rather than becoming `term_f 91112 a 8-…` (dogfood-3).
    func testNeverInventsWordBoundariesInACollapsedRun() {
        let input = [
            "ClaudeCodev2.1.239",
            "~/…/worktrees/damson-ide/dogfood-t50-20260825",
            "term_f91112a8-b4ac-48a4-96a8-5bf6bee5ee77",
            "Slack,GitHubcomments,oranyotherchanneltoreachahumanduringtherun.",
            "orchardsend--fromterm_0cc6eaa9--dispatch-capability",
        ]
        XCTAssertEqual(TerminalCaptureCleaner.clean(input).lines, input)
    }

    /// Dropping a line is the cleaner's job; dropping a line of real output is not.
    /// Short command output used to be discarded as a torn spinner fragment.
    func testShortRealOutputSurvives() {
        let input = ["ok", "PASS", "done", "yes", "3 ok"]
        XCTAssertEqual(TerminalCaptureCleaner.clean(input).lines, input)
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

    /// T52 correction: the two `XCTAssertFalse` checks that demanded the *collapsed*
    /// spellings disappear are gone. They could only be satisfied by splicing text
    /// from a neighbouring line, which is the pass dogfood-3 caught mangling live
    /// archives (see `testCollapsedLineWithNoEquallyLetteredPaintIsPassedThrough`).
    /// What this capture still proves is the part that was always sound: the
    /// well-spaced paints reach the reader, and the Swift debug dump does not.
    func testDogfood2CapturePreservesWordSpacingAndDropsSendDump() throws {
        let raw = try dogfood2Capture()
        XCTAssertEqual(raw.count, 630, "the fixture must stay the untouched capture")

        let report = TerminalCaptureCleaner.clean(raw)
        XCTAssertEqual(report.inputLineCount, raw.count)
        XCTAssertGreaterThan(report.debugDumpLines, 0)

        let cleaned = report.lines.joined(separator: "\n")
        XCTAssertTrue(cleaned.contains("orchard send --from"), cleaned)
        XCTAssertTrue(cleaned.contains("Orchard dogfood T38 completed"), cleaned)
        XCTAssertFalse(cleaned.contains("OrchardProtocol.JSONValue"),
                       "Swift debug dump leaked into the readable face")
        XCTAssertFalse(cleaned.contains("object(["),
                       "Swift debug dump leaked into the readable face")
    }

    // MARK: - Dogfood cycle 3 (T50)

    private func dogfood3Capture() throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/claude-code-tui-capture-t50",
                              withExtension: "txt"),
            "the T50 capture fixture is missing from the test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The capture that the T52 complaint was written against.
    ///
    /// Every mangled line dogfood-3 quoted out of the Vault reader is quoted back
    /// here — and every one of them is character-for-character what the capture
    /// holds. This session ran in a wide terminal whose paste never emitted its
    /// empty cells, so the stream buffer received `Tipsforgettingstarted`, and the
    /// paint that reached it was torn on top of that: "paste again to expand" was
    /// captured as `paste gain to expad`, "coordinator" as `coorinator`. The cleaner
    /// did not do that and cannot undo it. What it must do is not add to it.
    func testT50CapturePassesThroughWhatItCannotCleanFaithfully() throws {
        let raw = try dogfood3Capture()
        XCTAssertEqual(raw.count, 430, "the fixture must stay the untouched capture")

        let report = TerminalCaptureCleaner.clean(raw)
        XCTAssertEqual(report.inputLineCount, raw.count)
        let cleaned = report.lines

        // Damage that is already in the capture is reproduced exactly, not guessed at.
        for asCaptured in [
            "Tipsforgettingstarted",
            "paste gain to expad",
            "Your coordinator's terminalhandleis:cli",
            "You talk tohe coorinatoronlythroughtheCLIcommandsbelow.Donotuse",
            "Taskcompleteanddispatchsettled.",
        ] {
            XCTAssertTrue(cleaned.contains(asCaptured),
                          "the reader must see the capture verbatim: \(asCaptured)")
        }

        // And no boundary the capture never had is invented on top of it.
        let joined = cleaned.joined(separator: "\n")
        for invented in ["dogfood-t 50", "Claude Codev 2.1.239", "Git Hub", "its Task ID"] {
            XCTAssertFalse(joined.contains(invented),
                           "the cleaner invented a word boundary: \(invented)")
        }

        // The work still reads, and the chrome is still gone.
        XCTAssertTrue(cleaned.contains {
            $0.contains("git status --porcelain shows only ?? orchard-dogfood-t50.txt")
        }, "the worker's verification line was lost")
        XCTAssertGreaterThan(report.separatorLines, 15)
        XCTAssertGreaterThan(report.spinnerLines, 150)
        XCTAssertGreaterThan(report.duplicateLines, 20)
        XCTAssertFalse(cleaned.contains { TerminalCaptureCleaner.isSeparator($0) })
        XCTAssertFalse(cleaned.contains { $0.contains("✻") || $0.contains("✳") || $0.contains("⠋") })
        XCTAssertFalse(cleaned.contains { $0.contains("\u{1B}") })
    }
}
