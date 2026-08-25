import XCTest
@testable import OrchardTerminals

/// T52: the cleaned face of an archive must never say something the raw capture did
/// not say.
///
/// Dogfood cycle 3 read the Vault and found cleaned lines that had lost whitespace
/// *and* characters. Part of that damage is in the capture itself — a wide TUI paint
/// reaches the stream buffer with its empty cells never emitted, so the raw line is
/// already `Tipsforgettingstarted` and no cleaner can invent the spaces back. The
/// rest was the cleaner guessing: splitting `dogfood-t50-20260825` into
/// `dogfood-t 50-20260825`, splicing a better-spaced fragment of one line into the
/// middle of another. This file draws the line between the two: chrome may be
/// dropped, text may not be rewritten.
///
/// The checks below restate "chrome" independently of the implementation (their own
/// glyph set, their own tokenizer) so they audit the cleaner rather than echo it.
final class TerminalCaptureFidelityTests: XCTestCase {

    // MARK: - What the raw capture actually says

    private enum RawFacts {
        /// Glyphs a TUI draws as furniture: box rules, cell walls, block borders, and
        /// spinner frames. Deliberately spelled out here rather than imported from
        /// `TerminalCaptureCleaner` — a test that borrows the subject's definitions
        /// cannot catch the subject widening them.
        /// Rules, cell walls, and block borders.
        static let rules = Set<Character>("─━═╌┈╍╏│┃║╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬▁▂▃▔▌▐")
        /// Animation frames: one of these on a line means the TUI drew it, not a command.
        static let spinners = Set<Character>(
            "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⡿⣟⣯⣷⣾⣽⣻⢿✻✽✶✳✢✱✷◐◓◑◒◴◵◶◷⏺⏵⏸▪▫◆◇·•∗")
        static let chrome = rules.union(spinners)

        private static let escape = try! NSRegularExpression(
            pattern: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
                + "|\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
                + "|\u{1B}[@-Z\\\\-_]"
                + "|\u{1B}"
                + "|\\[[0-9;?]{0,8}[A-HJKSTfhlmnsu]|\\[[0-9]{3}~"
                + "|[\\x00-\\x08\\x0B-\\x1F\\x7F]")

        /// An escape sequence occupies no cells, but the fragments on either side of
        /// it were painted separately, so a boundary is the honest rendering.
        static func stripped(_ line: String) -> String {
            let range = NSRange(line.startIndex..., in: line)
            var value = escape.stringByReplacingMatches(in: line, range: range, withTemplate: " ")
            value = value.replacingOccurrences(of: "\u{00A0}", with: " ")
            value = value.replacingOccurrences(of: "\u{200B}", with: "")
            return value
        }

        /// The words the raw line contains, with chrome treated as a cell boundary.
        static func tokens(_ line: String) -> [String] {
            let spaced = String(stripped(line).map { chrome.contains($0) ? " " : $0 })
            return spaced.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        /// Every character the raw line said, minus chrome and spacing. Two lines with
        /// the same key are the same text painted with different spacing.
        static func key(_ line: String) -> String { tokens(line).joined() }
    }

    // MARK: - Fixtures

    private func capture(_ resource: String) throws -> [String] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(resource)", withExtension: "txt"),
            "fixture \(resource).txt is missing from the test bundle")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The three live captures the plan names, extracted from a *copy* of
    /// `~/Library/Application Support/Orchard/orchestration.db`
    /// (`worker_terminal_archives`, the `rawLines` field of the archived content).
    private static let captures = [
        ("T34", "claude-code-tui-capture"),
        ("T38", "claude-code-tui-capture-dogfood-2"),
        ("T50", "claude-code-tui-capture-t50"),
    ]

    // MARK: - The contract

    /// Every emitted line must be one raw line with its chrome taken off: same
    /// characters, same word boundaries. That single assertion covers both halves of
    /// the acceptance criterion — a join loses a boundary, a drop or an invented
    /// split changes the token list — and it leaves the cleaner exactly one honest
    /// move when it cannot improve a line: pass the raw line through.
    private func assertLinesAreFaithful(_ report: TerminalCaptureCleaner.Report,
                                        raw: [String], label: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        var rawByKey: [String: [[String]]] = [:]
        for rawLine in raw {
            let tokens = RawFacts.tokens(rawLine)
            guard !tokens.isEmpty else { continue }
            rawByKey[tokens.joined(), default: []].append(tokens)
        }

        var unsourced: [String] = []
        var reshaped: [(String, [String])] = []
        for cleaned in report.lines where !cleaned.isEmpty {
            let tokens = RawFacts.tokens(cleaned)
            guard let candidates = rawByKey[tokens.joined()] else {
                unsourced.append(cleaned)
                continue
            }
            if !candidates.contains(tokens) {
                reshaped.append((cleaned, candidates.first ?? []))
            }
        }

        XCTAssertTrue(unsourced.isEmpty,
                      "\(label): \(unsourced.count) cleaned line(s) carry characters no raw "
                        + "line has — text was invented or dropped:\n"
                        + unsourced.prefix(12).map { "  • \($0)" }.joined(separator: "\n"),
                      file: file, line: line)
        XCTAssertTrue(reshaped.isEmpty,
                      "\(label): \(reshaped.count) cleaned line(s) re-word a raw line — "
                        + "spaces were joined or invented:\n"
                        + reshaped.prefix(12)
                            .map { "  • \($0.0)\n    raw: \($0.1.joined(separator: " "))" }
                            .joined(separator: "\n"),
                      file: file, line: line)
    }

    func testEveryCleanedLineIsARawLineWithoutItsChrome() throws {
        for (label, resource) in Self.captures {
            let raw = try capture(resource)
            assertLinesAreFaithful(TerminalCaptureCleaner.clean(raw), raw: raw, label: label)
        }
    }

    /// A frame the cleaner exists to collapse: the spinner's progress readout and the
    /// status bar, both of which are redrawn (with different counters, and often torn
    /// mid-word) hundreds of times per capture. Recognised here by the marker glyphs
    /// they always carry — the ellipsis of a progress readout, the branch glyph of the
    /// status bar, a spinner frame — rather than by asking the cleaner what it thinks.
    private func isRepaintFrame(_ line: String) -> Bool {
        line.contains("…") || line.contains("⎇")
            || line.contains(where: { RawFacts.spinners.contains($0) })
    }

    /// The other half of "no character loss": a line of real work must not disappear.
    /// Chrome frames may be collapsed — that is the whole point — but a captured line
    /// with three words and twenty-four letters that is not a repaint frame has to
    /// reach the reader, with the same characters it was captured with.
    func testSubstantialRawLinesSurviveCleaning() throws {
        for (label, resource) in Self.captures {
            let raw = try capture(resource)
            let cleanedKeys = Set(TerminalCaptureCleaner.clean(raw).lines.map(RawFacts.key))
            var missing: [String] = []
            // The `orchard send` Swift-debug dump (dogfood-2) is dropped on purpose
            // and counted as `debugDumpLines`; it is machine spew, not work.
            for rawLine in raw where !isRepaintFrame(rawLine)
                && !rawLine.contains("OrchardProtocol.JSONValue") {
                let tokens = RawFacts.tokens(rawLine)
                guard tokens.count >= 3,
                      tokens.joined().filter({ $0.isLetter }).count >= 24 else { continue }
                if !cleanedKeys.contains(tokens.joined()) { missing.append(rawLine) }
            }
            XCTAssertTrue(missing.isEmpty,
                          "\(label): \(missing.count) substantive raw line(s) vanished:\n"
                            + missing.prefix(12).map { "  • \($0)" }.joined(separator: "\n"))
        }
    }
}
