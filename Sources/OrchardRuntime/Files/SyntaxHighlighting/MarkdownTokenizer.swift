import Foundation

struct MarkdownTokenizer: LineTokenizer {
    func tokenize(line: String, baseUTF16: Int, start: TokenizerState)
        -> (tokens: [SyntaxToken], end: TokenizerState) {
        var scanner = SyntaxScanner(line: line, base: baseUTF16)
        var state = start

        if let fence = state.frames.last.flatMap(SyntaxFrame.fenceParts) {
            if isClosingFence(scanner, fence: fence) {
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

        if let top = state.frames.last, SyntaxFrame.blockCommentDepth(top) != nil {
            scanHTMLComment(&scanner, &state)
            if scanner.atEnd { return (scanner.tokens, state) }
        }

        let indent = skipMarkdownIndent(&scanner)
        if indent <= 3, let fence = openingFence(&scanner) {
            let startC = fence.start
            while let c = scanner.peek(), c == fence.char { scanner.advance() }
            scanner.emit(.keyword, from: startC)
            scanner.skipWhitespace()
            if let ident = scanner.takeIdent() {
                scanner.emit(.type, from: ident.start)
            }
            if !scanner.atEnd {
                let rest = scanner.i
                scanner.i = scanner.length
                if scanner.i > rest { scanner.emit(.text, from: rest) }
            }
            state.frames.append(SyntaxFrame.fence(backtick: fence.char == 0x60, length: fence.length))
            return (scanner.tokens, state)
        }

        if indent <= 3, scanner.peekIs("#") {
            let startC = scanner.i
            var hashes = 0
            while scanner.peekIs("#"), hashes < 6 {
                scanner.advance()
                hashes += 1
            }
            if scanner.atEnd || scanner.peek().map(scanner.isWhitespace) == true {
                scanner.emit(.keyword, from: startC)
            }
        }

        while !scanner.atEnd {
            if scanner.peekIs("<"), scanner.peekIs("!", offset: 1),
               scanner.peekIs("-", offset: 2), scanner.peekIs("-", offset: 3) {
                scanner.advance(4)
                state.frames.append(SyntaxFrame.blockComment(1))
                scanHTMLComment(&scanner, &state, openedAt: scanner.i - 4)
                continue
            }
            if scanner.peekIs("`") {
                scanInlineCode(&scanner)
                continue
            }
            if let num = scanner.takeNumber(allowLeadingMinus: false, allowPrefixes: false) {
                if scanner.peekIs(".") || scanner.peekIs(")") {
                    scanner.emit(.number, from: num)
                    continue
                }
                // Rewind: a bare number in prose stays text.
                scanner.i = num
            }
            scanner.advance()
        }
        return (scanner.tokens, state)
    }

    private func skipMarkdownIndent(_ scanner: inout SyntaxScanner) -> Int {
        var n = 0
        while n < 3, let c = scanner.peek(), scanner.isWhitespace(c) {
            scanner.advance()
            n += 1
        }
        return n
    }

    private func openingFence(_ scanner: inout SyntaxScanner) -> (char: unichar, length: Int, start: Int)? {
        guard let c = scanner.peek(), c == 0x60 || c == 0x7E else { return nil }
        var n = 0
        while scanner.peek(n) == c { n += 1 }
        guard n >= 3 else { return nil }
        return (c, n, scanner.i)
    }

    private func isClosingFence(_ scanner: SyntaxScanner, fence: (backtick: Bool, length: Int)) -> Bool {
        var idx = 0
        while scanner.peek(idx).map({ $0 == 0x20 || $0 == 0x09 }) == true { idx += 1 }
        let char: unichar = fence.backtick ? 0x60 : 0x7E
        var n = 0
        while scanner.peek(idx + n) == char { n += 1 }
        guard n >= fence.length else { return false }
        var rest = idx + n
        while scanner.peek(rest).map({ $0 == 0x20 || $0 == 0x09 }) == true { rest += 1 }
        return scanner.peek(rest) == nil
    }

    private func scanInlineCode(_ scanner: inout SyntaxScanner) {
        let start = scanner.i
        var ticks = 0
        while scanner.peekIs("`") {
            ticks += 1
            scanner.advance()
        }
        while !scanner.atEnd {
            if scanner.peekIs("`") {
                var n = 0
                while scanner.peek(n) == 0x60 { n += 1 }
                if n == ticks {
                    scanner.advance(n)
                    scanner.emit(.string, from: start)
                    return
                }
            }
            scanner.advance()
        }
        scanner.emit(.string, from: start)
    }

    private func scanHTMLComment(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState,
                                 openedAt: Int? = nil) {
        let start = openedAt ?? scanner.i
        while !scanner.atEnd {
            if scanner.peekIs("-"), scanner.peekIs("-", offset: 1), scanner.peekIs(">", offset: 2) {
                scanner.advance(3)
                scanner.emit(.comment, from: start)
                if SyntaxFrame.blockCommentDepth(state.frames.last ?? "") != nil {
                    state.frames.removeLast()
                }
                return
            }
            scanner.advance()
        }
        scanner.emit(.comment, from: start)
    }
}
