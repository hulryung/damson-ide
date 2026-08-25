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
/// **The fidelity rule (T52).** Cleaning drops chrome; it never rewrites text. Every
/// line this emits is one captured line with its chrome taken off — same characters,
/// same word boundaries — with exactly one exception, spelled out below, that is
/// backed by another paint of the *same* characters. Dogfood cycle 3 found the Vault
/// reader showing lines the earlier passes had invented spaces into
/// (`term_f 91112 a 8-b 4 ac-…` for `term_f91112a8-b4ac-…`, `dogfood-t 50-20260825`,
/// `Git Hub`), because those passes guessed where the TUI's missing spaces belonged.
/// A guess that is right is unremarkable and a guess that is wrong is unreadable, so
/// the guessing is gone: when a captured line cannot be improved truthfully it is
/// passed through as captured.
///
/// That means some archives stay hard to read, and that is the honest outcome. A wide
/// paste reaches the stream buffer with its empty cells never emitted, so the *raw*
/// line already says `Tipsforgettingstarted`, and the T50 capture even lost letters
/// before Orchard saw it (`paste gain to expad` for "paste again to expand",
/// `coorinator` for "coordinator"). No cleaner can restore what the capture never
/// carried; inventing it is how you get a readable archive that says the wrong thing.
///
/// Stripping is still lossy at *line* granularity — a repaint stream cannot be
/// reconstructed into the exact frames a human saw — which is why the caller MUST
/// keep the untouched capture alongside the cleaned one (`worker-read --raw` serves
/// it). Every drop is counted in `Report` so a reader can tell how much was removed.
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
        /// Swift debug dumps of `JSONValue` (dogfood-2: `orchard send` without `--json`).
        public var debugDumpLines: Int
        /// Emitted lines whose spacing came from another capture line with exactly the
        /// same characters (see `spacingIndex`). The only text rewrite the cleaner
        /// performs, counted so a reader can see how often it fired.
        public var respacedLines: Int

        public var inputLineCount: Int {
            lines.count + separatorLines + spinnerLines + duplicateLines
                + blankLines + debugDumpLines
        }

        public init(lines: [String], separatorLines: Int = 0, spinnerLines: Int = 0,
                    duplicateLines: Int = 0, blankLines: Int = 0,
                    escapeRemnantLines: Int = 0, debugDumpLines: Int = 0,
                    respacedLines: Int = 0) {
            self.lines = lines
            self.separatorLines = separatorLines
            self.spinnerLines = spinnerLines
            self.duplicateLines = duplicateLines
            self.blankLines = blankLines
            self.escapeRemnantLines = escapeRemnantLines
            self.debugDumpLines = debugDumpLines
            self.respacedLines = respacedLines
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

    /// Shortest run of characters whose spacing may be taken from another capture
    /// line. Below this a collision is plausible (`12` and `1 2` are not obviously
    /// the same text), and the gain is not worth the doubt.
    static let respacingKeyFloor = 8

    /// Clean one captured tail.
    public static func clean(_ input: [String],
                             duplicateWindow: Int = TerminalCaptureCleaner.duplicateWindow) -> Report {
        var report = Report(lines: [])
        var window: [String] = []
        var squeezedWindow: [String] = []
        var maskedWindow: [String] = []
        var suffixWindow: [String] = []
        var lastEmittedWasBlank = true
        // Where the TUI painted the same characters twice, once with its space cells
        // and once without, the spaced paint is the one to show.
        let spacing = spacingIndex(input)

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
            var flattened = flattenSpinners(normalized)
            if isSwiftDebugDump(flattened) {
                report.debugDumpLines += 1
                continue
            }
            if isSpinnerResidue(flattened) {
                report.spinnerLines += 1
                continue
            }
            if let respaced = spacing[squeezeKey(flattened)],
               spaceCount(respaced) > spaceCount(flattened) {
                flattened = respaced
                report.respacedLines += 1
            }
            let squeezed = squeezeKey(flattened)
            // An exact repeat, or the same letters with different spacing, is a
            // repaint of the same frame. Both copies have already been respaced to
            // the best paint the capture holds, so the first one emitted is the one
            // to keep.
            if window.contains(flattened) || squeezedWindow.contains(squeezed) {
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
            squeezedWindow.append(squeezed)
            if chrome {
                maskedWindow.append(masked)
                suffixWindow.append(String(masked.suffix(20)))
            }
            if window.count > duplicateWindow {
                window.removeFirst()
                squeezedWindow.removeFirst()
            }
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
    ///
    /// Codes are stripped without joining adjacent cells: a remnant sitting between
    /// two printable fragments becomes a space, and interior box-drawing glyphs
    /// (the TUI's cell walls) become spaces rather than disappearing.
    static func normalize(_ line: String) -> (line: String, hadEscapeRemnant: Bool) {
        var value = line
        let before = value
        value = replacingWithoutJoining(escapeSequence, in: value)
        value = replacingWithoutJoining(orphanSequence, in: value)
        value = replacingWithoutJoining(controlCharacters, in: value)
        let hadRemnant = value != before
        // NBSP is how a TUI pads its prompt; it reads as a space, not as content.
        value = value.replacingOccurrences(of: "\u{00A0}", with: " ")
        value = value.replacingOccurrences(of: "\u{200B}", with: "")
        value = value.trimmingCharacters(in: .whitespaces)
        while let first = value.first, leadingBorders.contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        while let last = value.last, trailingBorders.contains(last) {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        value = value.trimmingCharacters(in: .whitespaces)
        // Pure rules stay rules so `isSeparator` still sees them; mixed lines have
        // interior walls turned into spaces instead of joining the cells.
        if isSeparator(value) { return (value, hadRemnant) }
        value = String(value.map { boxGlyphs.contains($0) ? " " : $0 })
        return (squeezeSpace(value.trimmingCharacters(in: .whitespaces)), hadRemnant)
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
        return squeezeSpace(replaced)
    }

    static func isSwiftDebugDump(_ line: String) -> Bool {
        line.contains("OrchardProtocol.JSONValue")
            || (line.contains("object([") && line.contains("JSONValue"))
    }

    static func isSpinnerResidue(_ line: String) -> Bool {
        if line.isEmpty { return true }
        if line == "❯" { return true }
        // No letters at all: a bare counter, a lone bracket run, stray punctuation.
        if !line.contains(where: { $0.isLetter }) { return true }
        // A progress line ("Levitating… (11s · ↓ 490 tokens)").
        if matches(progressLine, line) { return true }
        // A torn frame fragment: the tail of a word the next repaint finished, with
        // the spinner's frame counter still glued to it (`tg5`, `an9`, `Li3`). The
        // counter digit is what separates these from a real short line of output —
        // `ok`, `PASS` and `done` are content and must survive (T52).
        if line.count <= 4, !line.contains(" "), line.contains(where: { $0.isNumber }) {
            return true
        }
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

    // MARK: - Spacing

    /// The best-spaced paint of each distinct run of characters in the capture.
    ///
    /// This is the cleaner's only text rewrite, and it is not a guess: the
    /// replacement is another line of the *same capture* holding exactly the same
    /// characters in the same order, so the spaces it restores are ones the terminal
    /// really painted. Anything weaker — splicing a well-spaced fragment into the
    /// middle of a collapsed line, splitting `camelCase` runs, breaking before a
    /// `--flag` — invents boundaries the capture never had, which is what produced
    /// `term_f 91112 a 8-…` and `dogfood-t 50-20260825` in the Vault (T52).
    static func spacingIndex(_ input: [String]) -> [String: String] {
        var index: [String: String] = [:]
        for raw in input {
            let candidate = flattenSpinners(normalize(raw).line)
            guard candidate.contains(" ") else { continue }
            let key = squeezeKey(candidate)
            guard key.count >= respacingKeyFloor else { continue }
            if let existing = index[key], spaceCount(existing) >= spaceCount(candidate) {
                continue
            }
            index[key] = candidate
        }
        return index
    }

    static func squeezeSpace(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func squeezeKey(_ line: String) -> String {
        String(line.filter { !$0.isWhitespace })
    }

    private static func spaceCount(_ line: String) -> Int {
        line.reduce(0) { $0 + ($1.isWhitespace ? 1 : 0) }
    }

    // MARK: - Regex helpers

    /// Replace regex matches with nothing, inserting a single space when the match
    /// sat between two non-whitespace characters so adjacent fragments stay words.
    private static func replacingWithoutJoining(_ regex: NSRegularExpression,
                                                in value: String) -> String {
        guard !value.isEmpty else { return value }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard !matches.isEmpty else { return value }
        var result = ""
        var cursor = value.startIndex
        for match in matches {
            guard let range = Range(match.range, in: value) else { continue }
            result += value[cursor..<range.lowerBound]
            let left = result.last
            let right = range.upperBound < value.endIndex ? value[range.upperBound] : nil
            if let left, !left.isWhitespace, let right, !right.isWhitespace {
                result.append(" ")
            }
            cursor = range.upperBound
        }
        result += value[cursor...]
        return result
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
