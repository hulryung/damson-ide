import Foundation

// Blocking worker questions (`ask`). A question is a message row (type 'question' to the
// Run mailbox) plus a questions row tracking answer state; the answer is a reply message
// threaded on the question's message ID. Ported from
// ~/dev/orca/.../db/questions/question-threads.ts.
extension OrchestrationStore {
    /// Record a worker question against its active dispatch and deliver it to the Run.
    public func createQuestion(
        runID: String,
        dispatchID: String,
        askerHandle: String,
        question: String,
        options: [String] = []
    ) throws -> (question: Question, message: OrchestrationMessage) {
        let result: (question: Question, message: OrchestrationMessage) = try db.inTransaction {
            try requireRun(runID)
            guard let dispatch = try dispatchContext(dispatchID),
                  dispatch.runID == runID,
                  dispatch.status == .pending || dispatch.status == .dispatched else {
                throw OrchestrationError(
                    "dispatch_inactive",
                    "Dispatch \(dispatchID) is not active in Run \(runID)."
                )
            }
            let message = try insertMessage(MessageInsert(
                from: "dispatch:\(dispatchID)",
                to: "run:\(runID)",
                subject: "Question",
                body: question,
                type: .question,
                priority: .normal,
                threadID: nil,
                payload: JSONCoding.encodeObject([
                    "taskId": dispatch.taskID,
                    "dispatchId": dispatch.id,
                    "question": question,
                    "options": options,
                ]),
                senderPaneKey: nil,
                runID: runID
            ))
            // The question's own message ID is its thread ID — replies join it there.
            try db.run(
                "UPDATE messages SET thread_id = ? WHERE id = ?",
                [.text(message.id), .text(message.id)])
            try db.run(
                "INSERT INTO questions (message_id, run_id, dispatch_id, asker_handle) VALUES (?, ?, ?, ?)",
                [.text(message.id), .text(runID), .text(dispatchID), .text(askerHandle)]
            )
            return (try requireQuestion(message.id), try requireMessage(message.id))
        }
        notifyMessageArrived(result.message.toHandle, .question)
        return result
    }

    public func question(_ messageID: String) throws -> Question? {
        guard let row = try db.queryOne(
            "SELECT * FROM questions WHERE message_id = ?", [.text(messageID)]) else {
            return nil
        }
        return try Question(row: row)
    }

    /// Answer a pending question (coordinator side). Idempotent for the exact same
    /// answer body; a *different* answer to an answered question is `answer_conflict`.
    public func answerQuestion(
        messageID: String,
        runID: String,
        consumerGeneration: Int,
        body: String
    ) throws -> (question: Question, message: OrchestrationMessage, duplicate: Bool) {
        try db.inTransaction {
            try requireCurrentConsumer(runID, consumerGeneration)
            guard let question = try question(messageID), question.runID == runID else {
                throw OrchestrationError(
                    "question_not_found", "Question \(messageID) was not found in Run \(runID).")
            }
            if question.status == .closed {
                throw OrchestrationError(
                    "dispatch_inactive",
                    "Question \(messageID) is closed because its Dispatch is inactive."
                )
            }
            if question.status == .answered {
                guard question.answerBody == body, let answerID = question.answerMessageID else {
                    throw OrchestrationError(
                        "answer_conflict", "Question \(messageID) already has a different answer.")
                }
                return (question, try requireMessage(answerID), true)
            }
            let message = try insertMessage(MessageInsert(
                from: "run:\(runID)",
                to: "dispatch:\(question.dispatchID)",
                subject: "Re: Question",
                body: body,
                type: .status,
                priority: .normal,
                threadID: question.messageID,
                payload: nil,
                senderPaneKey: nil,
                runID: runID
            ))
            // `ask` returns thread state directly; leaving its answer unread would
            // deliver it again via check.
            try markAsRead([message.id])
            try db.run(
                """
                UPDATE questions
                SET status = 'answered', answer_message_id = ?, answer_body = ?,
                    answered_by_generation = ?, answered_at = datetime('now')
                WHERE message_id = ? AND status = 'pending'
                """,
                [
                    .text(message.id), .text(body), .int(Int64(consumerGeneration)),
                    .text(question.messageID),
                ]
            )
            return (try requireQuestion(question.messageID), try requireMessage(message.id), false)
        }
    }

    /// Close every pending question of a settled dispatch — a dead dispatch can never
    /// consume an answer, and a blocked `ask` must fail fast instead of hanging.
    /// Returns the closed question message IDs.
    @discardableResult
    public func closeQuestionsForDispatch(_ dispatchID: String) throws -> [String] {
        let pending = try db.query(
            "SELECT message_id FROM questions WHERE dispatch_id = ? AND status = 'pending'",
            [.text(dispatchID)]
        ).map { try $0.text("message_id") }
        guard !pending.isEmpty else { return [] }
        try db.run(
            "UPDATE questions SET status = 'closed', closed_at = datetime('now') WHERE dispatch_id = ? AND status = 'pending'",
            [.text(dispatchID)]
        )
        return pending
    }

    private func requireQuestion(_ messageID: String) throws -> Question {
        guard let question = try question(messageID) else {
            throw OrchestrationError("question_not_found", "Question \(messageID) was not found.")
        }
        return question
    }
}
