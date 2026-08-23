import Foundation

/// UTF-16 cursor over one line. Offsets match `NSTextView` / `EditorDocument.caret`.
struct SyntaxScanner {
    let ns: NSString
    let length: Int
    let base: Int
    var i: Int
    var tokens: [SyntaxToken]

    init(line: String, base: Int) {
        let ns = line as NSString
        self.ns = ns
        self.length = ns.length
        self.base = base
        self.i = 0
        self.tokens = []
    }

    var atEnd: Bool { i >= length }

    func peek(_ offset: Int = 0) -> unichar? {
        let idx = i + offset
        guard idx >= 0, idx < length else { return nil }
        return ns.character(at: idx)
    }

    func peekIs(_ scalar: Unicode.Scalar, offset: Int = 0) -> Bool {
        peek(offset) == unichar(scalar.value)
    }

    mutating func advance(_ n: Int = 1) {
        if n <= 0 { return }
        i = min(length, i + n)
    }

    mutating func emit(_ kind: SyntaxTokenKind, from start: Int) {
        let len = i - start
        guard len > 0 else { return }
        tokens.append(SyntaxToken(kind: kind, utf16Location: base + start, utf16Length: len))
    }

    func isWhitespace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0B || c == 0x0C
    }

    func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

    func isHex(_ c: unichar) -> Bool {
        isDigit(c)
            || (c >= 0x41 && c <= 0x46)
            || (c >= 0x61 && c <= 0x66)
    }

    func isIdentStart(_ c: unichar, dollar: Bool = false) -> Bool {
        if c == 0x5F { return true }
        if dollar && c == 0x24 { return true }
        guard let scalar = Unicode.Scalar(UInt32(c)) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    func isIdentContinue(_ c: unichar, dollar: Bool = false) -> Bool {
        if isDigit(c) { return true }
        return isIdentStart(c, dollar: dollar)
    }

    func isUpperIdentStart(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(c)) else { return false }
        return CharacterSet.uppercaseLetters.contains(scalar)
    }

    mutating func skipWhitespace() {
        while let c = peek(), isWhitespace(c) { advance() }
    }

    func leadingIndent() -> Int {
        var n = 0
        var idx = 0
        while idx < length {
            let c = ns.character(at: idx)
            if c == 0x20 { n += 1 }
            else if c == 0x09 { n += 1 }
            else { break }
            idx += 1
        }
        return n
    }

    func substring(from start: Int, to end: Int) -> String {
        ns.substring(with: NSRange(location: start, length: max(0, end - start)))
    }

    mutating func takeIdent(dollar: Bool = false) -> (start: Int, text: String)? {
        guard let c = peek(), isIdentStart(c, dollar: dollar) else { return nil }
        let start = i
        advance()
        while let next = peek(), isIdentContinue(next, dollar: dollar) {
            advance()
        }
        return (start, substring(from: start, to: i))
    }

    /// Best-effort numeric literal. `allowLeadingMinus` covers JSON/YAML; Swift
    /// treats `+`/`-` as operators so those stay outside the number.
    mutating func takeNumber(allowLeadingMinus: Bool, allowPrefixes: Bool) -> Int? {
        let start = i
        if allowLeadingMinus, peekIs("-") {
            guard let next = peek(1), isDigit(next) || next == 0x2E else { return nil }
            advance()
        }
        guard let c = peek() else {
            i = start
            return nil
        }

        if allowPrefixes, c == 0x30, let prefix = peek(1) {
            if prefix == 0x78 || prefix == 0x58 {
                advance(2)
                var any = false
                while let d = peek() {
                    if d == 0x5F { advance(); continue }
                    if isHex(d) { any = true; advance(); continue }
                    break
                }
                if any { return start }
                i = start
                return nil
            }
            if prefix == 0x62 || prefix == 0x42 || prefix == 0x6F || prefix == 0x4F {
                advance(2)
                var any = false
                while let d = peek() {
                    if d == 0x5F { advance(); continue }
                    if isDigit(d) { any = true; advance(); continue }
                    break
                }
                if any { return start }
                i = start
                return nil
            }
        }

        if isDigit(c) {
            while let d = peek(), isDigit(d) || d == 0x5F { advance() }
            if peekIs(".") {
                if let frac = peek(1), isDigit(frac) {
                    advance()
                    while let d = peek(), isDigit(d) || d == 0x5F { advance() }
                }
            }
            consumeExponent(restore: start)
            return start
        }

        if c == 0x2E, let frac = peek(1), isDigit(frac) {
            advance()
            while let d = peek(), isDigit(d) || d == 0x5F { advance() }
            consumeExponent(restore: start)
            return start
        }

        i = start
        return nil
    }

    private mutating func consumeExponent(restore start: Int) {
        guard let e = peek(), e == 0x65 || e == 0x45 else { return }
        let mark = i
        advance()
        if peekIs("+") || peekIs("-") { advance() }
        var any = false
        while let d = peek(), isDigit(d) || d == 0x5F {
            if isDigit(d) { any = true }
            advance()
        }
        if !any { i = mark }
        _ = start
    }

    mutating func emitIdent(_ text: String, from start: Int, keywords: Set<String>) {
        if keywords.contains(text) {
            emit(.keyword, from: start)
        } else if let first = peekUnichar(at: start), isUpperIdentStart(first) {
            emit(.type, from: start)
        }
    }

    private func peekUnichar(at index: Int) -> unichar? {
        guard index >= 0, index < length else { return nil }
        return ns.character(at: index)
    }
}

protocol LineTokenizer: Sendable {
    func tokenize(line: String, baseUTF16: Int, start: TokenizerState)
        -> (tokens: [SyntaxToken], end: TokenizerState)
}

struct PlainTokenizer: LineTokenizer {
    func tokenize(line: String, baseUTF16: Int, start: TokenizerState)
        -> (tokens: [SyntaxToken], end: TokenizerState) {
        _ = line
        _ = baseUTF16
        return ([], .normal)
    }
}
