import Foundation

/// The accumulated-text side of `terminal read`: a bounded ring of parsed output lines
/// with absolute-index cursor paging.
///
/// This answers a different question than the rendered grid. The stream is every text
/// token the PTY ever emitted, in arrival order, with escape sequences already stripped
/// by the VT parser — so a TUI that repaints a line contributes stacked fragments, one
/// per repaint, instead of overwriting. That is the correct shape for "what happened",
/// while `--screen` answers "what is shown"; `TerminalReadResult.source` names which
/// one the caller got.
///
/// Cursors are absolute line indices that stay valid as the ring drops old lines: index
/// 0 is the first line ever emitted, and a request below `oldestCursor` is served from
/// the oldest retained line with `truncated: true` so a reader knows it missed output.
///
/// **Capacity (T58).** A paint-heavy agent TUI ticks a spinner row at ~10 fps. At that
/// rate the default 10_000-line ring fills in 1_000 s (~16.7 min) and a `terminal_tail`
/// archive of the newest 2_000 lines is all spinner after 200 s (~3.3 min) — evicting
/// the transcript behind it. A larger ring or a byte budget only delays that. Captured
/// spinner/progress ticks therefore coalesce in place: inside `tickCoalesceWindow` the
/// latest tick overwrites the previous one, so a sustained spinner occupies one slot
/// and cannot push recent real output off the ring. Printed CR-stacked fragments are
/// not coalesced (the stream-vs-screen contract). Cursors do not shift: a replace
/// mutates the retained line at its existing absolute index.
public struct TerminalStreamBuffer: Sendable {
    /// Retained lines; `lines[0]` is absolute index `droppedLineCount`. The final
    /// element is the current, still-open line (possibly empty).
    private var lines: [String] = [""]
    /// How many lines the ring has dropped from the front — the absolute index offset.
    private var droppedLineCount = 0
    /// Whether the last control byte was CR, so a following LF is one break, not two.
    private var lastControlWasCR = false

    /// Maximum retained lines. Beyond it the oldest lines fall off the ring. Spinner
    /// ticks do not consume this budget (they coalesce); 10_000 is hours of real
    /// agent output, not ~17 minutes of paint.
    public let maxLines: Int
    /// Per-line length cap — a pathological no-newline stream must not grow unbounded.
    public let maxLineLength: Int

    /// How far back a captured spinner/progress tick may overwrite an earlier tick
    /// instead of appending. Walks through trailing blanks only and stops at any
    /// other content, so a later thinking phase after real output keeps its own slot.
    public static let tickCoalesceWindow = 8

    /// Captured spinner/progress rows that overwrote an earlier tick instead of
    /// growing the ring. Diagnostic: the coalesced ticks are not in `page`.
    public private(set) var coalescedTickCount = 0

    public init(maxLines: Int = 10_000, maxLineLength: Int = 4_096) {
        precondition(maxLines > 0)
        self.maxLines = maxLines
        self.maxLineLength = maxLineLength
    }

    // MARK: - Ingest

    /// Append a printed-text token to the current line.
    public mutating func appendText(_ text: String) {
        lastControlWasCR = false
        guard var current = lines.popLast() else { return }
        if current.count < maxLineLength {
            current += text.prefix(maxLineLength - current.count)
        }
        lines.append(current)
    }

    /// Feed one C0 control byte. Only line structure matters here: LF ends the line;
    /// a bare CR also ends it when it holds text (that is how a repaint arrives as a
    /// stacked fragment rather than an overwrite); CRLF counts once; TAB becomes a tab
    /// character; everything else (BS/BEL/…) is ignored.
    public mutating func appendControl(_ byte: UInt8) {
        switch byte {
        case 0x0A: // LF — but a CRLF pair already broke on the CR.
            if !lastControlWasCR { breakLine() }
            lastControlWasCR = false
        case 0x0D: // CR
            if let current = lines.last, !current.isEmpty { breakLine() }
            lastControlWasCR = true
        case 0x09: // TAB
            appendText("\t")
        default:
            lastControlWasCR = false
        }
    }

    /// Append one complete line captured from the rendered grid (T54 frame capture).
    /// A still-open printed line is closed first, exactly as a CR would close it, so a
    /// prompt that was mid-print when a repaint began is kept — never overwritten or
    /// joined with the captured row.
    ///
    /// A spinner/progress tick of a still-retained recent tick is overwritten in
    /// place (T58) so a 10 fps paint does not fill the ring.
    public mutating func appendCapturedRow(_ row: String) {
        if let current = lines.last, !current.isEmpty { breakLine() }
        lastControlWasCR = false
        let capped = row.count <= maxLineLength ? row : String(row.prefix(maxLineLength))
        if let idx = coalesceIndex(for: capped) {
            lines[idx] = capped
            coalescedTickCount += 1
            return
        }
        appendText(capped)
        breakLine()
    }

    /// Index of a still-retained spinner/progress tick that `row` should overwrite,
    /// or nil to append. Only captured paint uses this; printed output stacks.
    ///
    /// Walks back through trailing blanks only: a tick at the tail (the 10 fps case)
    /// overwrites, and a later thinking phase after real output keeps a new slot.
    /// Crossing real output would either reorder history or collapse two phases.
    private func coalesceIndex(for row: String) -> Int? {
        guard paintTickKey(row) != nil else { return nil }
        // `lines.last` is the open line (empty after the close above); search
        // completed lines only, newest first, bounded by the window.
        let completedCount = max(0, lines.count - 1)
        guard completedCount > 0 else { return nil }
        let span = min(Self.tickCoalesceWindow, completedCount)
        for offset in 0..<span {
            let idx = completedCount - 1 - offset
            if lines[idx].isEmpty { continue }
            if paintTickKey(lines[idx]) != nil { return idx }
            return nil
        }
        return nil
    }

    /// Spinner glyph or gerund-ellipsis progress (`Thinking… (4s · ↓ 181 tokens)`).
    /// Status bars and boxed content are not in this family, so they cannot overwrite
    /// a spinner or be overwritten by one.
    private func paintTickKey(_ line: String) -> String? {
        guard !line.isEmpty else { return nil }
        if line.contains(where: { TerminalCaptureCleaner.spinnerGlyphs.contains($0) }) {
            return "$progress"
        }
        let flattened = TerminalCaptureCleaner.flattenSpinners(line)
        if flattened.contains("…"), TerminalCaptureCleaner.isSpinnerResidue(flattened) {
            return "$progress"
        }
        return nil
    }

    private mutating func breakLine() {
        lines.append("")
        if lines.count > maxLines {
            let excess = lines.count - maxLines
            lines.removeFirst(excess)
            droppedLineCount += excess
        }
    }

    // MARK: - Paging

    public struct Page: Sendable {
        /// The returned lines (a non-empty still-open current line included when in
        /// range, so a shell prompt or half-printed line is readable).
        public let lines: [String]
        /// Absolute index of `lines.first` (equal to `nextCursor` when empty).
        public let startCursor: Int
        /// Pass this back to continue reading where this page ended. Never advances
        /// past the last *completed* line: a page that showed the open line will show
        /// it again (with more content) on the next read — at-least-once per line,
        /// never a silently missed suffix.
        public let nextCursor: Int
        /// The requested cursor pointed below the ring's oldest retained line —
        /// output between the two was dropped and cannot be replayed.
        public let truncated: Bool
    }

    /// Oldest absolute index still retained.
    public var oldestCursor: Int { droppedLineCount }
    /// The follow cursor: one past the newest *completed* line. Reading from here
    /// returns the open line (as it fills) and then everything after it.
    public var latestCursor: Int { droppedLineCount + lines.count - 1 }

    /// Read up to `limit` lines. `cursor: nil` means "the tail": the newest `limit`
    /// lines. A cursor at or past the end returns an empty page (nothing new yet).
    public func page(cursor: Int?, limit: Int) -> Page {
        let limit = max(1, limit)
        let completedEnd = latestCursor
        // The open line is visible only while it holds text.
        let visibleEnd = droppedLineCount + lines.count - ((lines.last?.isEmpty ?? true) ? 1 : 0)
        let requested = cursor ?? max(oldestCursor, visibleEnd - limit)
        let start = min(max(requested, oldestCursor), visibleEnd)
        let sliceEnd = min(start + limit, visibleEnd)
        let slice = Array(lines[(start - droppedLineCount)..<(sliceEnd - droppedLineCount)])
        return Page(lines: slice,
                    startCursor: start,
                    nextCursor: min(sliceEnd, completedEnd),
                    truncated: requested < oldestCursor)
    }

    /// The newest non-blank line, for listing previews. Empty when nothing printed yet.
    public var previewTail: String {
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
