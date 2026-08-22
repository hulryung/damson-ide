import XCTest
@testable import OrchardOrchestration

/// Group-address expansion at send time: one message row per recipient, shared
/// thread_id, forbidden for dispatch lifecycle types.
final class GroupAddressTests: StoreTestCase {
    private let terminals = [
        TerminalDirectoryEntry(handle: "term_a", title: "claude — fix tests", worktreeID: "wt1"),
        TerminalDirectoryEntry(handle: "term_b", title: "codex worker", worktreeID: "wt1"),
        TerminalDirectoryEntry(handle: "term_c", title: "grok.exe", worktreeID: "wt2"),
        TerminalDirectoryEntry(handle: "term_sender", title: "claude coordinator", worktreeID: "wt2"),
    ]

    func testAllExcludesSender() {
        let resolved = GroupAddress.resolve("@all", senderHandle: "term_sender", terminals: terminals)
        XCTAssertEqual(Set(resolved), ["term_a", "term_b", "term_c"])
    }

    func testIdleFiltersByAgentStatus() {
        let resolved = GroupAddress.resolve(
            "@idle", senderHandle: "term_sender", terminals: terminals,
            agentStatus: { $0 == "term_b" ? "idle" : "working" })
        XCTAssertEqual(resolved, ["term_b"])
    }

    func testWorktreeGroupMatchesWorktreeID() {
        let resolved = GroupAddress.resolve("@worktree:wt1", senderHandle: "term_sender", terminals: terminals)
        XCTAssertEqual(Set(resolved), ["term_a", "term_b"])
    }

    func testAgentNameGroupMatchesTitleTokens() {
        // Sender is a claude terminal too — excluded despite matching the title.
        XCTAssertEqual(
            GroupAddress.resolve("@claude", senderHandle: "term_sender", terminals: terminals),
            ["term_a"])
        // Windows launcher suffix still matches the token.
        XCTAssertEqual(
            GroupAddress.resolve("@grok", senderHandle: "term_sender", terminals: terminals),
            ["term_c"])
    }

    func testCursorRequiresIdentityNotVocabulary() {
        let terminals = [
            TerminalDirectoryEntry(handle: "term_vocab", title: "fix the text cursor blink"),
            TerminalDirectoryEntry(handle: "term_real", title: "cursor-agent session"),
        ]
        XCTAssertEqual(
            GroupAddress.resolve("@cursor", senderHandle: "term_sender", terminals: terminals),
            ["term_real"])
    }

    func testUnknownGroupResolvesEmpty() {
        XCTAssertEqual(
            GroupAddress.resolve("@nonsense", senderHandle: "term_sender", terminals: terminals), [])
    }

    func testNonGroupAddressResolvesToItself() {
        XCTAssertEqual(
            GroupAddress.resolve("term_x", senderHandle: "term_sender", terminals: terminals),
            ["term_x"])
    }

    // MARK: - Send integration

    func testGroupSendInsertsOneRowPerRecipientWithSharedThread() throws {
        let run = try store.createRun(
            objective: "groups", coordinatorHandle: "term_sender", coordinatorPaneKey: "pane_s")
        let receipt = try store.sendMessage(
            OutboundMessage(
                from: "term_sender", to: "@all", runID: run.id,
                subject: "sync up", body: "please report status"),
            terminals: terminals)

        XCTAssertEqual(receipt.messages.count, 3)
        XCTAssertEqual(Set(receipt.messages.map(\.toHandle)), ["term_a", "term_b", "term_c"])
        let threadIDs = Set(receipt.messages.map(\.threadID))
        XCTAssertEqual(threadIDs.count, 1)
        XCTAssertNotNil(threadIDs.first ?? nil)
        // Independent read-tracking: each recipient's copy is its own unread row.
        for handle in ["term_a", "term_b", "term_c"] {
            XCTAssertEqual(try store.unreadMessages(to: handle).count, 1)
        }
    }

    func testGroupSendForbiddenForWorkerDoneAndHeartbeat() throws {
        let fixture = try makeDispatchedTask()
        for type in [MessageType.workerDone, .heartbeat, .escalation, .decisionGate] {
            XCTAssertThrowsError(
                try store.sendMessage(
                    OutboundMessage(
                        from: "term_worker", to: "@all", runID: fixture.run.id,
                        subject: "x", type: type,
                        payload: workerDonePayload(taskID: fixture.task.id, dispatchID: fixture.dispatch.id)),
                    terminals: terminals),
                "\(type) must refuse group addressing"
            ) { error in
                XCTAssertEqual((error as? OrchestrationError)?.code, "invalid_argument")
            }
        }
    }

    func testEmptyGroupResolutionThrows() throws {
        let run = try store.createRun(
            objective: "groups", coordinatorHandle: "term_sender", coordinatorPaneKey: "pane_s")
        XCTAssertThrowsError(
            try store.sendMessage(
                OutboundMessage(from: "term_sender", to: "@idle", runID: run.id, subject: "x"),
                terminals: terminals)
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "terminal_not_found")
        }
    }

    func testTaskRecipientsAreUnsupported() throws {
        let fixture = try makeDispatchedTask()
        XCTAssertThrowsError(
            try store.sendMessage(OutboundMessage(
                from: "term_worker", to: "task:\(fixture.task.id)", runID: fixture.run.id, subject: "x"))
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "invalid_argument")
        }
    }
}
