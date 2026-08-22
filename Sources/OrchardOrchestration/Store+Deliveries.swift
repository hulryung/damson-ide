import Foundation

/// A `check` result: the delivery row plus its materialized messages, and whether this
/// was a verbatim replay of a batch handed out earlier.
public struct DeliveryBatch: Equatable, Sendable {
    public let delivery: Delivery
    public let messages: [OrchestrationMessage]
    public let replayed: Bool
}

// FIFO delivery batching with verbatim replay until ack, cap 50, one outstanding
// delivery per Run (unique partial index), consumer-generation fencing.
// Ported from ~/dev/orca/src/main/runtime/orchestration/db/runs/run-delivery.ts.
extension OrchestrationStore {
    /// Return the Run's outstanding delivery (verbatim replay) or create one from the
    /// oldest unread FIFO batch. Returns nil when the mailbox has nothing to deliver.
    ///
    /// `wakeTypes` filters only what *creates* a fresh delivery for a waiter — the
    /// returned batch is always the full oldest batch (docs/research/orca-inventory.md
    /// §1.5): filtering the batch itself would let a type-focused coordinator silently
    /// starve every other message type of its one outstanding slot.
    public func getOrCreateRunDelivery(
        runID: String,
        consumerGeneration: Int,
        limit: Int? = nil,
        wakeTypes: [MessageType]? = nil
    ) throws -> DeliveryBatch? {
        let batchLimit = min(max(limit ?? Self.deliveryBatchLimit, 1), Self.deliveryBatchLimit)
        return try db.inTransaction {
            try requireCurrentConsumer(runID, consumerGeneration)
            if let existingRow = try db.queryOne(
                "SELECT * FROM deliveries WHERE run_id = ? AND status = 'outstanding'",
                [.text(runID)]
            ) {
                let existing = try Delivery(row: existingRow)
                if existing.consumerGeneration != consumerGeneration {
                    throw OrchestrationError(
                        "consumer_fenced",
                        "This mailbox Delivery belongs to a fenced consumer generation."
                    )
                }
                return DeliveryBatch(
                    delivery: existing,
                    messages: try deliveryMessages(existing),
                    replayed: true
                )
            }

            let address = "run:\(runID)"
            if let wakeTypes, !wakeTypes.isEmpty {
                let placeholders = wakeTypes.map { _ in "?" }.joined(separator: ",")
                let matching = try db.queryOne(
                    """
                    SELECT 1 FROM messages
                    WHERE run_id = ? AND to_handle = ? AND read = 0
                      AND type IN (\(placeholders)) LIMIT 1
                    """,
                    [.text(runID), .text(address)] + wakeTypes.map { .text($0.rawValue) }
                )
                if matching == nil { return nil }
            }

            let messages = try db.query(
                """
                SELECT * FROM messages
                WHERE run_id = ? AND to_handle = ? AND read = 0
                ORDER BY sequence ASC LIMIT ?
                """,
                [.text(runID), .text(address), .int(Int64(batchLimit))]
            ).map(OrchestrationMessage.init)
            if messages.isEmpty { return nil }

            let deliveryID = generateID("delivery")
            try db.run(
                """
                INSERT INTO deliveries (id, run_id, consumer_generation, message_ids)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text(deliveryID), .text(runID), .int(Int64(consumerGeneration)),
                    .text(JSONCoding.encodeStringArray(messages.map(\.id))),
                ]
            )
            return DeliveryBatch(
                delivery: try requireDelivery(deliveryID),
                messages: messages,
                replayed: false
            )
        }
    }

    /// Acknowledge a delivery: marks its messages read and closes the outstanding slot.
    /// Idempotent — re-acking an acknowledged delivery reports `duplicate`.
    @discardableResult
    public func acknowledgeRunDelivery(
        runID: String,
        consumerGeneration: Int,
        deliveryID: String
    ) throws -> (delivery: Delivery, duplicate: Bool) {
        try db.inTransaction {
            try requireCurrentConsumer(runID, consumerGeneration)
            guard let delivery = try delivery(deliveryID), delivery.runID == runID else {
                throw OrchestrationError(
                    "stale_delivery",
                    "Delivery \(deliveryID) does not belong to this Run."
                )
            }
            if delivery.consumerGeneration != consumerGeneration || delivery.status == .fenced {
                throw OrchestrationError(
                    "consumer_fenced",
                    "This mailbox Delivery belongs to a fenced consumer generation."
                )
            }
            if delivery.status == .acknowledged {
                return (delivery, true)
            }
            try markAsRead(delivery.messageIDs)
            try db.run(
                "UPDATE deliveries SET status = 'acknowledged', acknowledged_at = datetime('now') WHERE id = ?",
                [.text(deliveryID)]
            )
            return (try requireDelivery(deliveryID), false)
        }
    }

    public func delivery(_ id: String) throws -> Delivery? {
        guard let row = try db.queryOne("SELECT * FROM deliveries WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try Delivery(row: row)
    }

    public func hasOutstandingRunDelivery(_ runID: String) throws -> Bool {
        try db.queryOne(
            "SELECT 1 FROM deliveries WHERE run_id = ? AND status = 'outstanding' LIMIT 1",
            [.text(runID)]
        ) != nil
    }

    /// Materialize a delivery's messages in their recorded order — the verbatim-replay
    /// guarantee lives here: the ID list in the row, not a fresh query, decides content.
    public func deliveryMessages(_ delivery: Delivery) throws -> [OrchestrationMessage] {
        guard !delivery.messageIDs.isEmpty else { return [] }
        let placeholders = delivery.messageIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try db.query(
            "SELECT * FROM messages WHERE id IN (\(placeholders))",
            delivery.messageIDs.map { .text($0) }
        ).map(OrchestrationMessage.init)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return delivery.messageIDs.compactMap { byID[$0] }
    }

    /// Fence (not delete) the outstanding delivery when the consumer generation moves on:
    /// the messages stay unread so the new consumer re-batches them, and the row stays
    /// auditable.
    func fenceOutstandingDelivery(_ runID: String) throws {
        try db.run(
            "UPDATE deliveries SET status = 'fenced' WHERE run_id = ? AND status = 'outstanding'",
            [.text(runID)]
        )
    }

    private func requireDelivery(_ id: String) throws -> Delivery {
        guard let delivery = try delivery(id) else {
            throw OrchestrationError("delivery_not_found", "Delivery \(id) was not found.")
        }
        return delivery
    }
}
