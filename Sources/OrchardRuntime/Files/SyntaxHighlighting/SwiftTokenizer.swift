import Foundation

/// Swift keywords we color. `Any`/`Self` stay keywords even though they look
/// like types so the token table stays a single source of truth.
private let swiftKeywords: Set<String> = [
    "Any", "Protocol", "Self", "Type", "actor", "as", "associativity",
    "async", "await", "borrowing", "break", "case", "catch", "class",
    "consuming", "continue", "convenience", "default", "defer", "deinit",
    "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough",
    "false", "fileprivate", "final", "for", "func", "get", "guard", "if",
    "import", "in", "indirect", "infix", "init", "inout", "internal",
    "is", "isolated", "lazy", "left", "let", "macro", "mutating", "nil",
    "nonisolated", "nonmutating", "open", "operator", "optional",
    "override", "package", "postfix", "precedence", "precedencegroup",
    "prefix", "private", "protocol", "public", "repeat", "required",
    "rethrows", "return", "right", "self", "set", "some", "static",
    "struct", "subscript", "super", "switch", "throw", "throws", "true",
    "try", "typealias", "unowned", "var", "weak", "where", "while",
    "willSet", "any", "each",
]

struct SwiftTokenizer: LineTokenizer {
    func tokenize(line: String, baseUTF16: Int, start: TokenizerState)
        -> (tokens: [SyntaxToken], end: TokenizerState) {
        var scanner = SyntaxScanner(line: line, base: baseUTF16)
        var state = start
        resume(&scanner, &state)
        while !scanner.atEnd {
            scanNormal(&scanner, &state)
        }
        return (scanner.tokens, state)
    }

    private func resume(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState) {
        guard let top = state.frames.last else { return }
        if SyntaxFrame.blockCommentDepth(top) != nil {
            scanBlockComment(&scanner, &state)
            return
        }
        if SyntaxFrame.stringParts(top) != nil {
            scanString(&scanner, &state)
            return
        }
        if SyntaxFrame.interpolationDepth(top) != nil {
            return
        }
    }

    private func scanNormal(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState) {
        scanner.skipWhitespace()
        guard !scanner.atEnd else { return }

        if scanner.peekIs("/") {
            if scanner.peekIs("/", offset: 1) {
                let start = scanner.i
                scanner.i = scanner.length
                scanner.emit(.comment, from: start)
                return
            }
            if scanner.peekIs("*", offset: 1) {
                scanner.advance(2)
                state.frames.append(SyntaxFrame.blockComment(1))
                let start = scanner.i - 2
                scanBlockComment(&scanner, &state, openedAt: start)
                return
            }
        }

        if scanner.peekIs("#") {
            let start = scanner.i
            scanner.advance()
            if scanner.peekIs("\"") || (scanner.peekIs("#") && lookAheadRawString(scanner)) {
                scanRawStringOpen(&scanner, &state, hashStart: start)
                return
            }
            if let ident = scanner.takeIdent() {
                scanner.emit(.keyword, from: start)
                _ = ident
                return
            }
            return
        }

        if scanner.peekIs("\"") {
            openString(&scanner, &state)
            return
        }

        if let numStart = scanner.takeNumber(allowLeadingMinus: false, allowPrefixes: true) {
            scanner.emit(.number, from: numStart)
            return
        }

        if let ident = scanner.takeIdent() {
            scanner.emitIdent(ident.text, from: ident.start, keywords: swiftKeywords)
            return
        }

        if scanner.peekIs("("), let depth = state.frames.last.flatMap(SyntaxFrame.interpolationDepth) {
            state.frames[state.frames.count - 1] = SyntaxFrame.interpolation(depth + 1)
            scanner.advance()
            return
        }
        if scanner.peekIs(")"), let depth = state.frames.last.flatMap(SyntaxFrame.interpolationDepth) {
            scanner.advance()
            if depth <= 1 {
                state.frames.removeLast()
                scanString(&scanner, &state)
            } else {
                state.frames[state.frames.count - 1] = SyntaxFrame.interpolation(depth - 1)
            }
            return
        }

        scanner.advance()
    }

    private func lookAheadRawString(_ scanner: SyntaxScanner) -> Bool {
        var idx = 0
        while scanner.peekIs("#", offset: idx) { idx += 1 }
        return scanner.peekIs("\"", offset: idx)
    }

    private func scanRawStringOpen(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState,
                                   hashStart: Int) {
        var hashes = 1
        while scanner.peekIs("#") {
            hashes += 1
            scanner.advance()
        }
        guard scanner.peekIs("\"") else {
            scanner.emit(.keyword, from: hashStart)
            return
        }
        scanner.advance()
        var multiline = false
        if scanner.peekIs("\""), scanner.peekIs("\"", offset: 1) {
            scanner.advance(2)
            multiline = true
        }
        state.frames.append(SyntaxFrame.string(multiline: multiline, hashes: hashes))
        scanString(&scanner, &state, openedAt: hashStart)
    }

    private func openString(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState) {
        let start = scanner.i
        scanner.advance()
        var multiline = false
        if scanner.peekIs("\""), scanner.peekIs("\"", offset: 1) {
            scanner.advance(2)
            multiline = true
        }
        state.frames.append(SyntaxFrame.string(multiline: multiline, hashes: 0))
        scanString(&scanner, &state, openedAt: start)
    }

    private func scanString(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState,
                            openedAt: Int? = nil) {
        guard let parts = state.frames.last.flatMap(SyntaxFrame.stringParts) else { return }
        let start = openedAt ?? scanner.i
        while !scanner.atEnd {
            if scanner.peekIs("\\") {
                let hashes = parts.hashes
                var ok = true
                if hashes > 0 {
                    for h in 1...hashes {
                        if !scanner.peekIs("#", offset: h) { ok = false; break }
                    }
                    if ok, scanner.peekIs("(", offset: hashes + 1) {
                        scanner.advance(hashes + 1)
                        scanner.emit(.string, from: start)
                        state.frames.append(SyntaxFrame.interpolation(1))
                        scanner.advance()
                        return
                    }
                } else if scanner.peekIs("(", offset: 1) {
                    scanner.advance()
                    scanner.emit(.string, from: start)
                    state.frames.append(SyntaxFrame.interpolation(1))
                    scanner.advance()
                    return
                }
                scanner.advance()
                if !scanner.atEnd { scanner.advance() }
                continue
            }
            if scanner.peekIs("\"") {
                if parts.multiline {
                    if scanner.peekIs("\"", offset: 1), scanner.peekIs("\"", offset: 2) {
                        if hashesMatch(scanner, at: 3, hashes: parts.hashes) {
                            scanner.advance(3 + parts.hashes)
                            scanner.emit(.string, from: start)
                            state.frames.removeLast()
                            return
                        }
                    }
                    scanner.advance()
                    continue
                }
                if hashesMatch(scanner, at: 1, hashes: parts.hashes) {
                    scanner.advance(1 + parts.hashes)
                    scanner.emit(.string, from: start)
                    state.frames.removeLast()
                    return
                }
            }
            scanner.advance()
        }
        if scanner.i > start {
            scanner.emit(.string, from: start)
        }
        // Unclosed strings keep their frame so the next line stays in string
        // mode (invalid Swift for `"..."`, required for `"""`).
    }

    private func hashesMatch(_ scanner: SyntaxScanner, at offset: Int, hashes: Int) -> Bool {
        if hashes == 0 { return true }
        for h in 0..<hashes {
            if !scanner.peekIs("#", offset: offset + h) { return false }
        }
        return true
    }

    private func scanBlockComment(_ scanner: inout SyntaxScanner, _ state: inout TokenizerState,
                                  openedAt: Int? = nil) {
        guard let depth0 = state.frames.last.flatMap(SyntaxFrame.blockCommentDepth) else { return }
        var depth = depth0
        let start = openedAt ?? scanner.i
        while !scanner.atEnd {
            if scanner.peekIs("/"), scanner.peekIs("*", offset: 1) {
                scanner.advance(2)
                depth += 1
                state.frames[state.frames.count - 1] = SyntaxFrame.blockComment(depth)
                continue
            }
            if scanner.peekIs("*"), scanner.peekIs("/", offset: 1) {
                scanner.advance(2)
                depth -= 1
                if depth <= 0 {
                    scanner.emit(.comment, from: start)
                    state.frames.removeLast()
                    return
                }
                state.frames[state.frames.count - 1] = SyntaxFrame.blockComment(depth)
                continue
            }
            scanner.advance()
        }
        scanner.emit(.comment, from: start)
    }
}
