import XCTest
@testable import OrchardTerminals

/// T57 (dogfood cycle 4): the first `terminal_tail` archive pinned *after* T54.
///
/// The three earlier fixtures were captured from the pre-T54 stream, where a wide
/// TUI paint reached the buffer with its empty cells never emitted
/// (`Tipsforgettingstarted`) and torn repaints dropped letters (`coorinator`). T54
/// captures a cursor-addressed paint from the frame instead, so an archive should now
/// hold whole rows. This file pins the fourth fixture —
/// `Fixtures/claude-code-tui-capture-t57.txt`, dispatch `ctx_cc1a74b0234a`, extracted
/// from a copy of `orchestration.db` with only the capability secret redacted — and
/// asserts the shape the live `worker-release` / `worker-read` receipts reported for
/// it (docs/reports/dogfood-4.md), so the in-tree cleaner is measured against the
/// post-T54 shape and not only against damage it can no longer see.
final class PostT54CaptureFixtureTests: XCTestCase {

    // MARK: - Fixture

    private func t57Capture() throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/claude-code-tui-capture-t57",
                              withExtension: "txt"),
            "the T57 capture fixture is missing from the test bundle")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Chrome glyphs, restated here rather than imported from the cleaner so the test
    /// cannot inherit a widened definition. Same sets `TerminalCaptureFidelityTests`
    /// uses for the three pre-T54 fixtures.
    private static let rules = Set<Character>("─━═╌┈╍╏│┃║╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬▁▂▃▔▌▐")
    private static let spinners = Set<Character>(
        "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⡿⣟⣯⣷⣾⣽⣻⢿✻✽✶✳✢✱✷◐◓◑◒◴◵◶◷⏺⏵⏸▪▫◆◇·•∗")
    private static let chrome = rules.union(spinners)

    /// The words a line contains, with chrome treated as a cell boundary.
    private static func tokens(_ line: String) -> [String] {
        let spaced = String(line.map { chrome.contains($0) ? " " : $0 })
        return spaced.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    // MARK: - The raw capture is whole rows

    /// What T54 promised: rows as the grid showed them. The archive is 380 lines, none
    /// wider than the 120-column pane, none carrying escape or control bytes, and the
    /// text that pre-T54 captures collapsed or tore arrives with its spaces and letters.
    func testRawCaptureHoldsWholeRows() throws {
        let raw = try t57Capture()
        XCTAssertEqual(raw.count, 380, "the fixture must stay the untouched capture")
        XCTAssertEqual(raw.map(\.count).max(), 120, "rows come from a 120-column grid")
        XCTAssertFalse(raw.contains { line in
            line.unicodeScalars.contains { $0 == "\u{1B}" || ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }
        }, "the VT parser ran: no escape or control bytes reach the archive")

        let joined = raw.joined(separator: "\n")
        // The exact sites the pre-T54 fixtures collapsed or tore (T50 fixture, T52 §1).
        for whole in [
            "Tips for getting started",
            "paste again to expand",
            "Your coordinator's terminal handle is: cli",
            "You talk to the coordinator only through the CLI commands below. Do not use",
            "Slack, GitHub comments, or any other channel to reach a human during the run.",
            "Welcome back Daekeun!",
        ] {
            XCTAssertTrue(joined.contains(whole), "captured whole: \(whole)")
        }
        for damage in [
            "Tipsforgettingstarted", "paste gain to expad", "coorinator", "terminalhandleis",
            "onlythrough", "Donotuse", "Taskcompleteanddispatchsettled",
        ] {
            XCTAssertFalse(joined.contains(damage), "pre-T54 damage shape reappeared: \(damage)")
        }
    }

    // MARK: - The cleaned shape

    /// The numbers the live runtime reported for this archive at release
    /// (`worker-release` receipt 282B2160…, `worker-read` receipt 4C086E9D…:
    /// 380 captured, 166 readable, 152 spinner, 17 separator, 39 duplicate, 6 blank,
    /// 0 escape remnants, 0 respaced). Pinned exactly: the in-tree cleaner must
    /// reproduce the archive a caller actually got back. `respacedLines == 0` is the
    /// T54 point — whole rows leave the cleaner nothing to re-space.
    func testCleanedShapeMatchesTheLiveReceipt() throws {
        let raw = try t57Capture()
        let report = TerminalCaptureCleaner.clean(raw)

        XCTAssertEqual(report.inputLineCount, 380)
        XCTAssertEqual(report.lines.count, 166)
        XCTAssertEqual(report.spinnerLines, 152)
        XCTAssertEqual(report.separatorLines, 17)
        XCTAssertEqual(report.duplicateLines, 39)
        XCTAssertEqual(report.blankLines, 6)
        XCTAssertEqual(report.escapeRemnantLines, 0)
        XCTAssertEqual(report.debugDumpLines, 0)
        XCTAssertEqual(report.respacedLines, 0, "whole rows leave nothing to re-space")
    }

    /// Chrome off, work in: no rule line and no spinner frame survives, while the
    /// preamble, the worker's own verification, and its `worker_done` all read whole.
    func testCleanedTextIsTheWorkWithoutTheChrome() throws {
        let cleaned = TerminalCaptureCleaner.clean(try t57Capture()).lines
        let joined = cleaned.joined(separator: "\n")

        XCTAssertFalse(cleaned.contains { TerminalCaptureCleaner.isSeparator($0) })
        XCTAssertFalse(cleaned.contains { line in
            let trimmed = line.drop(while: { $0.isWhitespace })
            return trimmed.first.map(Self.spinners.contains) == true
                && (trimmed.contains("Effecting…") || trimmed.contains("Cooked for"))
        }, "spinner progress frames must not reach the reader")

        for work in [
            "Tips for getting started",
            "paste again to expand",
            "Your coordinator's terminal handle is: cli",
            "You talk to the coordinator only through the CLI commands below. Do not use",
            "Orchard dogfood T57 verified capture fidelity after the T54 seam fix",
            "?? orchard-dogfood-t57.txt",
            "File is 69 bytes, and git status --porcelain shows only the untracked file. Sending worker_done now.",
            "sent worker_done",
        ] {
            XCTAssertTrue(joined.contains(work), "the reader must see: \(work)")
        }
    }

    /// No joined words: the only run of sixteen or more letters in the cleaned text is
    /// an identifier Claude Code's release notes printed as one word. Any other such
    /// run would be two words with their space lost — the exact failure the pre-T54
    /// fixtures are full of (`OrcharddogfoodT38completed`, `Tipsforgettingstarted`).
    func testNoJoinedWordsSurviveCleaning() throws {
        let cleaned = TerminalCaptureCleaner.clean(try t57Capture()).lines
        var runs = Set<String>()
        for captured in cleaned {
            // The pin's only edit: the capability secret, replaced in place by
            // `REDACTED` repeated to its width. Not capture text; skipped.
            let line = captured.replacingOccurrences(of: "dcap_REDACTEDREDACTEDREDACTEDREDACTED",
                                                     with: "dcap_")
            var run = ""
            for character in line + " " {
                if character.isLetter { run.append(character); continue }
                if run.count >= 16 { runs.insert(run) }
                run = ""
            }
        }
        XCTAssertEqual(runs, ["subagentPromptCacheTtl"],
                       "unexpected long letter runs — words were joined: \(runs.sorted())")
    }

    /// Every cleaned line is one raw line with its chrome taken off — same characters,
    /// same word boundaries — and no substantial raw line vanished. The same contract
    /// `TerminalCaptureFidelityTests` holds the three pre-T54 fixtures to, applied to
    /// the post-T54 one.
    func testEveryCleanedLineIsARawLineWithoutItsChrome() throws {
        let raw = try t57Capture()
        let cleaned = TerminalCaptureCleaner.clean(raw).lines

        var rawByKey: [String: [[String]]] = [:]
        for line in raw {
            let tokens = Self.tokens(line)
            if !tokens.isEmpty { rawByKey[tokens.joined(), default: []].append(tokens) }
        }
        var unsourced: [String] = []
        var reshaped: [String] = []
        for line in cleaned where !line.isEmpty {
            let tokens = Self.tokens(line)
            guard let candidates = rawByKey[tokens.joined()] else { unsourced.append(line); continue }
            if !candidates.contains(tokens) { reshaped.append(line) }
        }
        XCTAssertTrue(unsourced.isEmpty, "cleaned lines with characters no raw line has:\n"
                        + unsourced.prefix(8).map { "  • \($0)" }.joined(separator: "\n"))
        XCTAssertTrue(reshaped.isEmpty, "cleaned lines whose spacing no raw line has:\n"
                        + reshaped.prefix(8).map { "  • \($0)" }.joined(separator: "\n"))

        let cleanedKeys = Set(cleaned.map { Self.tokens($0).joined() })
        let vanished = raw.filter { line in
            let tokens = Self.tokens(line)
            let isRepaintFrame = line.contains("…") || line.contains("⎇")
                || line.contains(where: Self.spinners.contains)
            return !isRepaintFrame && tokens.count >= 3
                && tokens.joined().filter(\.isLetter).count >= 24
                && !cleanedKeys.contains(tokens.joined())
        }
        XCTAssertTrue(vanished.isEmpty, "substantive raw lines vanished:\n"
                        + vanished.prefix(8).map { "  • \($0)" }.joined(separator: "\n"))
    }
}
