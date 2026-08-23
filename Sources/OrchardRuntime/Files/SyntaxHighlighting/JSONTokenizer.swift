import Foundation

private let jsonKeywords: Set<String> = ["true", "false", "null"]

struct JSONTokenizer: LineTokenizer {
    func tokenize(line: String, baseUTF16: Int, start: TokenizerState)
        -> (tokens: [SyntaxToken], end: TokenizerState) {
        var scanner = SyntaxScanner(line: line, base: baseUTF16)
        var state = start
        if let top = state.frames.last, SyntaxFrame.isDoubleQuote(top) == true {
            scanString(&scanner, &state, consumeOpen: false)
        } else if state.frames.last.flatMap(SyntaxFrame.blockCommentDepth) != nil {
            scanBlockComment(&scanner, &state)
        }
        while !scanner.atEnd {
            scanner.skipWhitespace()
            guard !scanner.atEnd else { break }
            if scanner.peekIs("/") {
                // jsonc: // and /* */ so .jsonc files stay readable.
                if scanner.peekIs("/", offset: 1) {
                    let startC = scanner.i
                    scanner.i = scanner.length
                    scanner.emit(.comment, from: startC)
                    break
                }
                if scanner.peekIs("*", offset: 1) {
                    scanner.advance(2)
                    state.frames.append(SyntaxFrame.blockComment(1))
                    scanBlockComment(&scanner, &state, openedAt: scanner.i - 2)
                    continue
                }
            }
            if scanner.peekIs("\"") {
                state.frames.append(SyntaxFrame.quote(double: true))
                scanString(&scanner, &state, consumeOpen: true)
                continue
            }
            if let num = scanner.takeNumber(allowLeadingMinus: true, allowPrefixes: false) {
                scanner.emit(.number, from: num)
                continue
            }
            if let ident = scanner.takeIdent() {
                scanner.emitIdent(ident.text, from: ident.start, keywords: jsonKeywords)
                continue
            }
            scanner.advance()
        }
        return (scanner.tokens, state)
    }

    private func scanString(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState,
                            consumeOpen: Bool) {
        let start = scanner.i
        if consumeOpen { scanner.advance() }
        while !scanner.atEnd {
            if scanner.peekIs("\\") {
                scanner.advance()
                if !scanner.atEnd { scanner.advance() }
                continue
            }
            if scanner.peekIs("\"") {
                scanner.advance()
                scanner.emit(.string, from: start)
                if state.frames.last == SyntaxFrame.quote(double: true) {
                    state.frames.removeLast()
                }
                return
            }
            scanner.advance()
        }
        scanner.emit(.string, from: start)
    }

    private func scanBlockComment(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState,
                                  openedAt: Int? = nil) {
        guard SyntaxFrame.blockCommentDepth(state.frames.last ?? "") != nil else { return }
        let start = openedAt ?? scanner.i
        while !scanner.atEnd {
            if scanner.peekIs("*"), scanner.peekIs("/", offset: 1) {
                scanner.advance(2)
                scanner.emit(.comment, from: start)
                state.frames.removeLast()
                return
            }
            scanner.advance()
        }
        scanner.emit(.comment, from: start)
    }
}
