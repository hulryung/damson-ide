import XCTest
@testable import OrchardCore

final class UnreadReducerTests: XCTestCase {
    private let agentA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
    private let agentB = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
    private let ws1 = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let ws2 = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!

    func testActivityMarksAgentAndWorkspace() {
        let state = UnreadReducer.reduce(
            UnreadState(),
            .agentActivity(agentID: agentA, workspaceID: ws1))
        XCTAssertTrue(state.isUnread(agent: agentA))
        XCTAssertTrue(state.isUnread(workspace: ws1))
        XCTAssertFalse(state.isUnread(agent: agentB))
        XCTAssertFalse(state.isUnread(workspace: ws2))
    }

    func testActivityWithoutWorkspaceMarksOnlyTheAgent() {
        let state = UnreadReducer.reduce(
            UnreadState(),
            .agentActivity(agentID: agentA, workspaceID: nil))
        XCTAssertTrue(state.isUnread(agent: agentA))
        XCTAssertTrue(state.workspaceIDs.isEmpty)
    }

    func testFocusWorkspaceClearsEveryAgentOnThatCard() {
        let marked = UnreadReducer.reduce(UnreadState(), events: [
            .agentActivity(agentID: agentA, workspaceID: ws1),
            .agentActivity(agentID: agentB, workspaceID: ws1),
        ])
        let cleared = UnreadReducer.reduce(marked, .focusedWorkspace(ws1))
        XCTAssertFalse(cleared.isUnread(workspace: ws1))
        XCTAssertFalse(cleared.isUnread(agent: agentA))
        XCTAssertFalse(cleared.isUnread(agent: agentB))
    }

    func testFocusWorkspaceLeavesOtherCardsAlone() {
        let marked = UnreadReducer.reduce(UnreadState(), events: [
            .agentActivity(agentID: agentA, workspaceID: ws1),
            .agentActivity(agentID: agentB, workspaceID: ws2),
        ])
        let cleared = UnreadReducer.reduce(marked, .focusedWorkspace(ws1))
        XCTAssertFalse(cleared.isUnread(workspace: ws1))
        XCTAssertTrue(cleared.isUnread(workspace: ws2))
        XCTAssertTrue(cleared.isUnread(agent: agentB))
    }

    func testFocusAgentClearsDashboardButLeavesSiblingAgents() {
        let marked = UnreadReducer.reduce(UnreadState(), events: [
            .agentActivity(agentID: agentA, workspaceID: ws1),
            .agentActivity(agentID: agentB, workspaceID: ws1),
        ])
        let cleared = UnreadReducer.reduce(marked, .focusedAgent(agentA))
        XCTAssertFalse(cleared.isUnread(agent: agentA))
        XCTAssertTrue(cleared.isUnread(agent: agentB))
        XCTAssertTrue(cleared.isUnread(workspace: ws1))
    }

    func testFocusLastAgentAlsoClearsTheCard() {
        let marked = UnreadReducer.reduce(
            UnreadState(),
            .agentActivity(agentID: agentA, workspaceID: ws1))
        let cleared = UnreadReducer.reduce(marked, .focusedAgent(agentA))
        XCTAssertFalse(cleared.isUnread(agent: agentA))
        XCTAssertFalse(cleared.isUnread(workspace: ws1))
    }

    func testRetireAndRemoveDropStaleMarkers() {
        let marked = UnreadReducer.reduce(UnreadState(), events: [
            .agentActivity(agentID: agentA, workspaceID: ws1),
            .agentActivity(agentID: agentB, workspaceID: ws2),
        ])
        let afterRetire = UnreadReducer.reduce(marked, .agentRetired(agentA))
        XCTAssertFalse(afterRetire.isUnread(agent: agentA))
        XCTAssertTrue(afterRetire.isUnread(workspace: ws2))
        let afterRemove = UnreadReducer.reduce(afterRetire, .workspaceRemoved(ws2))
        XCTAssertTrue(afterRemove.agentIDs.isEmpty)
        XCTAssertTrue(afterRemove.workspaceIDs.isEmpty)
    }

    func testRepeatedActivityIsIdempotent() {
        let once = UnreadReducer.reduce(
            UnreadState(),
            .agentActivity(agentID: agentA, workspaceID: ws1))
        let twice = UnreadReducer.reduce(
            once,
            .agentActivity(agentID: agentA, workspaceID: ws1))
        XCTAssertEqual(once, twice)
    }
}
