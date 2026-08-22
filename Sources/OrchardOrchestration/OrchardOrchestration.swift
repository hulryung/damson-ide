import Foundation

/// OrchardOrchestration — SQLite-backed orchestration store + semantics.
///
/// T1 implements this module per docs/REBUILD-PLAN.md: runs/messages/deliveries/tasks/
/// dispatch_contexts/decision_gates/worker_dispatches/questions on system SQLite3, FIFO
/// delivery batching with verbatim replay, consumer-generation fencing,
/// `(taskId, dispatchId)`-keyed settlement, the 3-failure circuit breaker, and the
/// dispatch-preamble builder. No damson import, no UI — ever.
///
/// This placeholder keeps the target compiling (and its module name reserved) until T1
/// lands.
public enum OrchardOrchestration {
    /// Bumped when the orchestration DB schema changes; T1 owns real migrations.
    public static let schemaVersion = 0
}
