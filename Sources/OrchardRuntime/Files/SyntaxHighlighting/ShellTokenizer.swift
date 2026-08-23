import Foundation

private let shellKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "in", "function", "select", "time", "coproc", "return",
    "exit", "local", "export", "declare", "typeset", "readonly", "unset",
    "shift", "break", "continue", "trap", "source",
]

struct ShellTokenizer: LineTokenizer {
    func tokenize(line: String, baseUTF16: Int, start: TokenizerState)
        -> (tokens: [SyntaxToken], end: TokenizerState) {
        var scanner = SyntaxScanner(line: line, base: baseUTF16)
        var state = start

        if let heredoc = state.frames.last.flatMap(SyntaxFrame.heredocParts) {
            if isHeredocEnd(scanner, delimiter: heredoc.delimiter) {
                let startC = scanner.i
                scanner.i = scanner.length
                scanner.emit(.keyword, from: startC)
                state.frames.removeLast()
                return (scanner.tokens, state)
            }
            if !scanner.atEnd {
                let startC = scanner.i
                scanner.i = scanner.length
                scanner.emit(.string, from: startC)
            }
            return (scanner.tokens, state)
        }

        if let top = state.frames.last, let dbl = SyntaxFrame.isDoubleQuote(top) {
            scanQuoted(&scanner, &state, double: dbl, consumeOpen: false)
        }

        while !scanner.atEnd {
            scanner.skipWhitespace()
            guard !scanner.atEnd else { break }

            if scanner.peekIs("$") {
                scanner.advance()
                if scanner.peekIs("#") || scanner.peekIs("@") || scanner.peekIs("*")
                    || scanner.peekIs("?") || scanner.peekIs("!") || scanner.peekIs("$")
                    || scanner.peekIs("-") {
                    scanner.advance()
                } else {
                    _ = scanner.takeIdent()
                }
                continue
            }

            if scanner.peekIs("#") {
                let startC = scanner.i
                scanner.i = scanner.length
                scanner.emit(.comment, from: startC)
                break
            }

            if scanner.peekIs("<"), scanner.peekIs("<", offset: 1) {
                scanHeredocOpener(&scanner, &state)
                continue
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
            if scanner.peekIs("`") {
                scanBacktick(&scanner)
                continue
            }

            if scanner.peekIs("["), scanner.peekIs("[", offset: 1) {
                let startC = scanner.i
                scanner.advance(2)
                scanner.emit(.keyword, from: startC)
                continue
            }
            if scanner.peekIs("]"), scanner.peekIs("]", offset: 1) {
                let startC = scanner.i
                scanner.advance(2)
                scanner.emit(.keyword, from: startC)
                continue
            }

            if let num = scanner.takeNumber(allowLeadingMinus: false, allowPrefixes: false) {
                scanner.emit(.number, from: num)
                continue
            }

            if let ident = scanner.takeIdent() {
                scanner.emitIdent(ident.text, from: ident.start, keywords: shellKeywords)
                continue
            }

            scanner.advance()
        }
        return (scanner.tokens, state)
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
            if double && scanner.peekIs("\"") {
                scanner.advance()
                scanner.emit(.string, from: start)
                if state.frames.last == SyntaxFrame.quote(double: true) {
                    state.frames.removeLast()
                }
                return
            }
            if !double && scanner.peekIs("'") {
                scanner.advance()
                scanner.emit(.string, from: start)
                if state.frames.last == SyntaxFrame.quote(double: false) {
                    state.frames.removeLast()
                }
                return
            }
            scanner.advance()
        }
        scanner.emit(.string, from: start)
    }

    private func scanBacktick(_ scanner: inout SyntaxScanner) {
        let start = scanner.i
        scanner.advance()
        while !scanner.atEnd {
            if scanner.peekIs("\\") {
                scanner.advance()
                if !scanner.atEnd { scanner.advance() }
                continue
            }
            if scanner.peekIs("`") {
                scanner.advance()
                scanner.emit(.string, from: start)
                return
            }
            scanner.advance()
        }
        scanner.emit(.string, from: start)
    }

    private func scanHeredocOpener(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState) {
        scanner.advance(2)
        var stripTabs = false
        if scanner.peekIs("-") || scanner.peekIs("<") {
            stripTabs = scanner.peekIs("-")
            scanner.advance()
        }
        _ = stripTabs
        scanner.skipWhitespace()
        var quoted = false
        var delim = ""
        if scanner.peekIs("'") || scanner.peekIs("\"") {
            quoted = true
            let quote = scanner.peek()
            scanner.advance()
            let start = scanner.i
            while let c = scanner.peek(), c != quote { scanner.advance() }
            delim = scanner.substring(from: start, to: scanner.i)
            if scanner.peek() == quote { scanner.advance() }
        } else if let ident = scanner.takeIdent() {
            delim = ident.text
        }
        if !delim.isEmpty {
            state.frames.append(SyntaxFrame.heredoc(quoted: quoted, delimiter: delim))
        }
    }

    private func isHeredocEnd(_ scanner: SyntaxScanner, delimiter: String) -> Bool {
        var idx = 0
        while scanner.peek(idx) == 0x09 { idx += 1 }
        let delim = delimiter as NSString
        let n = delim.length
        for i in 0..<n {
            if scanner.peek(idx + i) != delim.character(at: i) { return false }
        }
        return scanner.peek(idx + n) == nil
    }
}
