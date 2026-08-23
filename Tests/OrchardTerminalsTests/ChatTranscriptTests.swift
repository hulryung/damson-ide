import XCTest
@testable import OrchardTerminals

/// UI-free projection of the agent-status stream into a bounded chat transcript.
final class ChatTranscriptTests: XCTestCase {

    private func snap(prompt: String = "", completed: String? = nil,
                      assistant: String? = nil,
                      projection: AgentRuntimeProjection? = .idle,
                      updatedAt: Double = 1) -> AgentStatusSnapshot {
        AgentStatusSnapshot(
            state: projection == .working ? .working
                : projection == .permission ? .blocked : .done,
            prompt: prompt,
            updatedAt: updatedAt,
            stateStartedAt: updatedAt,
            agentType: "claude",
            paneKey: "tab:leaf",
            terminalHandle: "term_1",
            isRunningAgent: projection != nil,
            projection: projection,
            lastAssistantMessage: assistant,
            lastCompletedAssistantMessage: completed)
    }

    func testProjectsPromptCompletedAssistantAndMarkers() {
        var projector = ChatTranscriptProjector()
        _ = projector.apply(snap(prompt: "fix the parser", projection: .working, updatedAt: 10))
        _ = projector.apply(snap(prompt: "fix the parser", completed: "Patched parse.swift.",
                                 projection: .idle, updatedAt: 20))
        XCTAssertEqual(projector.transcript.map(\.role), [.user, .marker, .assistant, .marker])
        XCTAssertEqual(projector.transcript.map(\.text), [
            "fix the parser", "Working", "Patched parse.swift.", "Idle",
        ])
        XCTAssertEqual(projector.transcript[1].projection, .working)
        XCTAssertEqual(projector.transcript[3].projection, .idle)
    }

    func testRepeatSnapshotsDoNotDuplicate() {
        var projector = ChatTranscriptProjector()
        let first = snap(prompt: "hello", completed: "hi", projection: .idle)
        _ = projector.apply(first)
        let afterFirst = projector.transcript.count
        _ = projector.apply(first)
        _ = projector.apply(first)
        XCTAssertEqual(projector.transcript.count, afterFirst)
    }

    func testNewPromptStartsAnotherUserTurn() {
        var projector = ChatTranscriptProjector()
        _ = projector.apply(snap(prompt: "one", projection: .idle))
        _ = projector.apply(snap(prompt: "two", projection: .idle))
        XCTAssertEqual(projector.transcript.filter { $0.role == .user }.map(\.text), ["one", "two"])
    }

    func testPermissionIsABlockedMarkerNotASilentDrop() {
        var projector = ChatTranscriptProjector()
        _ = projector.apply(snap(prompt: "rm -rf /", projection: .working))
        _ = projector.apply(snap(prompt: "rm -rf /", projection: .permission))
        let markers = projector.transcript.filter { $0.role == .marker }
        XCTAssertEqual(markers.map(\.projection), [.working, .permission])
        XCTAssertEqual(markers.last?.text, "Needs permission")
    }

    func testCompletedAssistantChangeAppendsWithoutGridText() {
        var projector = ChatTranscriptProjector()
        _ = projector.apply(snap(completed: "first", projection: .idle))
        _ = projector.apply(snap(completed: "second", projection: .idle))
        XCTAssertEqual(projector.transcript.filter { $0.role == .assistant }.map(\.text),
                       ["first", "second"])
    }

    func testIgnoresEmptyPromptAndNilProjection() {
        var projector = ChatTranscriptProjector()
        _ = projector.apply(snap(prompt: "   ", completed: nil, projection: nil))
        XCTAssertTrue(projector.transcript.isEmpty)
    }

    func testHistoryIsBounded() {
        var projector = ChatTranscriptProjector()
        for i in 0..<(chatTranscriptHistoryMax + 12) {
            _ = projector.apply(snap(prompt: "p\(i)", projection: .idle, updatedAt: Double(i)))
        }
        XCTAssertEqual(projector.transcript.count, chatTranscriptHistoryMax)
        XCTAssertEqual(projector.transcript.first?.text.hasPrefix("p"), true)
        XCTAssertEqual(projector.transcript.last?.role, .user)
        XCTAssertTrue(projector.transcript.contains { $0.text == "p\(chatTranscriptHistoryMax + 11)" })
        XCTAssertFalse(projector.transcript.contains { $0.text == "p0" })
    }
}
