import XCTest
@testable import OrchardTerminals
import OrchardCore

/// UI-free dashboard projection: kanban bucketing from AgentStatusEntry
/// transitions, and elapsed-in-state formatting.
final class DashboardProjectionTests: XCTestCase {

    private func snap(state: AgentStatusState,
                      projection: AgentRuntimeProjection? = nil,
                      prompt: String = "",
                      assistant: String? = nil,
                      completed: String? = nil,
                      stateStartedAt: Double = 1_000) -> AgentStatusSnapshot {
        AgentStatusSnapshot(
            state: state,
            prompt: prompt,
            updatedAt: stateStartedAt,
            stateStartedAt: stateStartedAt,
            agentType: "claude",
            paneKey: "tab:leaf",
            terminalHandle: "term_1",
            isRunningAgent: projection != nil,
            projection: projection,
            lastAssistantMessage: assistant,
            lastCompletedAssistantMessage: completed)
    }

    func testPermissionAndBlockedGoToAttention() {
        XCTAssertEqual(
            DashboardProjection.bucket(snapshot: snap(state: .blocked, projection: .permission),
                                       unseen: false),
            .attention)
        XCTAssertEqual(DashboardProjection.dotState(from: snap(state: .blocked)), .blocked)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .awaitingApproval, unseen: false),
                       .attention)
    }

    func testWaitingGoesToAttention() {
        XCTAssertEqual(
            DashboardProjection.bucket(snapshot: snap(state: .waiting, projection: .permission),
                                       unseen: false),
            .attention)
        XCTAssertEqual(DashboardProjection.dotState(from: snap(state: .waiting)), .waiting)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .awaitingInput, unseen: false),
                       .attention)
    }

    func testWorkingGoesToWorking() {
        XCTAssertEqual(
            DashboardProjection.bucket(snapshot: snap(state: .working, projection: .working),
                                       unseen: false),
            .working)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .starting, unseen: false), .working)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .working, unseen: true), .working)
    }

    func testDoneStaysInDoneUntilAcknowledged() {
        let done = snap(state: .done, projection: .idle)
        XCTAssertEqual(DashboardProjection.bucket(snapshot: done, unseen: true), .done)
        XCTAssertEqual(DashboardProjection.displayState(dotState: .done, unseen: true), .done)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .idle, unseen: true), .done)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .finished(0), unseen: true), .done)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .errored("boom"), unseen: true), .done)
    }

    func testAcknowledgedDoneSettlesToIdle() {
        let done = snap(state: .done, projection: .idle)
        XCTAssertEqual(DashboardProjection.bucket(snapshot: done, unseen: false), .idle)
        XCTAssertEqual(DashboardProjection.displayState(dotState: .done, unseen: false), .idle)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .idle, unseen: false), .idle)
        XCTAssertEqual(DashboardProjection.bucket(runtime: .finished(0), unseen: false), .idle)
    }

    func testUnseenDoesNotMoveAttentionOrWorking() {
        XCTAssertEqual(
            DashboardProjection.bucket(snapshot: snap(state: .blocked), unseen: true),
            .attention)
        XCTAssertEqual(
            DashboardProjection.bucket(snapshot: snap(state: .working), unseen: true),
            .working)
    }

    func testGlyphsMatchLiveDotStates() {
        XCTAssertEqual(DashboardProjection.glyph(for: .working), "⟳")
        XCTAssertEqual(DashboardProjection.glyph(for: .blocked), "⚠")
        XCTAssertEqual(DashboardProjection.glyph(for: .waiting), "✎")
        XCTAssertEqual(DashboardProjection.glyph(for: .done), "✓")
        XCTAssertEqual(DashboardProjection.glyph(for: .idle), "●")
    }

    func testFormatElapsed() {
        XCTAssertEqual(DashboardProjection.formatElapsed(-3), "0s")
        XCTAssertEqual(DashboardProjection.formatElapsed(0), "0s")
        XCTAssertEqual(DashboardProjection.formatElapsed(59), "59s")
        XCTAssertEqual(DashboardProjection.formatElapsed(60), "1m")
        XCTAssertEqual(DashboardProjection.formatElapsed(3_599), "59m")
        XCTAssertEqual(DashboardProjection.formatElapsed(3_600), "1h 0m")
        XCTAssertEqual(DashboardProjection.formatElapsed(3_661), "1h 1m")
    }

    func testElapsedIntervalUsesMillisecondEpoch() {
        let started = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_045)
        XCTAssertEqual(
            DashboardProjection.elapsedInterval(stateStartedAtMs: 1_000_000, now: now),
            45,
            accuracy: 0.001)
        XCTAssertEqual(
            DashboardProjection.elapsedInterval(stateStartedAtMs: now.timeIntervalSince1970 * 1000,
                                                now: started),
            0)
    }

    func testDetailLinePrefersPromptThenAssistant() {
        XCTAssertEqual(
            DashboardProjection.detailLine(prompt: "  fix the parser  ", lastAssistant: "done"),
            "fix the parser")
        XCTAssertEqual(
            DashboardProjection.detailLine(prompt: "   ", lastAssistant: "Patched parse.swift."),
            "Patched parse.swift.")
        XCTAssertNil(DashboardProjection.detailLine(prompt: "", lastAssistant: "  "))
        XCTAssertNil(DashboardProjection.detailLine(prompt: "", lastAssistant: nil))
    }
}
