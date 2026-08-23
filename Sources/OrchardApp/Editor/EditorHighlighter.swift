import AppKit
import OrchardRuntime

/// Applies tokenizer output to an `NSTextView` without touching the string.
///
/// Sync work is only the visible/edited neighborhood. A full-file pass runs on
/// a serial background queue on open (and after edits, debounced) so a long
/// comment or string can catch up without blocking keystrokes.
final class EditorHighlighter {
    private let queue = DispatchQueue(label: "orchard.editor.highlight", qos: .userInitiated)
    private var generation = 0
    private var lineEndStates: [TokenizerState] = []
    private var fullyApplied = false
    private var pendingFull: DispatchWorkItem?

    var language: SyntaxLanguage = .plain
    var enabled = false
    weak var textView: NSTextView?

    func restart() {
        generation += 1
        pendingFull?.cancel()
        lineEndStates = []
        fullyApplied = false
        guard enabled, language != .plain, let textView else {
            clearColors()
            return
        }
        let text = textView.string
        highlightNeighborhood(in: textView, text: text, editUTF16: 0)
        scheduleFull(text: text, debounce: 0)
    }

    func documentDidEdit(editUTF16: Int) {
        generation += 1
        fullyApplied = false
        guard enabled, language != .plain, let textView else { return }
        let text = textView.string
        highlightNeighborhood(in: textView, text: text, editUTF16: editUTF16)
        scheduleFull(text: text, debounce: 0.12)
    }

    func visibleDidChange() {
        guard enabled, !fullyApplied, language != .plain, let textView else { return }
        highlightNeighborhood(in: textView, text: textView.string,
                              editUTF16: textView.selectedRange().location)
    }

    func disable() {
        generation += 1
        pendingFull?.cancel()
        enabled = false
        fullyApplied = true
        lineEndStates = []
        clearColors()
    }

    private func highlightNeighborhood(in textView: NSTextView, text: String, editUTF16: Int) {
        let lines = SyntaxHighlightEngine.splitLines(text)
        let editLine = SyntaxHighlightEngine.lineIndex(utf16Offset: editUTF16, in: lines)
        let visible = visibleLines(in: textView, lines: lines)
        let from = SyntaxHighlightEngine.nearestRetokenizeLine(
            editLine: editLine, endStates: lineEndStates)
        let through = SyntaxHighlightEngine.neighborhoodThroughLine(
            editLine: editLine, visible: visible, lineCount: lines.count)
        let startState: TokenizerState
        if from == 0 {
            startState = .normal
        } else if from - 1 < lineEndStates.count {
            startState = lineEndStates[from - 1]
        } else {
            startState = .normal
        }
        let slice = SyntaxHighlightEngine.highlightLines(
            lines, language: language, fromLine: from, throughLine: through,
            startState: startState)
        merge(slice: slice, lineCount: lines.count)
        apply(tokens: slice.tokens, location: slice.utf16Location, length: slice.utf16Length,
              in: textView)
    }

    private func scheduleFull(text: String, debounce: TimeInterval) {
        pendingFull?.cancel()
        let gen = generation
        let lang = language
        let work = DispatchWorkItem { [weak self] in
            self?.queue.async {
                let result = SyntaxHighlightEngine.highlightDocument(text, language: lang)
                DispatchQueue.main.async {
                    self?.applyFull(result, text: text, generation: gen)
                }
            }
        }
        pendingFull = work
        if debounce <= 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
        }
    }

    private func applyFull(_ result: HighlightResult, text: String, generation gen: Int) {
        guard generation == gen, enabled, language != .plain, let textView else { return }
        guard textView.string == text else { return }
        lineEndStates = result.lineEndStates
        fullyApplied = true
        let length = (text as NSString).length
        apply(tokens: result.tokens, location: 0, length: length, in: textView)
    }

    private func merge(slice: HighlightSlice, lineCount: Int) {
        var next = lineEndStates
        if next.count > lineCount {
            next = Array(next.prefix(lineCount))
        }
        if next.count < lineCount {
            next.append(contentsOf: Array(repeating: TokenizerState.normal,
                                          count: lineCount - next.count))
        }
        for (offset, state) in slice.lineEndStates.enumerated() {
            let idx = slice.fromLine + offset
            if idx < next.count {
                next[idx] = state
            }
        }
        lineEndStates = next
    }

    private func apply(tokens: [SyntaxToken], location: Int, length: Int, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let limit = storage.length
        let range = NSIntersectionRange(
            NSRange(location: location, length: length),
            NSRange(location: 0, length: limit))
        guard range.length > 0 || limit == 0 else { return }
        if range.length == 0 { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: EditorSyntaxTheme.default, range: range)
        if let font = textView.font {
            storage.addAttribute(.font, value: font, range: range)
        }
        for token in tokens where token.kind != .text {
            let tokenRange = NSIntersectionRange(
                NSRange(location: token.utf16Location, length: token.utf16Length),
                range)
            if tokenRange.length > 0 {
                storage.addAttribute(
                    .foregroundColor,
                    value: EditorSyntaxTheme.color(for: token.kind),
                    range: tokenRange)
            }
        }
        storage.endEditing()
    }

    private func clearColors() {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
        let range = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: EditorSyntaxTheme.default, range: range)
        if let font = textView.font {
            storage.addAttribute(.font, value: font, range: range)
        }
        storage.endEditing()
    }

    private func visibleLines(in textView: NSTextView, lines: [SyntaxLine]) -> Range<Int>? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return nil
        }
        let glyph = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let chars = layout.characterRange(forGlyphRange: glyph, actualGlyphRange: nil)
        if chars.length == 0 {
            return 0..<1
        }
        let start = SyntaxHighlightEngine.lineIndex(utf16Offset: chars.location, in: lines)
        let end = SyntaxHighlightEngine.lineIndex(
            utf16Offset: chars.location + max(0, chars.length - 1), in: lines)
        return start..<(end + 1)
    }
}
