import XCTest
@testable import OrchardOrchestration

/// Blocking worker questions: durable rows, first-answer-wins, dead dispatches close
/// their questions.
final class QuestionTests: StoreTestCase {
    func testCreateQuestionDeliversToRunMailboxAndThreadsOnItself() throws {
        let fixture = try makeDispatchedTask()
        let (question, message) = try store.createQuestion(
            runID: fixture.run.id, dispatchID: fixture.dispatch.id,
            askerHandle: "term_worker", question: "Which schema version?",
            options: ["v1", "v2"])

        XCTAssertEqual(question.status, .pending)
        XCTAssertEqual(question.dispatchID, fixture.dispatch.id)
        XCTAssertEqual(message.toHandle, "run:\(fixture.run.id)")
        XCTAssertEqual(message.type, .question)
        XCTAssertEqual(message.threadID, message.id)
        let payload = try XCTUnwrap(JSONCoding.decodeObject(message.payload))
        XCTAssertEqual(payload["taskId"] as? String, fixture.task.id)
        XCTAssertEqual(payload["options"] as? [String], ["v1", "v2"])
    }

    func testQuestionRequiresActiveDispatch() throws {
        let fixture = try makeDispatchedTask()
        _ = try sendWorkerDone(fixture)
        XCTAssertThrowsError(
            try store.createQuestion(
                runID: fixture.run.id, dispatchID: fixture.dispatch.id,
                askerHandle: "term_worker", question: "too late?")
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "dispatch_inactive")
        }
    }

    func testAnswerThreadsBackToAskerAndIsIdempotentForSameBody() throws {
        let fixture = try makeDispatchedTask()
        let (question, questionMessage) = try store.createQuestion(
            runID: fixture.run.id, dispatchID: fixture.dispatch.id,
            askerHandle: "term_worker", question: "Which color?")

        let answer = try store.answerQuestion(
            messageID: question.messageID, runID: fixture.run.id,
            consumerGeneration: 1, body: "blue")
        XCTAssertFalse(answer.duplicate)
        XCTAssertEqual(answer.question.status, .answered)
        XCTAssertEqual(answer.message.toHandle, "dispatch:\(fixture.dispatch.id)")
        XCTAssertEqual(answer.message.threadID, questionMessage.id)
        // The answer is pre-read: `ask` returns thread state directly, and an unread
        // answer would re-deliver via check.
        XCTAssertTrue(answer.message.read)

        let duplicate = try store.answerQuestion(
            messageID: question.messageID, runID: fixture.run.id,
            consumerGeneration: 1, body: "blue")
        XCTAssertTrue(duplicate.duplicate)
        XCTAssertEqual(duplicate.message.id, answer.message.id)
    }

    func testConflictingAnswerIsRefused() throws {
        let fixture = try makeDispatchedTask()
        let (question, _) = try store.createQuestion(
            runID: fixture.run.id, dispatchID: fixture.dispatch.id,
            askerHandle: "term_worker", question: "Which color?")
        _ = try store.answerQuestion(
            messageID: question.messageID, runID: fixture.run.id, consumerGeneration: 1, body: "blue")

        XCTAssertThrowsError(
            try store.answerQuestion(
                messageID: question.messageID, runID: fixture.run.id,
                consumerGeneration: 1, body: "red")
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "answer_conflict")
        }
    }

    func testFencedConsumerCannotAnswer() throws {
        let fixture = try makeDispatchedTask()
        let (question, _) = try store.createQuestion(
            runID: fixture.run.id, dispatchID: fixture.dispatch.id,
            askerHandle: "term_worker", question: "Which color?")
        try store.bindRun(
            runID: fixture.run.id, coordinatorHandle: "term_new", coordinatorPaneKey: "pane_new")

        XCTAssertThrowsError(
            try store.answerQuestion(
                messageID: question.messageID, runID: fixture.run.id,
                consumerGeneration: 1, body: "blue")
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "consumer_fenced")
        }
    }

    func testClosedQuestionRefusesAnswers() throws {
        let fixture = try makeDispatchedTask()
        let (question, _) = try store.createQuestion(
            runID: fixture.run.id, dispatchID: fixture.dispatch.id,
            askerHandle: "term_worker", question: "Which color?")
        _ = try sendWorkerDone(fixture)
        XCTAssertEqual(try store.question(question.messageID)?.status, .closed)

        XCTAssertThrowsError(
            try store.answerQuestion(
                messageID: question.messageID, runID: fixture.run.id,
                consumerGeneration: 1, body: "blue")
        ) { error in
            XCTAssertEqual((error as? OrchestrationError)?.code, "dispatch_inactive")
        }
    }
}
