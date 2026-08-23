import Foundation

/// Turns a raw terminal-tail capture into readable text (T35, dogfood-1 finding 4).
///
/// A full-screen agent TUI repaints its frame many times per second, and the stream
/// buffer records every repaint as stacked fragments rather than overwriting them
/// (`TerminalStreamBuffer`'s deliberate "what happened" shape). Read back as an
/// archive that is 80% chrome: box borders, separator rules, spinner glyph runs,
/// half-painted status fragments, and the same footer frame repeated hundreds of
/// times. The real dogfood-1 archive was 1,594 lines for roughly 275 lines of
/// content.
///
/// This is deliberately lossy — a repaint stream cannot be reconstructed into the
/// exact frames a human saw — which is why the caller MUST keep the untouched
/// capture alongside the cleaned one (`worker-read --raw` serves it). Every drop is
/// counted in `Report` so a reader can tell how much was removed.
public enum TerminalCaptureCleaner {

    /// The cleaned lines plus a per-reason tally of what was dropped. The counts are
    /// receipt material, not debugging output: an archive whose `spinnerLines` dwarfs
    /// `lines.count` is telling the reader the agent spent the session thinking.
    public struct Report: Sendable, Equatable {
        public var lines: [String]
        /// Input lines that were pure box/rule chrome.
        public var separatorLines: Int
        /// Input lines that were spinner glyphs, progress fragments, or stray digits.
        public var spinnerLines: Int
        /// Input lines dropped because an equivalent line was emitted very recently —
        /// the repeated frame footer.
        public var duplicateLines: Int
        /// Blank lines beyond the first in a run.
        public var blankLines: Int
        /// Lines that still carried escape/control remnants after the VT parser.
        public var escapeRemnantLines: Int

        public var inputLineCount: Int {
            lines.count + separatorLines + spinnerLines + duplicateLines
                + blankLines
        }

        public init(lines: [String], separatorLines: Int = 0, spinnerLines: Int = 0,
                    duplicateLines: Int = 0, blankLines: Int = 0,
                    escapeRemnantLines: Int = 0) {
            self.lines = lines
            self.separatorLines = separatorLines
            self.spinnerLines = spinnerLines
            self.duplicateLines = duplicateLines
            self.blankLines = blankLines
            self.escapeRemnantLines = escapeRemnantLines
        }
    }

    /// How many previously emitted lines a repeat is compared against. The repeated
    /// chrome in a TUI capture is the input box + status bar (six or so lines) drawn
    /// between short bursts of content, so the window has to be wider than one frame
    /// but narrow enough that genuinely repeated content far apart still survives.
    public static let duplicateWindow = 40

    /// Spinner and bullet glyphs that appear as standalone animation frames. Runs of
    /// these carry no information once the animation is flattened into a text stream.
    static let spinnerGlyphs = Set<Character>(
        "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⡿⣟⣯⣷⣾⣽⣻⢿✻✽✶✳✢✱✷◐◓◑◒◴◵◶◷⏺⏵⏸▪▫◆◇·•∗")

    /// Box-drawing characters. A line made only of these (plus spaces) is a
    /// separator; at the edges of a line they are frame borders around real text.
    static let boxGlyphs = Set<Character>("─━═╌┈╍╏│┃║╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬▁▂▃▔")
    /// Separator detection also accepts the ASCII rules a plain script prints
    /// (`------`, `======`). Those characters are far too common inside ordinary text
    /// to mark a line as chrome on their own, so they are NOT in `boxGlyphs`.
    static let ruleGlyphs = boxGlyphs.union("-_=~")
    static let leadingBorders = Set<Character>("│┃║╭╰┌└├▌▐")
    static let trailingBorders = Set<Character>("│┃║╮╯┐┘┤▐▌")

    /// Glyphs no plain command emits but a TUI status bar, prompt, or tree connector
    /// always does. Their presence is what licenses the fuzzy (digit-insensitive,
    /// suffix-matching) duplicate passes: a status bar whose only difference between
    /// repaints is `$0.14` → `$0.17` is one frame drawn twice, while `wrote 3 files`
    /// followed by `wrote 4 files` is two facts and must both survive.
    static let chromeGlyphs = Set<Character>("⎇⎿❯⏎…↓↑⌘⇧✔✗◉○⧉")

    /// Full escape sequences the VT parser can still leave behind (OSC strings that
    /// were never terminated, CSI sequences split across reads, a lone ESC).
    private static let escapeSequence = try! NSRegularExpression(
        pattern: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
            + "|\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
            + "|\u{1B}[@-Z\\\\-_]"
            + "|\u{1B}")
    /// Orphaned sequence bodies: the ESC byte was consumed by the parser and only the
    /// `[…m` / `[2K` / `[?25l` / `[200~` tail reached the stream.
    private static let orphanSequence = try! NSRegularExpression(
        pattern: "\\[[0-9;?]{0,8}[A-HJKSTfhlmnsu]|\\[[0-9]{3}~")
    /// C0 controls (except TAB) and DEL that survived as literal characters.
    private static let controlCharacters = try! NSRegularExpression(
        pattern: "[\\x00-\\x08\\x0B-\\x1F\\x7F]")
    /// A progress line: an optional single word, an ellipsis, then only counters —
    /// `Levitating… (11s · ↓ 490 tokens)`, `Thinking…`, `i…2`.
    private static let progressLine = try! NSRegularExpression(
        pattern: "^[A-Za-z]{0,24}…")

    /// Clean one captured tail.
    public static func clean(_ input: [String],
                             duplicateWindow: Int = TerminalCaptureCleaner.duplicateWindow) -> Report {
        var report = Report(lines: [])
        var window: [String] = []
        var maskedWindow: [String] = []
        var suffixWindow: [String] = []
        var lastEmittedWasBlank = true

        for raw in input {
            let (normalized, hadRemnant) = normalize(raw)
            if hadRemnant { report.escapeRemnantLines += 1 }

            if normalized.isEmpty {
                // Blank lines are paragraph structure, so keep one per run and drop
                // the rest; leading blanks never start the archive.
                if lastEmittedWasBlank {
                    report.blankLines += 1
                } else {
                    report.lines.append("")
                    lastEmittedWasBlank = true
                }
                continue
            }
            if isSeparator(normalized) {
                report.separatorLines += 1
                continue
            }
            let flattened = flattenSpinners(normalized)
            if isSpinnerResidue(flattened) {
                report.spinnerLines += 1
                continue
            }
            // An exact repeat inside the window is a repaint of the same frame,
            // whatever the line says.
            if window.contains(flattened) {
                report.duplicateLines += 1
                continue
            }
            // For chrome lines only, two fuzzier passes: digits masked (the status
            // bar's cost/elapsed counters tick every frame) and a tail match (a torn
            // repaint glues a few characters of the previous frame onto the front of
            // the next one, as in `vathinking with xhigh effort`).
            let chrome = isChrome(normalized)
            let masked = maskDigits(flattened)
            let suffix = masked.count <= 60 ? String(masked.suffix(20)) : nil
            if chrome, maskedWindow.contains(masked)
                || (suffix.map { suffixWindow.contains($0) } ?? false) {
                report.duplicateLines += 1
                continue
            }
            report.lines.append(flattened)
            lastEmittedWasBlank = false
            window.append(flattened)
            if chrome {
                maskedWindow.append(masked)
                suffixWindow.append(String(masked.suffix(20)))
            }
            if window.count > duplicateWindow { window.removeFirst() }
            if maskedWindow.count > duplicateWindow {
                maskedWindow.removeFirst()
                suffixWindow.removeFirst()
            }
        }
        while let last = report.lines.last, last.isEmpty {
            report.lines.removeLast()
            report.blankLines += 1
        }
        return report
    }

    // MARK: - Line passes

    /// Strip escape remnants, control characters, and frame borders. Returns the
    /// trimmed line and whether anything escape-shaped was removed.
    static func normalize(_ line: String) -> (line: String, hadEscapeRemnant: Bool) {
        var value = line
        let before = value
        value = replacing(escapeSequence, in: value)
        value = replacing(orphanSequence, in: value)
        value = replacing(controlCharacters, in: value)
        let hadRemnant = value != before
        // NBSP is how a TUI pads its prompt; it reads as a space, not as content.
        value = value.replacingOccurrences(of: "\u{00A0}", with: " ")
        value = value.replacingOccurrences(of: "\u{200B}", with: "")
        value = value.trimmingCharacters(in: .whitespaces)
        while let first = value.first, leadingBorders.contains(first) {
            value.removeFirst()
        }
        while let last = value.last, trailingBorders.contains(last) {
            value.removeLast()
        }
        return (value.trimmingCharacters(in: .whitespaces), hadRemnant)
    }

    static func isSeparator(_ line: String) -> Bool {
        let core = line.filter { !$0.isWhitespace }
        return core.count >= 3 && core.allSatisfy { ruleGlyphs.contains($0) }
    }

    /// Replace spinner glyphs with spaces and squeeze the resulting whitespace, so a
    /// line that was `✻ Bash(…)` keeps its text and a line that was `✢509` becomes
    /// the bare counter the residue test then discards.
    static func flattenSpinners(_ line: String) -> String {
        guard line.contains(where: { spinnerGlyphs.contains($0) }) else { return line }
        let replaced = String(line.map { spinnerGlyphs.contains($0) ? " " : $0 })
        return replaced.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func isSpinnerResidue(_ line: String) -> Bool {
        if line.isEmpty { return true }
        if line == "❯" { return true }
        // No letters at all: a bare counter, a lone bracket run, stray punctuation.
        if !line.contains(where: { $0.isLetter }) { return true }
        // A progress line ("Levitating… (11s · ↓ 490 tokens)").
        if matches(progressLine, line) { return true }
        // A torn frame fragment: too short to be a sentence, and what is left is the
        // tail of a word the next repaint finished ("tg5", "an9", "Li3").
        if line.count <= 4 { return true }
        return false
    }

    /// Whether a line is TUI furniture rather than command output. Checked on the
    /// pre-flatten text so a line whose only chrome was its spinner still counts.
    static func isChrome(_ line: String) -> Bool {
        line.contains { chromeGlyphs.contains($0) || spinnerGlyphs.contains($0)
            || boxGlyphs.contains($0) }
    }

    static func maskDigits(_ line: String) -> String {
        guard line.contains(where: { $0.isNumber }) else { return line }
        var out = ""
        var inRun = false
        for character in line {
            if character.isNumber {
                if !inRun { out.append("#"); inRun = true }
            } else {
                out.append(character)
                inRun = false
            }
        }
        return out
    }

    // MARK: - Regex helpers

    private static func replacing(_ regex: NSRegularExpression, in value: String) -> String {
        guard !value.isEmpty else { return value }
        return regex.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
