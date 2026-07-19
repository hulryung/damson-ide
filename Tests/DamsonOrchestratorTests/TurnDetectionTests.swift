import XCTest
@testable import DamsonOrchestrator

/// Covers the 3-tier turn-completion detection: the loopback hook server transport,
/// the Claude Code event→state mapping, and the detector precedence that makes a
/// structured signal (Tier 1 hook / Tier 2 OSC) override screen fingerprints.
final class TurnDetectionTests: XCTestCase {

    // MARK: - Detector precedence (the core fusion rule)

    /// Build a snapshot that a fingerprint classifier would read one way, with an
    /// optional external signal that must override it.
    private func snap(
        lines: [String] = [],
        sinceData: TimeInterval = 2.0,
        sinceSync: TimeInterval = 5.0,
        sinceSpawn: TimeInterval = 10.0,
        external: AgentRuntimeState? = nil
    ) -> ReadinessSnapshot {
        ReadinessSnapshot(
            lines: lines, cursorRow: 0, cursorCol: 0, cols: 80, rows: 24,
            isAltScreen: true, timeSinceLastData: sinceData,
            timeSinceLastSyncFrame: sinceSync, timeSinceSpawn: sinceSpawn,
            processExited: false, exitCode: nil, isRunningForegroundJob: true,
            newPromptMarkSinceTaskStart: false, externalSignal: external)
    }

    func testExternalWorkingOverridesIdleFingerprint() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        // A screen that looks idle (input box, quiescent) …
        let idleScreen = ["│ > ", "  ? for shortcuts"]
        XCTAssertEqual(ClaudeFingerprints.classify(snap(lines: idleScreen)), .idle,
                       "fingerprint alone reads this as idle")
        // … but a fresh hook said the agent is working → working wins.
        _ = d.update(snap(lines: idleScreen, external: .working))
        XCTAssertEqual(d.state, .working)
    }

    func testExternalApprovalOverridesWorkingFingerprint() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        let workingScreen = ["✻ Thinking… (12s · esc to interrupt)"]
        XCTAssertEqual(ClaudeFingerprints.classify(snap(lines: workingScreen)), .working)
        _ = d.update(snap(lines: workingScreen, external: .awaitingApproval))
        XCTAssertEqual(d.state, .awaitingApproval, "a permission hook must win over the spinner")
    }

    func testNoExternalFallsBackToFingerprint() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        d.noteTaskDelivered()                         // working, task active
        _ = d.update(snap(lines: ["✻ Working… (3s"], external: nil))
        XCTAssertEqual(d.state, .working)             // fingerprint drives it
        // Two idle observations (debounce) with the input box → idle.
        let idle = ["│ > ", "  ? for shortcuts"]
        _ = d.update(snap(lines: idle))
        _ = d.update(snap(lines: idle))
        XCTAssertEqual(d.state, .idle)
    }

    func testProcessExitBeatsExternalSignal() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        var s = snap(external: .working)
        // Rebuild with processExited — external says working, but exit is authoritative.
        s = ReadinessSnapshot(
            lines: [], cursorRow: 0, cursorCol: 0, cols: 80, rows: 24, isAltScreen: true,
            timeSinceLastData: 0, timeSinceLastSyncFrame: 5, timeSinceSpawn: 10,
            processExited: true, exitCode: 0, isRunningForegroundJob: false,
            newPromptMarkSinceTaskStart: false, externalSignal: .working)
        _ = d.update(s)
        XCTAssertEqual(d.state, .finished(0))
    }

    // MARK: - Claude Code hook event mapping

    func testClaudeHookEventMapping() {
        let e = ClaudeCodeEngine()
        XCTAssertEqual(e.hookSignal(event: "UserPromptSubmit", body: Data()), .working)
        XCTAssertEqual(e.hookSignal(event: "PreToolUse", body: Data()), .working)
        XCTAssertEqual(e.hookSignal(event: "PostToolUse", body: Data()), .working)
        XCTAssertEqual(e.hookSignal(event: "Stop", body: Data()), .idle)
        XCTAssertNil(e.hookSignal(event: "SessionEnd", body: Data()))
        // Notification disambiguated by payload text.
        let perm = Data(#"{"message":"Claude needs your permission to use Bash"}"#.utf8)
        XCTAssertEqual(e.hookSignal(event: "Notification", body: perm), .awaitingApproval)
        let idle = Data(#"{"message":"Claude is waiting for your input"}"#.utf8)
        XCTAssertEqual(e.hookSignal(event: "Notification", body: idle), .idle)
        XCTAssertNil(e.hookSignal(event: "Notification", body: Data(#"{"message":"hi"}"#.utf8)))
        XCTAssertNotNil(e.hookEvents)
    }

    // MARK: - Hook server transport (round-trip)

    func testHookServerReceivesPostedEvent() throws {
        let server = HookServer()
        guard let port = server.start() else { throw XCTSkip("could not bind loopback port") }
        defer { server.stop() }

        let received = XCTestExpectation(description: "event received")
        var got: HookEvent?
        server.onEvent = { ev in got = ev; received.fulfill() }

        // Post exactly the way HookInstaller's curl command would.
        let url = URL(string: "http://127.0.0.1:\(port)/hook?agent=tok123&event=Stop")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let done = XCTestExpectation(description: "http done")
        URLSession.shared.dataTask(with: req) { _, _, _ in done.fulfill() }.resume()

        wait(for: [received, done], timeout: 5)
        XCTAssertEqual(got?.token, "tok123")
        XCTAssertEqual(got?.event, "Stop")
        XCTAssertEqual(got.map { String(decoding: $0.body, as: UTF8.self) }, #"{"hook_event_name":"Stop"}"#)
    }

    // MARK: - Hook installer output

    func testHookInstallerWritesScopedSettings() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertTrue(HookInstaller.install(
            worktree: tmp, port: 9999, token: "abc",
            events: ["Stop", "PostToolUse"]))

        let file = tmp.appendingPathComponent(".claude/settings.local.json")
        let obj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: file)) as? [String: Any]
        let hooks = obj?["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["Stop"])
        XCTAssertNotNil(hooks?["PostToolUse"])
        // The command must curl our loopback endpoint with the token + event.
        let stop = (hooks?["Stop"] as? [[String: Any]])?.first
        let inner = (stop?["hooks"] as? [[String: Any]])?.first
        let cmd = inner?["command"] as? String ?? ""
        XCTAssertTrue(cmd.contains("127.0.0.1:9999"), cmd)
        XCTAssertTrue(cmd.contains("agent=abc"), cmd)
        XCTAssertTrue(cmd.contains("event=Stop"), cmd)
        XCTAssertTrue(cmd.contains("--data-binary @-"), cmd)
    }

    // MARK: - OSC 9999 keyword mapping (Tier 2, via the same detector path)

    func testExternalIdleSignalDrivesIdleThroughDetector() {
        let d = ReadinessDetector(engine: ClaudeCodeEngine())
        d.noteTaskDelivered()
        _ = d.update(snap(external: .working))         // saw working since delivery
        XCTAssertEqual(d.state, .working)
        _ = d.update(snap(external: .idle))
        _ = d.update(snap(external: .idle))            // debounce ×2
        XCTAssertEqual(d.state, .idle)
    }
}
