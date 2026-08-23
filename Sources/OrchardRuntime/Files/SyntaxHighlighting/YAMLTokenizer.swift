import Foundation

private let yamlKeywords: Set<String> = [
    "true", "false", "null", "True", "False", "Null", "TRUE", "FALSE", "NULL",
    "yes", "no", "Yes", "No", "YES", "NO", "on", "off", "On", "Off", "ON", "OFF",
    "~",
]

struct YAMLTokenizer: LineTokenizer {
    func tokenize(line: String, baseUTF16: Int, start: TokenizerState)
        -> (tokens: [SyntaxToken], end: TokenizerState) {
        var scanner = SyntaxScanner(line: line, base: baseUTF16)
        var state = start

        if let indent = state.frames.last.flatMap(SyntaxFrame.yamlIndent) {
            let leading = scanner.leadingIndent()
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if !blank && leading <= indent {
                state.frames.removeLast()
            } else {
                if !scanner.atEnd {
                    let startC = scanner.i
                    scanner.i = scanner.length
                    scanner.emit(.string, from: startC)
                }
                return (scanner.tokens, state)
            }
        }

        if let top = state.frames.last, let dbl = SyntaxFrame.isDoubleQuote(top) {
            scanQuoted(&scanner, &state, double: dbl, consumeOpen: false)
        }

        while !scanner.atEnd {
            scanner.skipWhitespace()
            guard !scanner.atEnd else { break }

            if scanner.peekIs("#") {
                let startC = scanner.i
                scanner.i = scanner.length
                scanner.emit(.comment, from: startC)
                break
            }

            if scanner.peekIs("\"") {
                state.frames.append(SyntaxFrame.quote(double: true))
                scanQuoted(&scanner, &state, double: true, consumeOpen: true)
                continue
            }
            if scanner.peekIs("'") {
                state.frames.append(SyntaxFrame.quote(double: false))
                scanQuoted(&scanner, &state, double: false, consumeOpen: true)
                continue
            }

            if isBlockScalarIndicator(scanner) {
                let indent = scanner.leadingIndent()
                let startC = scanner.i
                scanner.advance()
                if scanner.peekIs("+") || scanner.peekIs("-") { scanner.advance() }
                while let c = scanner.peek(), scanner.isDigit(c) { scanner.advance() }
                scanner.emit(.keyword, from: startC)
                scanner.skipWhitespace()
                if scanner.peekIs("#") {
                    let c0 = scanner.i
                    scanner.i = scanner.length
                    scanner.emit(.comment, from: c0)
                } else {
                    scanner.i = scanner.length
                }
                state.frames.append(SyntaxFrame.yamlBlock(indent))
                break
            }

            if scanner.peekIs("-"), scanner.peek(1).map(scanner.isWhitespace) == true
                || scanner.peek(1) == nil {
                let startC = scanner.i
                scanner.advance()
                scanner.emit(.keyword, from: startC)
                continue
            }

            if let num = scanner.takeNumber(allowLeadingMinus: true, allowPrefixes: false) {
                scanner.emit(.number, from: num)
                continue
            }

            if scanner.peekIs("~") {
                let startC = scanner.i
                scanner.advance()
                scanner.emit(.keyword, from: startC)
                continue
            }

            if let ident = scanner.takeIdent() {
                scanner.emitIdent(ident.text, from: ident.start, keywords: yamlKeywords)
                continue
            }

            scanner.advance()
        }
        return (scanner.tokens, state)
    }

    private func isBlockScalarIndicator(_ scanner: SyntaxScanner) -> Bool {
        guard scanner.peekIs("|") || scanner.peekIs(">") else { return false }
        guard let next = scanner.peek(1) else { return true }
        if scanner.isWhitespace(next) || next == 0x23 || next == 0x2B || next == 0x2D {
            return true
        }
        return scanner.isDigit(next)
    }

    private func scanQuoted(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState,
                            double: Bool, consumeOpen: Bool) {
        let start = scanner.i
        if consumeOpen { scanner.advance() }
        while !scanner.atEnd {
            if double && scanner.peekIs("\\") {
                scanner.advance()
                if !scanner.atEnd { scanner.advance() }
                continue
            }
            if !double && scanner.peekIs("'") {
                if scanner.peekIs("'", offset: 1) {
                    scanner.advance(2)
                    continue
                }
                scanner.advance()
                scanner.emit(.string, from: start)
                if state.frames.last == SyntaxFrame.quote(double: false) {
                    state.frames.removeLast()
                }
                return
            }
            if double && scanner.peekIs("\"") {
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
}
