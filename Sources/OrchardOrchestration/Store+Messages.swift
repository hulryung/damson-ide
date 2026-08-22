import Foundation

/// Parameters for one message row insert (already resolved to a single recipient —
/// group expansion happens in `sendMessage`).
struct MessageInsert {
    var from: String
    var to: String
    var subject: String
    var body: String
    var type: MessageType
    var priority: MessagePriority
    var threadID: String?
    var payload: String?
    var senderPaneKey: String?
    var runID: String
}

// Message rows + inbox reads. Ported from
// ~/dev/orca/src/main/runtime/orchestration/db/messages/{message-insert,message-inbox}.ts.
extension OrchestrationStore {
    @discardableResult
    func insertMessage(_ message: MessageInsert) throws -> OrchestrationMessage {
        try requireRun(message.runID)
        let id = generateID("msg")
        try db.run(
            """
            INSERT INTO messages (
              id, run_id, from_handle, to_handle, subject, body,
              type, priority, thread_id, payload, sender_pane_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id), .text(message.runID), .text(message.from), .text(message.to),
                .text(message.subject), .text(message.body),
                .text(message.type.rawValue), .text(message.priority.rawValue),
                .maybeText(message.threadID), .maybeText(message.payload),
                .maybeText(message.senderPaneKey),
            ]
        )
        return try requireMessage(id)
    }

    public func message(_ id: String) throws -> OrchestrationMessage? {
        guard let row = try db.queryOne("SELECT * FROM messages WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try OrchestrationMessage(row: row)
    }

    func requireMessage(_ id: String) throws -> OrchestrationMessage {
        guard let message = try message(id) else {
            throw OrchestrationError("message_not_found", "Message \(id) was not found.")
        }
        return message
    }

    public func unreadMessages(to handle: String, types: [MessageType]? = nil) throws -> [OrchestrationMessage] {
        if let types, !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            return try db.query(
                """
                SELECT * FROM messages WHERE to_handle = ? AND read = 0
                  AND type IN (\(placeholders)) ORDER BY sequence
                """,
                [.text(handle)] + types.map { .text($0.rawValue) }
            ).map(OrchestrationMessage.init)
        }
        return try db.query(
            "SELECT * FROM messages WHERE to_handle = ? AND read = 0 ORDER BY sequence",
            [.text(handle)]
        ).map(OrchestrationMessage.init)
    }

    /// Read-only history for a mailbox — never flips the read bit.
    public func messageHistory(
        to handle: String, limit: Int = 100, types: [MessageType]? = nil
    ) throws -> [OrchestrationMessage] {
        let rowLimit = max(1, limit)
        if let types, !types.isEmpty {
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            return try db.query(
                """
                SELECT * FROM messages WHERE to_handle = ? AND type IN (\(placeholders))
                ORDER BY sequence DESC LIMIT ?
                """,
                [.text(handle)] + types.map { .text($0.rawValue) } + [.int(Int64(rowLimit))]
            ).map(OrchestrationMessage.init)
        }
        return try db.query(
            "SELECT * FROM messages WHERE to_handle = ? ORDER BY sequence DESC LIMIT ?",
            [.text(handle), .int(Int64(rowLimit))]
        ).map(OrchestrationMessage.init)
    }

    /// Messages in one thread addressed to `handle`, optionally after a sequence —
    /// the `ask` wait-loop read (skips the asker's own outbound question).
    public func threadMessages(
        threadID: String, to handle: String, afterSequence: Int? = nil
    ) throws -> [OrchestrationMessage] {
        if let afterSequence {
            return try db.query(
                """
                SELECT * FROM messages WHERE thread_id = ? AND to_handle = ? AND sequence > ?
                ORDER BY sequence ASC
                """,
                [.text(threadID), .text(handle), .int(Int64(afterSequence))]
            ).map(OrchestrationMessage.init)
        }
        return try db.query(
            "SELECT * FROM messages WHERE thread_id = ? AND to_handle = ? ORDER BY sequence ASC",
            [.text(threadID), .text(handle)]
        ).map(OrchestrationMessage.init)
    }

    public func markAsRead(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.run(
            "UPDATE messages SET read = 1 WHERE id IN (\(placeholders))",
            ids.map { .text($0) }
        )
    }

    /// Superseded lifecycle messages stay in history but must not be consumed or
    /// injected after their dispatch finished.
    func markAsReadAndDelivered(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.run(
            """
            UPDATE messages SET read = 1, delivered_at = COALESCE(delivered_at, datetime('now'))
            WHERE id IN (\(placeholders))
            """,
            ids.map { .text($0) }
        )
    }

    /// Rewrite a rejected lifecycle message in place: it stays auditable but must not
    /// reach read paths as an actionable completion/liveness event. The rejection marker
    /// in the payload makes a replayed row rejectable again without re-running settlement.
    /// (~/dev/orca/.../db/messages/message-inbox.ts `convertLifecycleMessageToRejection`.)
    @discardableResult
    func convertLifecycleMessageToRejection(
        _ messageID: String, code: String, reason: String
    ) throws -> OrchestrationMessage? {
        guard let message = try message(messageID),
              [.workerDone, .heartbeat, .escalation, .decisionGate].contains(message.type) else {
            return try self.message(messageID)
        }
        let originalBody = message.body.isEmpty ? "" : "\n\nOriginal body:\n\(message.body)"
        let body = "Orchard rejected this \(message.type.rawValue): \(reason)\(originalBody)"
        var payload = JSONCoding.decodeObject(message.payload) ?? [:]
        payload["_orchardLifecycleRejection"] = ["code": code, "reason": reason]
        // Rejected escalation/decision_gate downgrade to status so coordinator triage
        // does not re-run on them; worker_done/heartbeat keep their type for audit.
        try db.run(
            """
            UPDATE messages
            SET type = CASE WHEN type IN ('escalation', 'decision_gate') THEN 'status' ELSE type END,
                priority = 'high', subject = ?, body = ?, payload = ?
            WHERE id = ?
            """,
            [
                .text("Rejected \(message.type.rawValue): \(message.subject)"),
                .text(body), .text(JSONCoding.encodeObject(payload)), .text(messageID),
            ]
        )
        return try self.message(messageID)
    }

    /// A previously persisted rejection marker, if the payload carries one.
    static func persistedLifecycleRejection(in payload: [String: Any]) -> (code: String, reason: String)? {
        guard let marker = payload["_orchardLifecycleRejection"] as? [String: Any],
              let code = marker["code"] as? String,
              let reason = marker["reason"] as? String else {
            return nil
        }
        return (code, reason)
    }
}
