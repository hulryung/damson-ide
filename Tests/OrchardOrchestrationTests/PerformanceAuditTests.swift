import XCTest
@testable import OrchardOrchestration

final class PerformanceAuditTests: StoreTestCase {
    func testHotQueryPlansAndMicroBenchmark() throws {
        let run = try store.createRun(objective: "performance audit",
                                      coordinatorHandle: "term_perf",
                                      coordinatorPaneKey: "pane_perf")
        try store.db.inTransaction {
            for index in 0..<4_000 {
                try store.db.run(
                    "INSERT INTO messages (id, run_id, from_handle, to_handle, subject, read) VALUES (?, ?, 'worker', ?, 'status', ?)",
                    [.text("message_\(index)"), .text(run.id),
                     .text(index.isMultiple(of: 2) ? "run:\(run.id)" : "term_other"),
                     .int(index.isMultiple(of: 5) ? 1 : 0)])
                try store.db.run(
                    "INSERT INTO tasks (id, run_id, spec, status) VALUES (?, ?, 'work', ?)",
                    [.text("task_\(index)"), .text(run.id),
                     .text(index.isMultiple(of: 3) ? "ready" : "pending")])
            }
        }

        let deliverySQL = "SELECT * FROM messages WHERE run_id = ? AND to_handle = ? AND read = 0 ORDER BY sequence ASC LIMIT 50"
        let taskSQL = "SELECT * FROM tasks WHERE run_id = ? AND status = 'ready' ORDER BY created_at, id"
        let deliveryParams: [SQLiteValue] = [.text(run.id), .text("run:\(run.id)")]
        let taskParams: [SQLiteValue] = [.text(run.id)]

        let beforeDeliveryPlan = try plan(deliverySQL, deliveryParams)
        let beforeTaskPlan = try plan(taskSQL, taskParams)
        let beforeDelivery = try elapsed(repetitions: 150) { _ = try store.db.query(deliverySQL, deliveryParams) }
        let beforeTasks = try elapsed(repetitions: 40) { _ = try store.db.query(taskSQL, taskParams) }

        try store.db.exec("CREATE INDEX idx_messages_delivery_hot_path ON messages(run_id, to_handle, read, sequence)")
        try store.db.exec("CREATE INDEX idx_tasks_ready_list ON tasks(run_id, status, created_at, id)")
        let afterDeliveryPlan = try plan(deliverySQL, deliveryParams)
        let afterTaskPlan = try plan(taskSQL, taskParams)
        let afterDelivery = try elapsed(repetitions: 150) { _ = try store.db.query(deliverySQL, deliveryParams) }
        let afterTasks = try elapsed(repetitions: 40) { _ = try store.db.query(taskSQL, taskParams) }

        let settlementPlan = try plan("SELECT * FROM dispatch_contexts WHERE id = ?", [.text("ctx_missing")])
        XCTAssertTrue(beforeDeliveryPlan.contains("idx_inbox"), beforeDeliveryPlan)
        XCTAssertTrue(beforeTaskPlan.contains("idx_tasks_run_status"), beforeTaskPlan)
        XCTAssertTrue(afterDeliveryPlan.contains("idx_messages_delivery_hot_path"), afterDeliveryPlan)
        XCTAssertTrue(afterTaskPlan.contains("idx_tasks_ready_list"), afterTaskPlan)
        XCTAssertTrue(settlementPlan.contains("sqlite_autoindex_dispatch_contexts_1"), settlementPlan)
        print(String(format: "PERF delivery ms before %.2f after %.2f; ready-list ms before %.2f after %.2f", beforeDelivery, afterDelivery, beforeTasks, afterTasks))
        print("PLAN delivery before: \(beforeDeliveryPlan); after: \(afterDeliveryPlan)")
        print("PLAN ready before: \(beforeTaskPlan); after: \(afterTaskPlan); settlement: \(settlementPlan)")
    }

    func testPragmasAreTheMeasuredDurabilityLatencyBalance() throws {
        XCTAssertEqual(try store.db.queryOne("PRAGMA journal_mode")?.text("journal_mode").lowercased(), "wal")
        XCTAssertEqual(try store.db.queryOne("PRAGMA synchronous")?.int("synchronous"), 1)
        XCTAssertEqual(try store.db.queryOne("PRAGMA busy_timeout")?.int("timeout"), 5_000)
    }

    private func plan(_ sql: String, _ params: [SQLiteValue]) throws -> String {
        try store.db.query("EXPLAIN QUERY PLAN \(sql)", params)
            .compactMap { try? $0.text("detail") }.joined(separator: " | ")
    }

    private func elapsed(repetitions: Int, _ body: () throws -> Void) throws -> Double {
        let start = ContinuousClock.now
        for _ in 0..<repetitions { try body() }
        return Double(start.duration(to: .now).components.attoseconds) / 1e15
    }
}
