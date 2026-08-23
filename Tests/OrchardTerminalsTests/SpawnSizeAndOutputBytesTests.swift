import XCTest
import Combine
import DamsonTerminal
import OrchardCore
@testable import OrchardTerminals

/// T19 adoption of damson's sized spawn and multi-subscriber raw-output stream:
/// spawn geometry threads from the create call through the spec to the PTY (so a
/// child's first TIOCGWINSZ reads the real pane size, not 80×24), and the raw
/// `outputBytes` stream — not the `gridChanged` piggyback — drives the activity clock.
@MainActor
final class SpawnSizeAndOutputBytesTests: XCTestCase {

    /// Launches `/bin/cat` directly (no login-shell wrap), so the real-PTY tests
    /// below spawn something inert instead of an interactive shell.
    private struct CatEngine: AgentEngine {
        let id = "cat"
        let displayName = "cat"
        var launchesOwnShell: Bool { true }
        func launchArgv(task: AgentTask, worktree: URL) -> [String] { ["/bin/cat"] }
    }

    private func catSpec(cols: Int? = nil, rows: Int? = nil) -> TerminalCreateSpec {
        TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(), paneKey: TerminalRegistry.mintPaneKey(),
            worktreeId: nil, cwd: nil, engineID: "cat", prompt: "", title: nil,
            initialCols: cols, initialRows: rows)
    }

    // MARK: - Sized spawn, end to end against a real PTY

    func testSizedSpawnReachesThePTYGrid() {
        var config = DamsonConfig()
        config.argv = ["/bin/cat"]
        let session = DamsonTerminalSession(config: config, initialCols: 97, initialRows: 41)
        defer { session.terminate() }
        let grid = session.gridSnapshot()
        XCTAssertEqual(grid.cols, 97)
        XCTAssertEqual(grid.rows, 41)
    }

    func testFactorySpawnsAtSpecSizeAndDefaultsWhenUnknown() throws {
        let factory = DamsonTerminalFactory.make()

        let sized = try factory(catSpec(cols: 91, rows: 33), CatEngine())
        defer { sized.terminate() }
        XCTAssertEqual(sized.gridSnapshot().cols, 91)
        XCTAssertEqual(sized.gridSnapshot().rows, 33)

        // No geometry in the spec ⇒ the sensible default, not the historical 80×24.
        let defaulted = try factory(catSpec(), CatEngine())
        defer { defaulted.terminate() }
        XCTAssertEqual(defaulted.gridSnapshot().cols, TerminalSpawnDefaults.cols)
        XCTAssertEqual(defaulted.gridSnapshot().rows, TerminalSpawnDefaults.rows)
    }

    // MARK: - Size threading through the service

    private final class CapturingHarness {
        var specs: [TerminalCreateSpec] = []
        var sessions: [String: ScriptedTerminalSession] = [:]   // by handle
        private(set) var service: TerminalService!

        @MainActor
        init() {
            service = TerminalService(factory: { [weak self] spec, _ in
                let session = ScriptedTerminalSession()
                self?.specs.append(spec)
                self?.sessions[spec.handle] = session
                return session
            })
        }
    }

    func testCreateThreadsInitialSizeIntoTheSpec() throws {
        let harness = CapturingHarness()
        _ = try harness.service.create(engineID: "shell", initialCols: 143, initialRows: 52)
        XCTAssertEqual(harness.specs.last?.initialCols, 143)
        XCTAssertEqual(harness.specs.last?.initialRows, 52)

        // A caller with no geometry leaves the spec unset — the default belongs to the
        // factory, so scripted/test factories never see a fabricated size.
        _ = try harness.service.create(engineID: "shell")
        XCTAssertNil(harness.specs.last?.initialCols)
        XCTAssertNil(harness.specs.last?.initialRows)
    }

    func testRespawnCarriesTheCurrentPaneGridSize() throws {
        let harness = CapturingHarness()
        let created = try harness.service.create(engineID: "shell")
        _ = try harness.service.respawn(paneKey: created.paneKey)
        // ScriptedTerminalSession's grid reports 80×24 — the respawn spec must carry
        // whatever the outgoing session's grid says, not the create-time value (nil).
        XCTAssertEqual(harness.specs.last?.initialCols, 80)
        XCTAssertEqual(harness.specs.last?.initialRows, 24)
    }

    // MARK: - Raw output stream

    func testRawBytesDriveTheActivityClockWithoutParsedEvents() throws {
        let harness = CapturingHarness()
        let created = try harness.service.create(engineID: "shell")
        let scripted = try XCTUnwrap(harness.sessions[created.handle])
        XCTAssertNil(harness.service.list().first?.lastOutputAt)

        // A repaint-only burst: raw bytes arrive, no text/control event follows. It
        // must register as activity — and must not leak into the parsed stream buffer.
        scripted.emitRawBytes(Data("\u{1B}[2K\u{1B}[1G".utf8))
        let summary = try XCTUnwrap(harness.service.list().first)
        XCTAssertNotNil(summary.lastOutputAt)
        XCTAssertEqual(summary.preview, "")

        let read = try harness.service.read(handle: created.handle)
        XCTAssertEqual(read.lines.filter { !$0.isEmpty }, [])
    }

    func testScriptedOutputFeedsBothStreams() throws {
        let scripted = ScriptedTerminalSession()
        var rawChunks: [Data] = []
        var cancellables = Set<AnyCancellable>()
        scripted.outputBytes
            .sink { rawChunks.append($0) }
            .store(in: &cancellables)

        scripted.emitOutput("build ok\n")
        XCTAssertEqual(rawChunks, [Data("build ok\n".utf8)])
    }
}
