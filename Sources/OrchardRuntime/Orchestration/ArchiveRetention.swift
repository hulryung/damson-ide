import Foundation
import OrchardOrchestration

/// Retention for worker archives (docs/REBUILD-PLAN.md T49): what a size/age cap
/// selects for deletion, and what it refuses to touch. Pure selection — nothing here
/// reads or writes the store, so the rule is testable without a database and the
/// dry-run preview is computed by exactly the code that later executes.

public struct ArchiveRetentionPolicy: Equatable, Sendable {
    /// 512 MB of pinned worker output before the oldest archives start rolling off.
    /// Large enough that a normal week of runs never trips it, small enough that a
    /// forgotten machine does not accumulate gigabytes of TUI tails.
    public static let defaultMaxTotalBytes = 512 * 1024 * 1024
    /// Archives older than 60 days: past the point anyone re-reads a released worker.
    public static let defaultMaxAgeDays = 60

    /// Total archive bytes to keep. 0 = keep forever.
    public var maxTotalBytes: Int
    /// Age ceiling in days. 0 = keep forever.
    public var maxAgeDays: Int

    public static let `default` = ArchiveRetentionPolicy(
        maxTotalBytes: defaultMaxTotalBytes, maxAgeDays: defaultMaxAgeDays)
    /// Both caps off — prune selects nothing.
    public static let keepForever = ArchiveRetentionPolicy(maxTotalBytes: 0, maxAgeDays: 0)

    public init(maxTotalBytes: Int, maxAgeDays: Int) {
        self.maxTotalBytes = max(0, maxTotalBytes)
        self.maxAgeDays = max(0, maxAgeDays)
    }

    public var enforcesSize: Bool { maxTotalBytes > 0 }
    public var enforcesAge: Bool { maxAgeDays > 0 }
    public var isDisabled: Bool { !enforcesSize && !enforcesAge }
}

/// Why an archive was selected. Age wins when both apply — it is the rule the user
/// can reason about from the timestamp alone.
public enum ArchivePruneReason: String, Equatable, Sendable {
    case age
    case size
}

public struct ArchivePruneEntry: Equatable, Sendable, Identifiable {
    public var id: String { dispatchID }
    public let dispatchID: String
    public let runID: String
    public let runObjective: String
    public let taskLabel: String
    public let kind: String
    public let createdAt: String
    public let byteSize: Int
    public let reason: ArchivePruneReason

    public init(dispatchID: String, runID: String, runObjective: String, taskLabel: String,
                kind: String, createdAt: String, byteSize: Int, reason: ArchivePruneReason) {
        self.dispatchID = dispatchID
        self.runID = runID
        self.runObjective = runObjective
        self.taskLabel = taskLabel
        self.kind = kind
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.reason = reason
    }

    public var sizeLabel: String { VaultProjection.byteLabel(byteSize) }
    public var kindLabel: String { VaultProjection.kindLabel(kind) }
}

/// The dry-run preview, and — unchanged — the instruction a prune executes. Every
/// number the UI shows before deleting comes from here.
public struct ArchivePrunePlan: Equatable, Sendable {
    public let policy: ArchiveRetentionPolicy
    public let entries: [ArchivePruneEntry]
    /// Bytes the plan would free.
    public let freedBytes: Int
    /// Bytes currently held by every archive, protected ones included.
    public let totalBytes: Int
    public let totalCount: Int
    /// Archives skipped because their run still holds live coordination.
    public let protectedCount: Int
    public let protectedBytes: Int
    public let protectedRunIDs: [String]
    /// Bytes still above the size cap once every eligible archive is gone — a live
    /// run holding more than the cap cannot be pruned under it, and the preview says
    /// so instead of silently under-delivering.
    public let remainingOverBytes: Int

    public static let empty = ArchivePrunePlan(
        policy: .keepForever, entries: [], freedBytes: 0, totalBytes: 0, totalCount: 0,
        protectedCount: 0, protectedBytes: 0, protectedRunIDs: [], remainingOverBytes: 0)

    public init(policy: ArchiveRetentionPolicy, entries: [ArchivePruneEntry], freedBytes: Int,
                totalBytes: Int, totalCount: Int, protectedCount: Int, protectedBytes: Int,
                protectedRunIDs: [String], remainingOverBytes: Int) {
        self.policy = policy
        self.entries = entries
        self.freedBytes = freedBytes
        self.totalBytes = totalBytes
        self.totalCount = totalCount
        self.protectedCount = protectedCount
        self.protectedBytes = protectedBytes
        self.protectedRunIDs = protectedRunIDs
        self.remainingOverBytes = remainingOverBytes
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var dispatchIDs: [String] { entries.map(\.dispatchID) }
    public var freedLabel: String { VaultProjection.byteLabel(freedBytes) }
    public var totalLabel: String { VaultProjection.byteLabel(totalBytes) }
    public var ageEntries: [ArchivePruneEntry] { entries.filter { $0.reason == .age } }
    public var sizeEntries: [ArchivePruneEntry] { entries.filter { $0.reason == .size } }

    /// One line the preview leads with, so a user reads the consequence before the list.
    public var summary: String {
        guard !entries.isEmpty else {
            if policy.isDisabled { return "Retention is off — nothing would be deleted." }
            return "Nothing to prune: every archive is within the caps or belongs to a live run."
        }
        let count = "\(entries.count) archive\(entries.count == 1 ? "" : "s")"
        return "Delete \(count), freeing \(freedLabel) of \(totalLabel)."
    }
}

/// What a prune actually did, once the plan was confirmed.
public struct ArchivePruneReceipt: Equatable, Sendable {
    public let deletedCount: Int
    public let freedBytes: Int
    public let deletedDispatchIDs: [String]
    /// Previewed but no longer eligible when the prune ran (its run went live again,
    /// or the archive was already gone). Never deleted, always reported.
    public let skippedDispatchIDs: [String]

    public static let empty = ArchivePruneReceipt(
        deletedCount: 0, freedBytes: 0, deletedDispatchIDs: [], skippedDispatchIDs: [])

    public init(deletedCount: Int, freedBytes: Int, deletedDispatchIDs: [String],
                skippedDispatchIDs: [String]) {
        self.deletedCount = deletedCount
        self.freedBytes = freedBytes
        self.deletedDispatchIDs = deletedDispatchIDs
        self.skippedDispatchIDs = skippedDispatchIDs
    }

    public var freedLabel: String { VaultProjection.byteLabel(freedBytes) }
}

public enum ArchiveRetention {
    /// Select the archives a policy would delete.
    ///
    /// Rules, in order:
    /// 1. Archives whose run is live (or explicitly protected) are never selected.
    /// 2. Age: eligible archives older than `maxAgeDays` go, reason `.age`.
    /// 3. Size: if the *total* — protected archives included, since the cap is on what
    ///    is on disk — still exceeds `maxTotalBytes`, the oldest remaining eligible
    ///    archives go until it fits, reason `.size`.
    ///
    /// An archive whose timestamp does not parse is never age-selected and sorts last
    /// for size selection: an undateable row is the last thing to delete, not the first.
    public static func plan(
        records: [WorkerArchiveRecord],
        policy: ArchiveRetentionPolicy,
        now: Date,
        protectedRunIDs: Set<String>
    ) -> ArchivePrunePlan {
        let totalBytes = records.reduce(0) { $0 + $1.byteSize }
        let protectedRecords = records.filter { isProtected($0, protectedRunIDs) }
        let protectedBytes = protectedRecords.reduce(0) { $0 + $1.byteSize }
        let protectedRuns = orderedUnique(protectedRecords.map { $0.runID ?? VaultProjection.orphanRunID })

        guard !policy.isDisabled else {
            return ArchivePrunePlan(
                policy: policy, entries: [], freedBytes: 0, totalBytes: totalBytes,
                totalCount: records.count, protectedCount: protectedRecords.count,
                protectedBytes: protectedBytes, protectedRunIDs: protectedRuns,
                remainingOverBytes: 0)
        }

        let eligible = records.filter { !isProtected($0, protectedRunIDs) }
        var selected: [ArchivePruneEntry] = []
        var selectedIDs = Set<String>()
        var remainingBytes = totalBytes

        if policy.enforcesAge {
            let cutoff = now.addingTimeInterval(-Double(policy.maxAgeDays) * 86_400)
            for record in eligible {
                guard let date = timestamp(record.createdAt), date < cutoff else { continue }
                selected.append(entry(record, reason: .age))
                selectedIDs.insert(record.dispatchID)
                remainingBytes -= record.byteSize
            }
        }

        if policy.enforcesSize, remainingBytes > policy.maxTotalBytes {
            let oldestFirst = eligible
                .filter { !selectedIDs.contains($0.dispatchID) }
                .sorted { lhs, rhs in
                    let left = timestamp(lhs.createdAt) ?? .distantFuture
                    let right = timestamp(rhs.createdAt) ?? .distantFuture
                    if left != right { return left < right }
                    return lhs.dispatchID < rhs.dispatchID
                }
            for record in oldestFirst {
                guard remainingBytes > policy.maxTotalBytes else { break }
                selected.append(entry(record, reason: .size))
                selectedIDs.insert(record.dispatchID)
                remainingBytes -= record.byteSize
            }
        }

        let overBytes = policy.enforcesSize ? max(0, remainingBytes - policy.maxTotalBytes) : 0
        return ArchivePrunePlan(
            policy: policy,
            entries: selected,
            freedBytes: selected.reduce(0) { $0 + $1.byteSize },
            totalBytes: totalBytes,
            totalCount: records.count,
            protectedCount: protectedRecords.count,
            protectedBytes: protectedBytes,
            protectedRunIDs: protectedRuns,
            remainingOverBytes: overBytes)
    }

    /// An archive with no run cannot be protected by a live run — but it also cannot
    /// belong to one, so it is eligible like any settled run's leftovers.
    static func isProtected(_ record: WorkerArchiveRecord, _ protectedRunIDs: Set<String>) -> Bool {
        guard let runID = record.runID else { return false }
        return protectedRunIDs.contains(runID)
    }

    static func entry(_ record: WorkerArchiveRecord, reason: ArchivePruneReason) -> ArchivePruneEntry {
        ArchivePruneEntry(
            dispatchID: record.dispatchID,
            runID: record.runID ?? VaultProjection.orphanRunID,
            runObjective: record.runObjective ?? VaultProjection.orphanRunObjective,
            taskLabel: VaultProjection.taskLabel(record),
            kind: record.kind.rawValue,
            createdAt: record.createdAt,
            byteSize: record.byteSize,
            reason: reason)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Timestamps

    /// SQLite writes `datetime('now')` as UTC `yyyy-MM-dd HH:mm:ss`; ISO-8601 is
    /// accepted too so a hand-written or migrated row still dates correctly.
    public static func timestamp(_ raw: String) -> Date? {
        if let date = sqliteFormatter.date(from: raw) { return date }
        if let date = isoFormatter.date(from: raw) { return date }
        return isoFractionalFormatter.date(from: raw)
    }

    private static let sqliteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
