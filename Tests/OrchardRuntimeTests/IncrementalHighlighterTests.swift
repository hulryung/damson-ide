import XCTest
@testable import OrchardRuntime

final class IncrementalHighlighterTests: XCTestCase {
    func testNearestStableLineWalksOutOfUnclosedString() {
        let src = "let a = 1\nlet b = \"hello\nworld\"\nlet c = 2\n"
        let result = SyntaxHighlightEngine.highlightDocument(src, language: .swift)
        XCTAssertTrue(result.lineEndStates[0].isStable)
        XCTAssertFalse(result.lineEndStates[1].isStable)
        XCTAssertTrue(result.lineEndStates[2].isStable)
        XCTAssertEqual(
            SyntaxHighlightEngine.nearestRetokenizeLine(editLine: 2, endStates: result.lineEndStates),
            1)
        XCTAssertEqual(
            SyntaxHighlightEngine.nearestRetokenizeLine(editLine: 3, endStates: result.lineEndStates),
            3)
    }

    func testNeighborhoodSliceMatchesFullDocumentTokens() {
        let src = """
        func greet() {
          let name = "Ada"
          return name
        }
        """
        let full = SyntaxHighlightEngine.highlightDocument(src, language: .swift)
        let from = SyntaxHighlightEngine.nearestRetokenizeLine(
            editLine: 2, endStates: full.lineEndStates)
        let slice = SyntaxHighlightEngine.highlightLines(
            src, language: .swift, fromLine: from, throughLine: 2,
            startState: from == 0 ? .normal : full.lineEndStates[from - 1])
        let fullInRange = full.tokens.filter {
            $0.utf16Location >= slice.utf16Location
                && $0.utf16Location < slice.utf16Location + slice.utf16Length
        }
        XCTAssertEqual(slice.tokens, fullInRange)
    }

    func testBlockCommentPropagatesUntilClosed() {
        let src = "/* start\nstill\n*/\nlet z = 3"
        let result = SyntaxHighlightEngine.highlightDocument(src, language: .swift)
        XCTAssertFalse(result.lineEndStates[0].isStable)
        XCTAssertFalse(result.lineEndStates[1].isStable)
        XCTAssertTrue(result.lineEndStates[2].isStable)
        XCTAssertEqual(
            SyntaxHighlightEngine.nearestRetokenizeLine(editLine: 1, endStates: result.lineEndStates),
            0)
        XCTAssertEqual(kind(of: "still", in: src, .swift), .comment)
        XCTAssertEqual(kind(of: "let", in: src, .swift), .keyword)
    }

    func testLineSplitKeepsUTF16Offsets() {
        let src = "ab\ncd\n"
        let lines = SyntaxHighlightEngine.splitLines(src)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].content, "ab")
        XCTAssertEqual(lines[1].content, "cd")
        XCTAssertEqual(lines[2].content, "")
        XCTAssertEqual(lines[1].startUTF16, 3)
        XCTAssertEqual(SyntaxHighlightEngine.lineIndex(utf16Offset: 3, in: lines), 1)
        XCTAssertEqual(SyntaxHighlightEngine.lineIndex(utf16Offset: 99, in: lines), 2)
    }

    func testPlainLanguageEmitsNoTokens() {
        let result = SyntaxHighlightEngine.highlightDocument("let x = 1", language: .plain)
        XCTAssertTrue(result.tokens.isEmpty)
        XCTAssertTrue(result.lineEndStates.allSatisfy(\.isStable))
    }

    private func kind(of fragment: String, in text: String, _ language: SyntaxLanguage) -> SyntaxTokenKind {
        let result = SyntaxHighlightEngine.highlightDocument(text, language: language)
        let range = (text as NSString).range(of: fragment)
        let mid = range.location + max(0, range.length / 2)
        return result.tokens.first { $0.contains(utf16Offset: mid) }?.kind ?? .text
    }
}
