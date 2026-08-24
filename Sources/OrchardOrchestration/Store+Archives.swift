import Foundation

// Cross-run archive inventory and the additive deletion API behind the Vault
// (docs/REBUILD-PLAN.md T49). Reads join `worker_terminal_archives` to the run/task/
// dispatch that produced it so a browser can group leftovers without N+1 queries;
// deletion touches `worker_terminal_archives` and nothing else — messages, tasks,
// dispatch rows and terminal resources are never in a prune's blast radius.

/// One archived dispatch as the Vault lists it: the archive row plus the run/task
/// context it belongs to, the agent that produced it, and a bounded prefix of the
/// stored text so a content filter never has to load whole archives.
///
/// Run/task fields are optional because an archive outlives its dispatch row only in
/// a corrupted or partially-reset database — the Vault still lists (and can prune)
/// those rather than pretending they are not on disk.
public struct WorkerArchiveRecord: Equatable, Sendable {
    public let dispatchID: String
    public let resourceID: String
    public let kind: WorkerTerminalArchiveKind
    public let createdAt: String
    /// `content` size in bytes, as stored.
    public let byteSize: Int
    public let runID: String?
    public let runObjective: String?
    public let runCreatedAt: String?
    public let taskID: String?
    public let taskTitle: String?
    public let taskDisplayName: String?
    public let taskSpec: String?
    public let dispatchStatus: DispatchStatus?
    public let workerState: String
    public let agentHandle: String?
    /// Engine id recorded by `worker-start` in `start_options` (`agent`, else
    /// `launch.agent`). Nil for context-only dispatches and reused terminals.
    public let engineID: String?
    /// First `contentScanLimit` characters of the stored archive text — the only
    /// content a filter match is allowed to see.
    public let contentScan: String
    /// The archive text is longer than `contentScan`, so a filter miss is not proof
    /// the term is absent.
    public let contentScanTruncated: Bool

    public init(
        dispatchID: String,
        resourceID: String = "",
        kind: WorkerTerminalArchiveKind,
        createdAt: String,
        byteSize: Int,
        runID: String? = nil,
        runObjective: String? = nil,
        runCreatedAt: String? = nil,
        taskID: String? = nil,
        taskTitle: String? = nil,
        taskDisplayName: String? = nil,
        taskSpec: String? = nil,
        dispatchStatus: DispatchStatus? = nil,
        workerState: String = "unsupervised",
        agentHandle: String? = nil,
        engineID: String? = nil,
        contentScan: String = "",
        contentScanTruncated: Bool = false
    ) {
        self.dispatchID = dispatchID
        self.resourceID = resourceID
        self.kind = kind
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.runID = runID
        self.runObjective = runObjective
        self.runCreatedAt = runCreatedAt
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.taskDisplayName = taskDisplayName
        self.taskSpec = taskSpec
        self.dispatchStatus = dispatchStatus
        self.workerState = workerState
        self.agentHandle = agentHandle
        self.engineID = engineID
        self.contentScan = contentScan
        self.contentScanTruncated = contentScanTruncated
    }
}

/// What a deletion actually removed. `dispatchIDs` is the subset that had a row —
/// asking to delete an id with no archive is a no-op, not an error.
public struct ArchiveDeletionReceipt: Equatable, Sendable {
    public let deletedCount: Int
    public let freedBytes: Int
    public let dispatchIDs: [String]

    public static let empty = ArchiveDeletionReceipt(deletedCount: 0, freedBytes: 0, dispatchIDs: [])

    public init(deletedCount: Int, freedBytes: Int, dispatchIDs: [String]) {
        self.deletedCount = deletedCount
        self.freedBytes = freedBytes
        self.dispatchIDs = dispatchIDs
    }
}

extension OrchestrationStore {
    /// Characters of each archive a content filter may scan. Bounded on purpose: the
    /// Vault lists every archive across every run, and a 2 MB transcript pin per row
    /// would make opening the window a full-database read.
    public static let defaultArchiveScanLimit = 4096

    /// SQLite's default `SQLITE_MAX_VARIABLE_NUMBER` is 999; stay well under it so a
    /// prune of thousands of archives still runs as a handful of statements.
    static let archiveDeleteChunkSize = 400

    /// Every archive in the database, newest first, joined to its run/task/dispatch.
    ///
    /// `contentScanLimit` caps the per-archive text a caller may match against;
    /// pass 0 to list metadata only.
    public func listWorkerArchives(
        contentScanLimit: Int = OrchestrationStore.defaultArchiveScanLimit
    ) throws -> [WorkerArchiveRecord] {
        let limit = max(0, contentScanLimit)
        let rows = try db.query(
            """
            SELECT a.dispatch_id                     AS dispatch_id,
                   a.resource_id                     AS resource_id,
                   a.kind                            AS kind,
                   a.created_at                      AS created_at,
                   length(CAST(a.content AS BLOB))   AS byte_size,
                   length(a.content)                 AS char_length,
                   substr(a.content, 1, ?)           AS content_scan,
                   d.run_id                          AS run_id,
                   d.task_id                         AS task_id,
                   d.status                          AS dispatch_status,
                   COALESCE(w.state, 'unsupervised') AS worker_state,
                   COALESCE(w.agent_terminal_handle, d.assignee_handle) AS agent_handle,
                   w.start_options                   AS start_options,
                   r.objective                       AS run_objective,
                   r.created_at                      AS run_created_at,
                   t.task_title                      AS task_title,
                   t.display_name                    AS task_display_name,
                   t.spec                            AS task_spec
              FROM worker_terminal_archives a
              LEFT JOIN dispatch_contexts d ON d.id = a.dispatch_id
              LEFT JOIN worker_dispatches w ON w.dispatch_id = a.dispatch_id
              LEFT JOIN runs r ON r.id = d.run_id
              LEFT JOIN tasks t ON t.id = d.task_id
             ORDER BY a.created_at DESC, a.dispatch_id
            """,
            [.int(Int64(limit))])
        return try rows.map { row in
            let charLength = try row.int("char_length")
            let scan = limit == 0 ? "" : (try row.textOrNil("content_scan") ?? "")
            let statusRaw = try row.textOrNil("dispatch_status")
            return WorkerArchiveRecord(
                dispatchID: try row.text("dispatch_id"),
                resourceID: try row.text("resource_id"),
                kind: try OrchestrationMessage.decodeEnum(
                    WorkerTerminalArchiveKind.self, row.text("kind"), column: "kind"),
                createdAt: try row.text("created_at"),
                byteSize: try row.int("byte_size"),
                runID: try row.textOrNil("run_id"),
                runObjective: try row.textOrNil("run_objective"),
                runCreatedAt: try row.textOrNil("run_created_at"),
                taskID: try row.textOrNil("task_id"),
                taskTitle: try row.textOrNil("task_title"),
                taskDisplayName: try row.textOrNil("task_display_name"),
                taskSpec: try row.textOrNil("task_spec"),
                dispatchStatus: statusRaw.flatMap(DispatchStatus.init(rawValue:)),
                workerState: try row.text("worker_state"),
                agentHandle: try row.textOrNil("agent_handle"),
                engineID: Self.engineID(startOptions: try row.textOrNil("start_options")),
                contentScan: scan,
                contentScanTruncated: charLength > limit)
        }
    }

    /// Runs that still hold live coordination: an unsettled dispatch, an unsettled
    /// worker, a pending decision gate, or a pending question. The active run is
    /// always one of these, and retention must never prune any of them — a coordinator
    /// mid-run can still ask for a worker's leftovers.
    public func liveRunIDs() throws -> Set<String> {
        let settled = WorkerDispatchState.allCases.filter(\.isSettled).map(\.rawValue)
        let settledPlaceholders = settled.map { _ in "?" }.joined(separator: ",")
        let rows = try db.query(
            """
            SELECT run_id FROM dispatch_contexts WHERE status IN ('pending', 'dispatched')
            UNION
            SELECT d.run_id FROM worker_dispatches w
              JOIN dispatch_contexts d ON d.id = w.dispatch_id
             WHERE w.state NOT IN (\(settledPlaceholders))
            UNION
            SELECT run_id FROM decision_gates WHERE status = 'pending'
            UNION
            SELECT run_id FROM questions WHERE status = 'pending'
            """,
            settled.map { .text($0) })
        return Set(try rows.map { try $0.text("run_id") })
    }

    /// Total bytes held by `worker_terminal_archives`.
    public func totalWorkerArchiveBytes() throws -> Int {
        let row = try db.queryOne(
            "SELECT COALESCE(SUM(length(CAST(content AS BLOB))), 0) AS total FROM worker_terminal_archives")
        return try row?.int("total") ?? 0
    }

    /// Delete the named dispatches' archives — and only those. Nothing else in the
    /// schema is touched: this statement cannot reach messages, tasks, dispatch
    /// contexts, worker rows, or terminal resources.
    ///
    /// Idempotent: ids with no archive row are skipped, not reported as deleted.
    @discardableResult
    public func deleteWorkerTerminalArchives(dispatchIDs: [String]) throws -> ArchiveDeletionReceipt {
        let unique = Array(NSOrderedSet(array: dispatchIDs).compactMap { $0 as? String })
        guard !unique.isEmpty else { return .empty }
        return try db.inTransaction {
            var deleted: [String] = []
            var freed = 0
            for chunk in stride(from: 0, to: unique.count, by: Self.archiveDeleteChunkSize).map({
                Array(unique[$0..<min($0 + Self.archiveDeleteChunkSize, unique.count)])
            }) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let params: [SQLiteValue] = chunk.map { .text($0) }
                // Measure before the delete: after it there is nothing left to size.
                let present = try db.query(
                    """
                    SELECT dispatch_id, length(CAST(content AS BLOB)) AS byte_size
                      FROM worker_terminal_archives
                     WHERE dispatch_id IN (\(placeholders))
                    """,
                    params)
                for row in present {
                    deleted.append(try row.text("dispatch_id"))
                    freed += try row.int("byte_size")
                }
                try db.run(
                    "DELETE FROM worker_terminal_archives WHERE dispatch_id IN (\(placeholders))",
                    params)
            }
            return ArchiveDeletionReceipt(
                deletedCount: deleted.count, freedBytes: freed, dispatchIDs: deleted)
        }
    }

    /// `start_options.agent`, falling back to `start_options.launch.agent` — the two
    /// places `worker-start` records the engine it launched.
    static func engineID(startOptions: String?) -> String? {
        guard let object = JSONCoding.decodeObject(startOptions) else { return nil }
        if let agent = object["agent"] as? String, !agent.isEmpty { return agent }
        if let launch = object["launch"] as? [String: Any],
           let agent = launch["agent"] as? String, !agent.isEmpty {
            return agent
        }
        return nil
    }
}
