import Foundation

/// Line-based highlighter: full-document tokenize for background passes, and
/// a neighborhood slice that starts at the nearest stable line-end state above
/// an edit so typing does not rescan the whole buffer on the main thread.
public enum SyntaxHighlightEngine: Sendable {
    /// Files past this UTF-8 size stay plain text (with a footer notice).
    public static let byteBudget = 128 * 1024
    /// Secondary cap so a tiny-but-huge-line-count buffer also degrades.
    public static let lineBudget = 6_000
    /// Sync re-highlight window around the caret / visible lines.
    public static let syncNeighborhoodLines = 80

    public static func exceedsBudget(_ text: String) -> Bool {
        if text.utf8.count > byteBudget { return true }
        var lines = 1
        for byte in text.utf8 where byte == 10 {
            lines += 1
            if lines > lineBudget { return true }
        }
        return false
    }

    public static func budgetNotice(for language: SyntaxLanguage) -> String {
        let kb = byteBudget / 1024
        if language == .plain {
            return "Plain text · over \(kb) KB highlight budget"
        }
        return "Plain text · \(language.displayName) highlighting skipped over \(kb) KB"
    }

    public static func splitLines(_ text: String) -> [SyntaxLine] {
        let ns = text as NSString
        let n = ns.length
        if n == 0 {
            return [SyntaxLine(startUTF16: 0, endUTF16: 0, breakUTF16: 0, content: "")]
        }
        var lines: [SyntaxLine] = []
        var i = 0
        while i < n {
            let start = i
            while i < n {
                let c = ns.character(at: i)
                if c == 10 || c == 13 { break }
                i += 1
            }
            let end = i
            if i < n {
                let c = ns.character(at: i)
                i += 1
                if c == 13, i < n, ns.character(at: i) == 10 {
                    i += 1
                }
            }
            lines.append(SyntaxLine(
                startUTF16: start,
                endUTF16: end,
                breakUTF16: i,
                content: ns.substring(with: NSRange(location: start, length: end - start))))
        }
        if n > 0 {
            let last = ns.character(at: n - 1)
            if last == 10 || last == 13 {
                lines.append(SyntaxLine(startUTF16: n, endUTF16: n, breakUTF16: n, content: ""))
            }
        }
        return lines
    }

    public static func lineIndex(utf16Offset: Int, in lines: [SyntaxLine]) -> Int {
        guard !lines.isEmpty else { return 0 }
        let clamped = max(0, utf16Offset)
        for (idx, line) in lines.enumerated() {
            if clamped < line.breakUTF16 { return idx }
        }
        return lines.count - 1
    }

    /// Walk backward to the first line whose *previous* line ended stable.
    public static func nearestRetokenizeLine(editLine: Int, endStates: [TokenizerState]) -> Int {
        var line = min(max(0, editLine), endStates.count)
        while line > 0 {
            if endStates[line - 1].isStable { return line }
            line -= 1
        }
        return 0
    }

    public static func highlightDocument(_ text: String, language: SyntaxLanguage) -> HighlightResult {
        let lines = splitLines(text)
        let slice = highlightLines(
            lines, language: language, fromLine: 0,
            throughLine: max(0, lines.count - 1), startState: .normal)
        return HighlightResult(
            tokens: slice.tokens,
            lineEndStates: slice.lineEndStates,
            lineCount: lines.count)
    }

    public static func highlightLines(
        _ text: String,
        language: SyntaxLanguage,
        fromLine: Int,
        throughLine: Int,
        startState: TokenizerState
    ) -> HighlightSlice {
        highlightLines(splitLines(text), language: language, fromLine: fromLine,
                       throughLine: throughLine, startState: startState)
    }

    public static func highlightLines(
        _ lines: [SyntaxLine],
        language: SyntaxLanguage,
        fromLine: Int,
        throughLine: Int,
        startState: TokenizerState
    ) -> HighlightSlice {
        guard !lines.isEmpty else {
            return HighlightSlice(tokens: [], lineEndStates: [], fromLine: 0,
                                  throughLine: 0, utf16Location: 0, utf16Length: 0)
        }
        let from = min(max(0, fromLine), lines.count - 1)
        let through = min(max(from, throughLine), lines.count - 1)
        let tokenizer = tokenizer(for: language)
        var state = startState
        var tokens: [SyntaxToken] = []
        var endStates: [TokenizerState] = []
        endStates.reserveCapacity(through - from + 1)
        for idx in from...through {
            let line = lines[idx]
            let out = tokenizer.tokenize(line: line.content, baseUTF16: line.startUTF16, start: state)
            tokens.append(contentsOf: out.tokens)
            state = out.end
            endStates.append(state)
        }
        let loc = lines[from].startUTF16
        let end = lines[through].breakUTF16
        return HighlightSlice(
            tokens: tokens,
            lineEndStates: endStates,
            fromLine: from,
            throughLine: through,
            utf16Location: loc,
            utf16Length: max(0, end - loc))
    }

    public static func neighborhoodThroughLine(
        editLine: Int,
        visible: Range<Int>?,
        lineCount: Int
    ) -> Int {
        let margin = syncNeighborhoodLines
        var through = min(lineCount - 1, editLine + margin)
        if let visible, !visible.isEmpty {
            through = min(lineCount - 1, max(through, visible.upperBound - 1 + 20))
        }
        return max(0, through)
    }

    static func tokenizer(for language: SyntaxLanguage) -> any LineTokenizer {
        switch language {
        case .swift: return SwiftTokenizer()
        case .json: return JSONTokenizer()
        case .yaml: return YAMLTokenizer()
        case .markdown: return MarkdownTokenizer()
        case .shell: return ShellTokenizer()
        case .plain: return PlainTokenizer()
        }
    }
}
