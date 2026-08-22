import Foundation

/// OrchardOrchestration — SQLite-backed orchestration store + semantics.
///
/// Entry points: `OrchestrationStore` (the store; see its extensions per domain),
/// `MessageWaitCenter` (the `check --wait` long-poll primitive), `DispatchPreamble`
/// (the injected worker contract), and `GroupAddress` (send-time group expansion).
/// No damson import, no UI — ever.
public enum OrchardOrchestration {
    /// Mirrors `PRAGMA user_version` of orchestration.db; bumped on schema changes.
    public static let schemaVersion = OrchestrationSchema.version
}
