import Foundation

/// What `reset` removed, per table, so the caller can report exactly what happened.
public struct OrchestrationResetCounts: Equatable, Sendable {
    public var messages = 0
    public var deliveries = 0
    public var questions = 0
    public var tasks = 0
    public var dispatchContexts = 0
    public var decisionGates = 0
    public var workerDispatches = 0
    public var workerTerminalResources = 0
    public var workerTerminalArchives = 0
    public var runs = 0
    public var mutationReceipts = 0
}

// `reset (--all|--tasks|--messages)` — the recovery verb (docs/research/
// orca-inventory.md §1.4). Additive wave-2 surface: it deletes whole families of
// rows and never rewrites surviving ones, so the T1 semantics above are untouched.
extension OrchestrationStore {
    /// Delete orchestration state by family. `messages` clears the mail plane
    /// (messages, deliveries, questions); `tasks` clears the work plane (tasks,
    /// dispatch contexts, gates, worker accounting); `all` clears both plus runs and
    /// mutation receipts. One transaction — a crash mid-reset leaves everything.
    public func reset(
        messages: Bool = false, tasks: Bool = false, all: Bool = false
    ) throws -> OrchestrationResetCounts {
        var counts = OrchestrationResetCounts()
        try db.inTransaction {
            if messages || all {
                counts.questions = try db.run("DELETE FROM questions")
                counts.deliveries = try db.run("DELETE FROM deliveries")
                counts.messages = try db.run("DELETE FROM messages")
            }
            if tasks || all {
                counts.workerTerminalArchives = try db.run("DELETE FROM worker_terminal_archives")
                counts.workerTerminalResources = try db.run("DELETE FROM worker_terminal_resources")
                counts.workerDispatches = try db.run("DELETE FROM worker_dispatches")
                counts.decisionGates = try db.run("DELETE FROM decision_gates")
                // Questions hang off dispatches; a task reset orphans them even when
                // the mail plane is kept, so they go with their dispatch contexts.
                counts.questions += try db.run("DELETE FROM questions")
                counts.dispatchContexts = try db.run("DELETE FROM dispatch_contexts")
                counts.tasks = try db.run("DELETE FROM tasks")
            }
            if all {
                counts.runs = try db.run("DELETE FROM runs")
                counts.mutationReceipts = try db.run("DELETE FROM mutation_receipts")
            }
        }
        return counts
    }
}
