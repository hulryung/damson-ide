import XCTest
@testable import OrchardRuntime

/// State-machine tokenizers: nested strings, comment-in-string, YAML
/// indentation, Markdown fences, and shell quoting.
final class SyntaxTokenizerTests: XCTestCase {
    func testLanguageIsChosenByExtension() {
        XCTAssertEqual(SyntaxLanguage.infer(fromPath: "Sources/App.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage.infer(fromPath: "a/b.json"), .json)
        XCTAssertEqual(SyntaxLanguage.infer(fromPath: "config.yml"), .yaml)
        XCTAssertEqual(SyntaxLanguage.infer(fromPath: "README.md"), .markdown)
        XCTAssertEqual(SyntaxLanguage.infer(fromPath: "scripts/setup.sh"), .shell)
        XCTAssertEqual(SyntaxLanguage.infer(fromPath: "Notes.txt"), .plain)
        XCTAssertEqual(SyntaxLanguage.infer(fromPath: "Makefile"), .plain)
    }

    func testBudgetUsesUtf8SizeAndLineCap() {
        XCTAssertFalse(SyntaxHighlightEngine.exceedsBudget("small"))
        let oversized = String(repeating: "a", count: SyntaxHighlightEngine.byteBudget + 1)
        XCTAssertTrue(SyntaxHighlightEngine.exceedsBudget(oversized))
        let manyLines = String(repeating: "x\n", count: SyntaxHighlightEngine.lineBudget + 1)
        XCTAssertTrue(SyntaxHighlightEngine.exceedsBudget(manyLines))
    }

    // MARK: - Swift

    func testSwiftCommentInsideStringIsStillString() {
        let src = #"let u = "http://x" // real"#
        XCTAssertEqual(kind(of: "http://x", in: src, .swift), .string)
        XCTAssertEqual(kind(of: "// real", in: src, .swift), .comment)
        XCTAssertEqual(kind(of: "let", in: src, .swift), .keyword)
    }

    func testSwiftStringInsideCommentIsStillComment() {
        let src = #"// "foo" is not a string"#
        XCTAssertEqual(kind(of: #""foo""#, in: src, .swift), .comment)
    }

    func testSwiftNestedBlockComments() {
        let src = "/* outer /* inner */ still */ let x = 1"
        XCTAssertEqual(kind(of: "outer", in: src, .swift), .comment)
        XCTAssertEqual(kind(of: "inner", in: src, .swift), .comment)
        XCTAssertEqual(kind(of: "still", in: src, .swift), .comment)
        XCTAssertEqual(kind(of: "let", in: src, .swift), .keyword)
        XCTAssertEqual(kind(of: "1", in: src, .swift), .number)
    }

    func testSwiftInterpolationAndNestedStrings() {
        let src = #""a \( "b \(1)" ) c""#
        XCTAssertEqual(kind(of: #""a \"#, in: src, .swift), .string)
        XCTAssertEqual(kind(of: #""b \"#, in: src, .swift), .string)
        XCTAssertEqual(kind(of: "1", in: src, .swift), .number)
        XCTAssertEqual(kind(of: #" c""#, in: src, .swift), .string)
    }

    func testSwiftMultilineStringPersistsState() {
        let src = "let s = \"\"\"\nhello\n\"\"\"\nlet y = 2"
        let result = SyntaxHighlightEngine.highlightDocument(src, language: .swift)
        XCTAssertFalse(result.lineEndStates[0].isStable)
        XCTAssertEqual(kind(of: "hello", in: src, .swift), .string)
        XCTAssertEqual(kind(of: "let y", in: src, .swift), .keyword)
        XCTAssertEqual(kind(of: "2", in: src, .swift), .number)
    }

    func testSwiftCapitalizedIdentifierIsType() {
        let src = "let decoder = JSONDecoder()"
        XCTAssertEqual(kind(of: "JSONDecoder", in: src, .swift), .type)
        XCTAssertEqual(kind(of: "decoder", in: src, .swift), .text)
    }

    // MARK: - JSON

    func testJSONTokensAndEscapedQuotes() {
        let src = #"{"n": -2.5, "ok": true, "q": "a\"b"}"#
        XCTAssertEqual(kind(of: #""n""#, in: src, .json), .string)
        XCTAssertEqual(kind(of: "-2.5", in: src, .json), .number)
        XCTAssertEqual(kind(of: "true", in: src, .json), .keyword)
        XCTAssertEqual(kind(of: #"a\"b"#, in: src, .json), .string)
    }

    func testJSONCommentInStringIsString() {
        let src = #"{ "url": "http://x" }"#
        XCTAssertEqual(kind(of: "http://x", in: src, .json), .string)
    }

    // MARK: - YAML

    func testYAMLBlockScalarFollowsIndent() {
        let src = """
        root:
          nested: |
            keep
            this
          after: 1
        """
        XCTAssertEqual(kind(of: "keep", in: src, .yaml), .string)
        XCTAssertEqual(kind(of: "this", in: src, .yaml), .string)
        XCTAssertEqual(kind(of: "1", in: src, .yaml), .number)
        XCTAssertNotEqual(kind(of: "after", in: src, .yaml), .string)
    }

    func testYAMLHashInQuotesIsNotComment() {
        let src = "key: \"value # not comment\"\n# comment\nplain: value # trailing"
        XCTAssertEqual(kind(of: "value # not comment", in: src, .yaml), .string)
        XCTAssertEqual(kind(of: "# comment", in: src, .yaml), .comment)
        XCTAssertEqual(kind(of: "# trailing", in: src, .yaml), .comment)
    }

    // MARK: - Markdown

    func testMarkdownFenceKeepsInnerHashAsString() {
        let src = """
        ```
        # not a heading
        ```
        # heading
        """
        XCTAssertEqual(kind(of: "# not a heading", in: src, .markdown), .string)
        XCTAssertEqual(kind(of: "# heading", in: src, .markdown, probe: .start), .keyword)
    }

    func testMarkdownFenceLanguageAndInlineCode() {
        let src = "```swift\nlet x = 1\n```\nUse `code` here"
        XCTAssertEqual(kind(of: "swift", in: src, .markdown), .type)
        XCTAssertEqual(kind(of: "let x = 1", in: src, .markdown), .string)
        XCTAssertEqual(kind(of: "`code`", in: src, .markdown), .string)
    }

    func testMarkdownHTMLComment() {
        let src = "Hello <!-- hidden --> world"
        XCTAssertEqual(kind(of: "<!-- hidden -->", in: src, .markdown), .comment)
    }

    // MARK: - Shell

    func testShellQuotingDoesNotOpenComments() {
        let src = "echo '#' \"not # comment\" 'x'\n# real\n"
        XCTAssertEqual(kind(of: "'#'", in: src, .shell), .string)
        XCTAssertEqual(kind(of: "\"not # comment\"", in: src, .shell), .string)
        XCTAssertEqual(kind(of: "'x'", in: src, .shell), .string)
        XCTAssertEqual(kind(of: "# real", in: src, .shell), .comment)
        XCTAssertEqual(kind(of: "echo", in: src, .shell), .text)
    }

    func testShellKeywordsAndHeredoc() {
        let src = "if true; then\ncat <<EOF\n# not comment\nEOF\nfi\n"
        XCTAssertEqual(kind(of: "if", in: src, .shell), .keyword)
        XCTAssertEqual(kind(of: "then", in: src, .shell), .keyword)
        XCTAssertEqual(kind(of: "# not comment", in: src, .shell), .string)
        XCTAssertEqual(kind(of: "fi", in: src, .shell), .keyword)
    }

    func testShellDollarHashIsNotComment() {
        let src = "echo $#\n# after"
        XCTAssertNotEqual(kind(of: "#", in: src, .shell), .comment)
        XCTAssertEqual(kind(of: "# after", in: src, .shell), .comment)
    }

    // MARK: - Helpers

    private enum Probe { case start, mid }

    private func kind(of fragment: String, in text: String, _ language: SyntaxLanguage,
                      probe: Probe = .mid,
                      file: StaticString = #filePath, line: UInt = #line) -> SyntaxTokenKind {
        let result = SyntaxHighlightEngine.highlightDocument(text, language: language)
        let range = (text as NSString).range(of: fragment)
        XCTAssertNotEqual(range.location, NSNotFound, "missing fragment \(fragment)",
                          file: file, line: line)
        let offset = probe == .start
            ? range.location
            : range.location + max(0, range.length / 2)
        return result.tokens.first { $0.contains(utf16Offset: offset) }?.kind ?? .text
    }
}
