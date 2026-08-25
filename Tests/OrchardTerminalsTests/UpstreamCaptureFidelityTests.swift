import XCTest
import Combine
import DamsonTerminal
import OrchardCore
@testable import OrchardTerminals

/// T54 scripted-paint repro: the real damson engine (`DamsonSession` — VT parser and
/// grid — on a process-free IO backend) behind the production seam, driven by a
/// cell-diffing renderer of the kind that produced the T50 archive. Each test shows
/// the same bytes two ways: what the pre-T54 stream made of the parser's text events
/// (the collapsed and torn text in `Fixtures/claude-code-tui-capture-t50.txt`), and
/// what `terminal read` returns now that a paint is captured from the frame.
@MainActor
final class UpstreamCaptureFidelityTests: XCTestCase {

    /// A `SessionIOBackend` with no process: bytes go in through `feed`, writes are
    /// swallowed. This is the seam damson's tmux backend also sits behind.
    private final class ScriptedIOBackend: SessionIOBackend {
        var onData: ((Data) -> Void)?
        var onExit: ((Int32) -> Void)?
        var childWorkingDirectory: String? { nil }
        var isRunningForegroundJob: Bool { true }
        func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
        func write(_ data: Data) {}
        func resize(cols: Int, rows: Int) {}
        func terminate() {}
        func feed(_ text: String) { onData?(Data(text.utf8)) }
    }

    /// The renderer under suspicion: keeps the last frame it drew and, for the next
    /// one, rewrites only the cells whose character changed, addressing each run of
    /// changed cells with CHA. Blank cells that stay blank are stepped over, so a wide
    /// line painted on a clean screen sends no spaces; characters that already match
    /// are not resent, so a row painted over similar text sends torn fragments. Rows
    /// end with CRLF (which is why the pre-T54 stream got one line per row) and the
    /// whole frame is wrapped in DECSET 2026, like Claude Code's.
    private struct CellDiffRenderer {
        private var previous: [String] = []
        let cols: Int

        init(cols: Int) { self.cols = cols }

        mutating func frame(_ rows: [String]) -> String {
            var out = "\u{1b}[?2026h\u{1b}[1;1H"
            for (r, row) in rows.enumerated() {
                let new = Array(row.padding(toLength: cols, withPad: " ", startingAt: 0))
                let old = Array((r < previous.count ? previous[r] : "")
                    .padding(toLength: cols, withPad: " ", startingAt: 0))
                var c = 0
                while c < cols {
                    guard new[c] != old[c] else { c += 1; continue }
                    let start = c
                    while c < cols, new[c] != old[c] { c += 1 }
                    out += "\u{1b}[\(start + 1)G" + String(new[start..<c])
                }
                out += "\r\n"
            }
            out += "\u{1b}[?2026l"
            previous = rows
            return out
        }
    }

    private var backend: ScriptedIOBackend!
    private var damson: DamsonSession!
    private var service: TerminalService!
    private var handle = ""
    /// What `TerminalRecord.attach` did before T54: every `.text` / `.execute` event
    /// straight into a stream buffer, every CSI dropped.
    private var legacy = TerminalStreamBuffer()
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        try await super.setUp()
        backend = ScriptedIOBackend()
        damson = DamsonSession(config: DamsonConfig(), backend: backend,
                               initialCols: 60, initialRows: 8)
        damson.outputEvents
            .sink { [weak self] event in
                switch event {
                case .text(let s): self?.legacy.appendText(s)
                case .execute(let byte): self?.legacy.appendControl(byte)
                default: break
                }
            }
            .store(in: &cancellables)
        let terminal = DamsonTerminalSession(session: damson)
        service = TerminalService(factory: { _, _ in terminal })
        handle = try service.create(engineID: "shell").handle
    }

    override func tearDown() async throws {
        try? service.close(handle: handle)
        cancellables.removeAll()
        try await super.tearDown()
    }

    private func stream() throws -> [String] {
        try service.read(handle: handle, cursor: 0, limit: 500).lines
    }

    private func legacyLines() -> [String] {
        legacy.page(cursor: 0, limit: 500).lines
    }

    private func screen() throws -> [String] {
        try service.read(handle: handle, screen: true).lines
    }

    // MARK: - The T50 evidence, reproduced

    func testWidePasteOnACleanScreenArrivesCollapsedInTextEventsAndWholeInTheFrame() throws {
        var renderer = CellDiffRenderer(cols: 60)
        let rows = [
            "╭─── Claude Code v2.1.239 ───╮",
            "│ Tips for getting started   │",
            "│ Welcome back Daekeun!      │",
            "╰────────────────────────────╯",
        ]
        backend.feed(renderer.frame(rows))

        // The parser is faithful — it emitted exactly the bytes the renderer sent —
        // and those bytes never contained the spaces. This is fixture line 2.
        XCTAssertEqual(legacyLines()[1], "│Tipsforgettingstarted│")
        XCTAssertEqual(legacyLines()[2], "│WelcomebackDaekeun!│")
        // The grid painted the spaces the renderer stepped over; the stream now reads
        // the rows as shown.
        XCTAssertEqual(try stream(), rows)
        XCTAssertEqual(try screen(), rows)
    }

    func testCellDiffRepaintArrivesTornInTextEventsAndWholeInTheFrame() throws {
        var renderer = CellDiffRenderer(cols: 60)
        backend.feed(renderer.frame([
            "❯ [Pasted text #1 +114 lines]",
            "  paste again to expand",
            "✢ Improvising… (4s · ↓ 181 tokens · thought for 1s)",
        ]))
        let legacyAfterFirstFrame = legacyLines().count
        // The next layout pulls the hint two columns left and ticks the spinner.
        backend.feed(renderer.frame([
            "❯ [Pasted text #1 +114 lines]",
            "paste again to expand",
            "✶ Improvising… (5s · ↓ 195 tokens · thought for 1s)",
        ]))

        // Only the cells that changed were resent. The hint row lost the letter that
        // happened to land on the same letter two columns over (`paste gain to expad`
        // in the archive is this, with more coincidences); the spinner row lost every
        // character that matched the previous frame — the archive's `✽59`, `✢63`,
        // `ought for 1s)` shapes. The unchanged first row sent nothing but its CRLF,
        // which on an empty stream line is no line at all.
        let torn = Array(legacyLines()[legacyAfterFirstFrame...])
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(torn, ["paste agin to expand", "✶595"])

        XCTAssertEqual(try stream(), [
            "❯ [Pasted text #1 +114 lines]",
            "  paste again to expand",
            "✢ Improvising… (4s · ↓ 181 tokens · thought for 1s)",
            "paste again to expand",
            "✶ Improvising… (5s · ↓ 195 tokens · thought for 1s)",
        ], "each frame adds its changed rows, whole; the unchanged row is not repeated")
    }

    func testFrameSplitAcrossChunksIsNotCapturedTorn() throws {
        var renderer = CellDiffRenderer(cols: 60)
        let frame = renderer.frame(["You talk to the coordinator only through the CLI", "commands below."])
        // The PTY hands the frame over in two reads, cut inside the first row.
        let cut = frame.index(frame.startIndex, offsetBy: 30)
        backend.feed(String(frame[..<cut]))
        XCTAssertEqual(try stream(), [], "mid-frame: the screen is half painted, nothing is captured")
        backend.feed(String(frame[cut...]))
        XCTAssertEqual(try stream(), ["You talk to the coordinator only through the CLI", "commands below."])
    }

    func testStatusRowTickingEveryFrameContributesOneWholeRowPerFrame() throws {
        var renderer = CellDiffRenderer(cols: 60)
        backend.feed(renderer.frame(["transcript line", "✢ Working… (1s · ↓ 10 tokens)"]))
        backend.feed(renderer.frame(["transcript line", "✳ Working… (2s · ↓ 25 tokens)"]))
        backend.feed(renderer.frame(["transcript line", "✶ Working… (3s · ↓ 63 tokens)"]))
        XCTAssertEqual(try stream(), [
            "transcript line",
            "✢ Working… (1s · ↓ 10 tokens)",
            "✳ Working… (2s · ↓ 25 tokens)",
            "✶ Working… (3s · ↓ 63 tokens)",
        ], "the unchanged transcript row is not repeated; each tick is one readable line")
        // …whereas the text events for the two repaints were digits and glyphs.
        XCTAssertEqual(Array(legacyLines().suffix(2)), ["✳225", "✶363"])
    }

    // MARK: - Print stays print

    func testPrintedOutputStillFlowsThroughTheTextEvents() throws {
        backend.feed("$ swift test\r\n\u{1b}[32mTest Suite 'All tests' passed\u{1b}[0m\r\nExecuted 932 tests\r\n")
        XCTAssertEqual(try stream(), ["$ swift test", "Test Suite 'All tests' passed", "Executed 932 tests"])
        XCTAssertEqual(try stream(), legacyLines(), "a print burst reads exactly as it did before T54")
    }

    func testPromptRepaintAfterPrintedOutputAddsOnlyThePrompt() throws {
        backend.feed("$ ls\r\nfoo\r\nbar\r\n")
        // zsh redraws its prompt: CR, erase to end of line, prompt text.
        backend.feed("\r\u{1b}[K❯ ")
        XCTAssertEqual(try stream(), ["$ ls", "foo", "bar", "❯"])
    }

    func testOutputLargerThanTheScreenInOnePaintReachesTheStreamFromScrollback() throws {
        // A paint burst that scrolls twelve rows through an eight-row screen: the
        // first rows are in scrollback by the time the frame closes, and the stream
        // still gets all of them, in order, once.
        var text = "\u{1b}[?2026h\u{1b}[1;1H"
        for i in 1...12 { text += "row \(i)\r\n" }
        text += "\u{1b}[?2026l"
        backend.feed(text)
        XCTAssertEqual(try stream(), (1...12).map { "row \($0)" })
        XCTAssertEqual(damson.grid.scrollback.count, 5,
                       "twelve rows plus the cursor's final line through eight rows")
    }

    // MARK: - Row → string conversion

    func testWideCharactersDoNotGrowAPhantomSpaceInScreenOrStream() throws {
        // A wide glyph occupies two cells; the trailing cell is a continuation
        // placeholder, not a character the program printed.
        backend.feed("\u{1b}[?2026h\u{1b}[1;1H한글 파일 Bash(ls)\r\n\u{1b}[?2026l")
        XCTAssertEqual(try screen(), ["한글 파일 Bash(ls)"])
        XCTAssertEqual(try stream(), ["한글 파일 Bash(ls)"])
    }
}
