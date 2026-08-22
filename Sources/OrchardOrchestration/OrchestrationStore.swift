import Foundation

/// SQLite-backed orchestration store: runs, messages, deliveries, tasks, dispatch
/// contexts, decision gates, worker dispatches, worker terminal resources/archives,
/// mutation receipts, and questions (docs/REBUILD-PLAN.md T1; semantics ported from
/// ~/dev/orca/src/main/runtime/orchestration/).
///
/// Concurrency model: the store confines its SQLite connection to one caller at a time —
/// the runtime serializes RPC handling onto it, exactly as Orca funnels everything through
/// one better-sqlite3 connection. It is deliberately NOT `Sendable`; wrap it in an actor
/// (or the runtime's single handler queue) to share it.
///
/// Every mutation that spans rows runs inside `BEGIN IMMEDIATE`/savepoints, so a crash
/// mid-settlement can never strand, e.g., a completed dispatch with an un-promoted DAG.
public final class OrchestrationStore {
    let db: SQLiteDatabase

    /// Fired after a message lands (and after its transaction commits), so the runtime
    /// can wake `waitForMessage` long-polls. Suppressed rows (consumed at reconcile
    /// time) do not fire — waking a waiter for a message it can never read would turn
    /// `check --wait` into a busy-loop.
    public var onMessageArrived: ((_ recipient: String, _ type: MessageType) -> Void)?

    /// Heartbeat cadence is 5 min (see `DispatchPreamble`); staleness threshold is 2×,
    /// so one missed heartbeat is the earliest a dispatch can look stale. Warning flag
    /// only — never auto-fails (docs/research/orca-inventory.md §1.8).
    public static let heartbeatStaleInterval: TimeInterval = 10 * 60

    /// FIFO delivery batch cap (docs/research/orca-inventory.md §1.5).
    public static let deliveryBatchLimit = 50

    /// 3 consecutive dispatch failures trip the circuit breaker
    /// (~/dev/orca/.../db/dispatch-context/dispatch-circuit-breaker.ts).
    public static let dispatchCircuitBreakFailures = 3

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try OrchestrationSchema.migrate(db)
    }

    /// A store backed by a fresh temporary file (WAL needs a real file; `:memory:`
    /// silently downgrades the journal mode tests are meant to exercise).
    public static func temporary() throws -> OrchestrationStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-orchestration-\(UUID().uuidString).db").path
        return try OrchestrationStore(path: path)
    }

    public func close() {
        db.close()
    }

    // MARK: - Shared helpers

    /// `<prefix>_<12 hex>` — same shape as Orca's generated IDs
    /// (~/dev/orca/.../db/generated-id.ts).
    func generateID(_ prefix: String) -> String {
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        return prefix + "_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A `Date` in the same UTC `datetime('now')` shape SQLite writes, for parameters
    /// compared against stored timestamps.
    public static func sqliteTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    func notifyMessageArrived(_ recipient: String, _ type: MessageType) {
        onMessageArrived?(recipient, type)
    }
}
