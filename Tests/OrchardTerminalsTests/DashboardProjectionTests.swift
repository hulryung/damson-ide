import XCTest
@testable import OrchardTerminals
import OrchardCore

/// UI-free dashboard projection: kanban bucketing from AgentStatusEntry
/// transitions, and elapsed-in-state formatting.
final class DashboardProjectionTests: XCTestCase {

    private let agentA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
    private let agentB = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!

    private func snap(state: AgentStatusState,
                      projection: AgentRuntimeProjection? = nil,
                      prompt: String = "",
                      assistant: String? = nil,
                      completed: String? = nil,
                      stateStartedAt: Double = 1_000,
                      paneKey: String = "tab:leaf",
                      agentType: String = "claude",
                      worktreeId: String? = nil,
                      toolName: String? = nil,
                      interactivePrompt: String? = nil,
                      history: [AgentStateHistoryRecord] = []) -> AgentStatusSnapshot {
        AgentStatusSnapshot(
            state: state,
            prompt: prompt,
            updatedAt: stateStartedAt,
            stateStartedAt: stateStartedAt,
            agentType: agentType,
            paneKey: paneKey,
            terminalHandle: "term_1",
            worktreeId: worktreeId,
            isRunningAgent: projection != nil,
            projection: projection,
            stateHistory: history,
            lastAssistantMessage: assistant,
            lastCompletedAssistantMessage: completed,
            toolName: toolName,
            interactivePrompt: interactivePrompt)
    }

    private func input(paneKey: String = "tab:leaf",
                       agentType: String = "claude",
                       snapshot: AgentStatusSnapshot? = nil,
                       runtime: AgentRuntimeState = .working,
                       unseen: Bool = false,
                       taskTitle: String? = nil,
                       taskPrompt: String? = nil,
                       parentPaneKey: String? = nil,
                       workspaceName: String = "wt",
                       workspaceStatusId: String? = nil,
                       workspaceStatusLabel: String? = nil,
                       repoId: String? = "repo-1",
                       worktreeId: String? = nil,
                       agentID: UUID? = nil,
                       startedAtMs: Double = 1_000,
                       finishedAtMs: Double? = nil,
                       interactivePrompt: String? = nil) -> DashboardCardInput {
        DashboardCardInput(
            paneKey: paneKey,
            agentType: agentType,
            snapshot: snapshot,
            runtime: runtime,
            unseen: unseen,
            taskTitle: taskTitle,
            taskPrompt: taskPrompt,
            parentPaneKey: parentPaneKey,
            workspaceName: workspaceName,
            workspaceStatusId: workspaceStatusId,
            workspaceStatusLabel: workspaceStatusLabel,
            repoId: repoId,
            worktreeId: worktreeId,
            agentID: agentID ?? agentA,
            startedAtMs: startedAtMs,
            finishedAtMs: finishedAtMs,
            interactivePrompt: interactivePrompt)
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

    func testParsePaneKeySplitsTabAndLeaf() {
        let parsed = DashboardProjection.parsePaneKey("tab_abc:leaf-uuid")
        XCTAssertEqual(parsed?.tabId, "tab_abc")
        XCTAssertEqual(parsed?.leafId, "leaf-uuid")
        XCTAssertNil(DashboardProjection.parsePaneKey("nocolon"))
        XCTAssertNil(DashboardProjection.parsePaneKey(":leaf"))
        XCTAssertNil(DashboardProjection.parsePaneKey("tab:"))
    }

    func testBoundedLabelCapsAtMaxLength() {
        let long = String(repeating: "x", count: DashboardProjection.maxLabelLength + 40)
        XCTAssertEqual(DashboardProjection.boundedLabel(long).count,
                       DashboardProjection.maxLabelLength)
        XCTAssertEqual(DashboardProjection.boundedLabel("short"), "short")
    }

    func testTaskPrefersTitleThenPrompt() {
        XCTAssertEqual(DashboardProjection.task(title: " T67 ", prompt: "full prompt"), "T67")
        XCTAssertEqual(DashboardProjection.task(title: "  ", prompt: "full prompt"), "full prompt")
        XCTAssertEqual(DashboardProjection.task(title: nil, prompt: nil), "")
    }

    func testAskSummaryOnlyOnAttention() {
        XCTAssertEqual(
            DashboardProjection.askSummary(bucket: .attention, interactivePrompt: "Approve deploy?"),
            "Approve deploy?")
        XCTAssertNil(
            DashboardProjection.askSummary(bucket: .working, interactivePrompt: "Approve deploy?"))
        XCTAssertEqual(
            DashboardProjection.askSummary(bucket: .attention, interactivePrompt: nil,
                                           toolName: "AskUserQuestion"),
            "AskUserQuestion")
        XCTAssertEqual(
            DashboardProjection.askSummary(
                bucket: .attention,
                interactivePrompt: #"{"questions":[{"question":"Ship to which region?"}]}"#),
            "Ship to which region?")
    }

    func testCardCarriesInventoryFields() {
        let snapshot = snap(
            state: .waiting,
            projection: .permission,
            prompt: "fix the parser",
            assistant: "Need a target region.",
            paneKey: "tab_1:leaf_1",
            worktreeId: "repo::/tmp/wt",
            interactivePrompt: "Approve deploy?")
        let card = DashboardProjection.card(from: input(
            paneKey: "tab_1:leaf_1",
            snapshot: snapshot,
            runtime: .awaitingInput,
            unseen: true,
            taskTitle: "T67 kanban",
            parentPaneKey: "tab_parent:leaf_p",
            workspaceName: "v18-dashboard",
            workspaceStatusId: "in-progress",
            workspaceStatusLabel: "In progress",
            repoId: "repo-1",
            worktreeId: "repo::/tmp/wt",
            startedAtMs: 5_000,
            interactivePrompt: "Approve deploy?"))
        XCTAssertEqual(card.paneKey, "tab_1:leaf_1")
        XCTAssertEqual(card.agentType, "claude")
        XCTAssertEqual(card.bucket, .attention)
        XCTAssertEqual(card.dotState, .waiting)
        XCTAssertEqual(card.task, "T67 kanban")
        XCTAssertEqual(card.lastUserMessage, "fix the parser")
        XCTAssertEqual(card.lastAgentMessage, "Need a target region.")
        XCTAssertEqual(card.focus.agentID, agentA)
        XCTAssertEqual(card.focus.repoId, "repo-1")
        XCTAssertEqual(card.focus.worktreeId, "repo::/tmp/wt")
        XCTAssertEqual(card.focus.tabId, "tab_1")
        XCTAssertEqual(card.focus.leafId, "leaf_1")
        XCTAssertEqual(card.parentPaneKey, "tab_parent:leaf_p")
        XCTAssertEqual(card.workspaceStatusId, "in-progress")
        XCTAssertEqual(card.workspaceStatusLabel, "In progress")
        XCTAssertEqual(card.startedAt, 5_000)
        XCTAssertNil(card.finishedAt)
        XCTAssertTrue(card.unseen)
        XCTAssertEqual(card.askSummary, "Approve deploy?")
        XCTAssertFalse(card.isHighlighted)
    }

    func testUnackedDoneCardStaysHighlightedInDoneBucket() {
        let card = DashboardProjection.card(from: input(
            snapshot: snap(state: .done, projection: .idle, stateStartedAt: 9_000),
            runtime: .idle,
            unseen: true,
            startedAtMs: 1_000))
        XCTAssertEqual(card.bucket, .done)
        XCTAssertEqual(card.dotState, .done)
        XCTAssertEqual(card.displayDotState, .done)
        XCTAssertTrue(card.isHighlighted)
        XCTAssertEqual(card.finishedAt, 9_000)
        XCTAssertEqual(card.timeColumnMs, 9_000)
    }

    func testAcknowledgedDoneCardSettlesToIdleAndDropsHighlight() {
        let card = DashboardProjection.card(from: input(
            snapshot: snap(state: .done, projection: .idle, stateStartedAt: 9_000),
            runtime: .idle,
            unseen: false,
            startedAtMs: 1_000))
        XCTAssertEqual(card.bucket, .idle)
        XCTAssertEqual(card.dotState, .done)
        XCTAssertEqual(card.displayDotState, .idle)
        XCTAssertFalse(card.isHighlighted)
        XCTAssertNil(card.askSummary)
    }

    func testFinishedAtFallsBackToHistoryWhenNotCurrentlyDone() {
        let history = [AgentStateHistoryRecord(state: .done, prompt: "old", startedAt: 4_200)]
        let card = DashboardProjection.card(from: input(
            snapshot: snap(state: .working, projection: .working, history: history),
            runtime: .working,
            startedAtMs: 1_000))
        XCTAssertEqual(card.finishedAt, 4_200)
        XCTAssertEqual(card.bucket, .working)
    }

    func testBoardCapsPerBucketAndKeepsNewestFirst() {
        var inputs: [DashboardCardInput] = []
        for i in 0..<50 {
            inputs.append(input(
                paneKey: String(format: "tab:%02d", i),
                snapshot: snap(state: .working, projection: .working,
                               stateStartedAt: Double(i),
                               paneKey: String(format: "tab:%02d", i)),
                runtime: .working,
                agentID: i == 0 ? agentA : agentB,
                startedAtMs: Double(i)))
        }
        inputs.append(input(
            paneKey: "tab:idle-1",
            snapshot: snap(state: .done, paneKey: "tab:idle-1"),
            runtime: .idle,
            unseen: false,
            agentID: agentB,
            startedAtMs: 1))
        let board = DashboardProjection.board(from: inputs, capPerBucket: 40)
        XCTAssertEqual(board.total(in: .working), 50)
        XCTAssertEqual(board.overflow(in: .working), 10)
        XCTAssertEqual(board.cards(in: .working).count, 40)
        XCTAssertEqual(board.cards(in: .working).first?.paneKey, "tab:49")
        XCTAssertEqual(board.cards(in: .idle).count, 1)
        XCTAssertEqual(board.overflow(in: .idle), 0)
        XCTAssertEqual(board.cards.count, 41)
    }

    func testBoardUsesDefaultCapMatchingInventoryBound() {
        XCTAssertEqual(DashboardProjection.maxCardsPerBucket, 40)
        let inputs = (0..<41).map { i in
            input(paneKey: "p:\(i)", runtime: .working, agentID: agentA, startedAtMs: Double(i))
        }
        let board = DashboardProjection.board(from: inputs)
        XCTAssertEqual(board.capPerBucket, 40)
        XCTAssertEqual(board.cards(in: .working).count, 40)
        XCTAssertEqual(board.overflow(in: .working), 1)
    }
}
