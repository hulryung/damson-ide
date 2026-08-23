import Foundation
import XCTest
@testable import OrchardTerminals

/// The persisted per-pane restoration record: its round trip is what stands between a
/// clean quit and the next boot adopting the right PTY under the right paneKey — and
/// the restart-argv stripping encodes damson's measured "no auto-resume" retreat.
final class KeeperRestorationTests: XCTestCase {

    private func sampleState() -> KeeperRestorationState {
        KeeperRestorationState(
            generation: "abc12345",
            // Whole seconds: the store encodes dates as ISO-8601, which drops
            // sub-second precision — a fractional Date would fail the equality below
            // for a reason that has nothing to do with the round trip.
            savedAt: Date(timeIntervalSince1970: 1_724_400_000),
            panes: [KeeperPaneRecord(
                keeperUUID: "keep-1",
                paneKey: "tab_1:leaf_1",
                incarnation: 3,
                worktreeId: "repo::/tmp/wt",
                engineID: "claude-code",
                title: "worker",
                cwd: "/tmp/wt",
                argv: ["/bin/zsh", "-l", "-c", "exec claude"],
                preambleBase64: Data("\u{1b}[?2004h".utf8).base64EncodedString(),
                cols: 132, rows: 40,
                hookToken: "tok123",
                hookPort: 49_152,
                repoPath: "/tmp/repo",
                worktreePath: "/tmp/wt")])
    }

    // MARK: - Record round trip

    func testStateRoundTripsThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = KeeperRestorationStore.defaultURL(dataDirectory: dir)

        let state = sampleState()
        try KeeperRestorationStore.save(state, to: url)
        let loaded = KeeperRestorationStore.loadAndDelete(at: url)
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded?.panes.first?.preamble, Data("\u{1b}[?2004h".utf8))

        // One-shot: the load consumed the file, so a second boot (or a crash mid
        // restore) can never re-adopt the same generation.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(KeeperRestorationStore.loadAndDelete(at: url))
    }

    func testLoadFromMissingFileIsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-nonexistent-\(UUID().uuidString).json")
        XCTAssertNil(KeeperRestorationStore.loadAndDelete(at: url))
    }

    /// A record written by a NEWER build (extra fields) must still decode: losing every
    /// pane over an unknown key would turn a downgrade into a mass pane loss.
    func testDecodeToleratesUnknownFields() throws {
        let json = """
        {"keeperUUID":"k","paneKey":"p","incarnation":1,"engineID":"shell",
         "argv":[],"preambleBase64":"","cols":80,"rows":24,
         "someFutureField":"ignored"}
        """
        let record = try JSONDecoder().decode(KeeperPaneRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.paneKey, "p")
        XCTAssertNil(record.hookToken)
    }

    // MARK: - Restart argv stripping

    func testStripsClaudeSessionFlagsFromDirectArgv() {
        XCTAssertEqual(
            KeeperRestartArgv.stripped(
                ["/opt/homebrew/bin/claude", "--session-id", "abc", "--resume", "def"]),
            ["/opt/homebrew/bin/claude"])
        XCTAssertEqual(
            KeeperRestartArgv.stripped(["claude", "-r", "abc", "--verbose"]),
            ["claude", "--verbose"])
        XCTAssertEqual(
            KeeperRestartArgv.stripped(["claude", "--session-id=abc", "--resume=def", "-p"]),
            ["claude", "-p"])
        // A bare trailing flag just disappears.
        XCTAssertEqual(KeeperRestartArgv.stripped(["claude", "--resume"]), ["claude"])
    }

    func testStripsInsideTheLoginShellWrap() {
        XCTAssertEqual(
            KeeperRestartArgv.stripped(
                ["/bin/zsh", "-l", "-c",
                 "exec /Users/me/.claude/local/claude --session-id abc --resume def"]),
            ["/bin/zsh", "-l", "-c", "exec /Users/me/.claude/local/claude"])
    }

    func testNonClaudeArgvIsUntouched() {
        // Not Claude: strip nothing, ever — damson has no idea how another program
        // resumes, and inventing a flag would be worse than starting it fresh.
        XCTAssertEqual(
            KeeperRestartArgv.stripped(["vim", "--resume", "x"]),
            ["vim", "--resume", "x"])
        // Matched on the executable NAME, never a path substring.
        XCTAssertEqual(
            KeeperRestartArgv.stripped(["/Users/claude/bin/vim", "--resume", "x"]),
            ["/Users/claude/bin/vim", "--resume", "x"])
        XCTAssertEqual(
            KeeperRestartArgv.stripped(["/bin/zsh", "-l", "-c", "exec vim --resume x"]),
            ["/bin/zsh", "-l", "-c", "exec vim --resume x"])
        // A wrap with no `-c` payload passes through.
        XCTAssertEqual(KeeperRestartArgv.stripped(["/bin/zsh", "-l"]), ["/bin/zsh", "-l"])
    }
}
