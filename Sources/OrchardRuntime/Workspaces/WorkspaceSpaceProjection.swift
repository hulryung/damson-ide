import Foundation

/// Typed outcome of walking one workspace path (Orca `WorkspaceSpaceScanStatus`).
public enum WorkspaceSpaceScanStatus: String, Sendable, Equatable {
    case ok
    case missing
    case permissionDenied = "permission-denied"
    case unavailable
    case error

    public var label: String {
        switch self {
        case .ok: return "Scanned"
        case .missing: return "Missing"
        case .permissionDenied: return "No access"
        case .unavailable: return "Unavailable"
        case .error: return "Failed"
        }
    }
}

public enum WorkspaceSpaceItemKind: String, Sendable, Equatable {
    case directory, file, symlink, other
}

public struct WorkspaceSpaceItem: Equatable, Sendable, Identifiable {
    public var id: String { path.isEmpty ? "other:\(name)" : path }
    public var name: String
    public var path: String
    public var kind: WorkspaceSpaceItemKind
    public var sizeBytes: Int

    public init(name: String, path: String, kind: WorkspaceSpaceItemKind, sizeBytes: Int) {
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
    }

    public var sizeLabel: String { WorkspaceSpaceProjection.byteLabel(sizeBytes) }
}

/// One filesystem walk. Built by `WorkspaceSpaceScanner`; the projection never
/// walks disk itself.
public struct WorkspaceSpaceMeasurement: Equatable, Sendable {
    public var status: WorkspaceSpaceScanStatus
    public var error: String?
    public var sizeBytes: Int
    public var skippedEntryCount: Int
    public var topLevelItems: [WorkspaceSpaceItem]
    public var omittedTopLevelItemCount: Int
    public var omittedTopLevelSizeBytes: Int

    public init(status: WorkspaceSpaceScanStatus, error: String? = nil, sizeBytes: Int = 0,
                skippedEntryCount: Int = 0, topLevelItems: [WorkspaceSpaceItem] = [],
                omittedTopLevelItemCount: Int = 0, omittedTopLevelSizeBytes: Int = 0) {
        self.status = status
        self.error = error
        self.sizeBytes = sizeBytes
        self.skippedEntryCount = skippedEntryCount
        self.topLevelItems = topLevelItems
        self.omittedTopLevelItemCount = omittedTopLevelItemCount
        self.omittedTopLevelSizeBytes = omittedTopLevelSizeBytes
    }

    public static func unavailable(_ message: String) -> WorkspaceSpaceMeasurement {
        WorkspaceSpaceMeasurement(status: .unavailable, error: message)
    }

    public static let unscanned = WorkspaceSpaceMeasurement(
        status: .error, error: "Not scanned")
}

/// A workspace the Space view can measure. Built from in-memory app/runtime
/// state — never from a git spawn — so a Space refresh cannot hitch a
/// workspace switch.
public struct WorkspaceSpaceSubject: Equatable, Sendable, Identifiable {
    public var id: String
    public var recordID: UUID?
    public var projectID: UUID
    public var repoID: String
    public var repoName: String
    public var displayName: String
    public var path: String
    public var branch: String
    public var hostId: String
    public var isMainWorktree: Bool
    public var isRemote: Bool
    public var isArchived: Bool
    public var lastActivityAt: Date
    public var kind: String

    public init(id: String, recordID: UUID?, projectID: UUID, repoID: String,
                repoName: String, displayName: String, path: String, branch: String,
                hostId: String, isMainWorktree: Bool, isRemote: Bool,
                isArchived: Bool, lastActivityAt: Date, kind: String) {
        self.id = id
        self.recordID = recordID
        self.projectID = projectID
        self.repoID = repoID
        self.repoName = repoName
        self.displayName = displayName
        self.path = path
        self.branch = branch
        self.hostId = hostId
        self.isMainWorktree = isMainWorktree
        self.isRemote = isRemote
        self.isArchived = isArchived
        self.lastActivityAt = lastActivityAt
        self.kind = kind
    }
}

public struct WorkspaceSpaceRow: Equatable, Sendable, Identifiable {
    public var id: String { subject.id }
    public var subject: WorkspaceSpaceSubject
    public var status: WorkspaceSpaceScanStatus
    public var error: String?
    public var sizeBytes: Int
    public var reclaimableBytes: Int
    public var skippedEntryCount: Int
    public var topLevelItems: [WorkspaceSpaceItem]
    public var omittedTopLevelItemCount: Int
    public var omittedTopLevelSizeBytes: Int

    public init(subject: WorkspaceSpaceSubject, status: WorkspaceSpaceScanStatus,
                error: String?, sizeBytes: Int, reclaimableBytes: Int,
                skippedEntryCount: Int, topLevelItems: [WorkspaceSpaceItem],
                omittedTopLevelItemCount: Int, omittedTopLevelSizeBytes: Int) {
        self.subject = subject
        self.status = status
        self.error = error
        self.sizeBytes = sizeBytes
        self.reclaimableBytes = reclaimableBytes
        self.skippedEntryCount = skippedEntryCount
        self.topLevelItems = topLevelItems
        self.omittedTopLevelItemCount = omittedTopLevelItemCount
        self.omittedTopLevelSizeBytes = omittedTopLevelSizeBytes
    }

    public var displayName: String { subject.displayName }
    public var repoName: String { subject.repoName }
    public var path: String { subject.path }
    public var isMainWorktree: Bool { subject.isMainWorktree }
    public var isRemote: Bool { subject.isRemote }
    public var canDelete: Bool {
        WorkspaceSpaceProjection.canDelete(subject: subject, status: status)
    }
    public var sizeLabel: String { WorkspaceSpaceProjection.byteLabel(sizeBytes) }
    public var reclaimableLabel: String { WorkspaceSpaceProjection.byteLabel(reclaimableBytes) }
    public var statusLabel: String { status.label }
    public var branchLabel: String {
        WorkspaceSpaceProjection.branchLabel(branch: subject.branch, isMain: subject.isMainWorktree)
    }

    public var searchText: String {
        [
            subject.displayName, subject.repoName, subject.branch, subject.path,
            status.label, subject.kind, isMainWorktree ? "main" : "extra",
        ]
        .joined(separator: " ")
        .lowercased()
    }
}

public struct WorkspaceSpaceRepoGroup: Equatable, Sendable, Identifiable {
    public var id: String { repoID }
    public var repoID: String
    public var repoName: String
    public var isRemote: Bool
    public var rows: [WorkspaceSpaceRow]

    public init(repoID: String, repoName: String, isRemote: Bool, rows: [WorkspaceSpaceRow]) {
        self.repoID = repoID
        self.repoName = repoName
        self.isRemote = isRemote
        self.rows = rows
    }

    public var worktreeCount: Int { rows.count }
    public var scannedCount: Int { rows.filter { $0.status == .ok }.count }
    public var unavailableCount: Int { rows.filter { $0.status != .ok }.count }
    public var totalSizeBytes: Int { rows.reduce(0) { $0 + $1.sizeBytes } }
    public var reclaimableBytes: Int { rows.reduce(0) { $0 + $1.reclaimableBytes } }
    public var sizeLabel: String { WorkspaceSpaceProjection.byteLabel(totalSizeBytes) }
    public var reclaimableLabel: String { WorkspaceSpaceProjection.byteLabel(reclaimableBytes) }
}

public struct WorkspaceSpaceSnapshot: Equatable, Sendable {
    public var scannedAt: Date?
    public var rows: [WorkspaceSpaceRow]
    public static let empty = WorkspaceSpaceSnapshot(scannedAt: nil, rows: [])

    public init(scannedAt: Date?, rows: [WorkspaceSpaceRow]) {
        self.scannedAt = scannedAt
        self.rows = rows
    }

    public var worktreeCount: Int { rows.count }
    public var scannedCount: Int { rows.filter { $0.status == .ok }.count }
    public var unavailableCount: Int { rows.filter { $0.status != .ok }.count }
    public var totalSizeBytes: Int { rows.reduce(0) { $0 + $1.sizeBytes } }
    public var reclaimableBytes: Int { rows.reduce(0) { $0 + $1.reclaimableBytes } }
    public var sizeLabel: String { WorkspaceSpaceProjection.byteLabel(totalSizeBytes) }
    public var reclaimableLabel: String { WorkspaceSpaceProjection.byteLabel(reclaimableBytes) }
    public var isEmpty: Bool { rows.isEmpty }

    public func row(id: String) -> WorkspaceSpaceRow? {
        rows.first { $0.id == id }
    }
}

public enum WorkspaceSpaceSortKey: String, CaseIterable, Sendable {
    case size, name, repo, activity
    public var label: String {
        switch self {
        case .size: return "Size"
        case .name: return "Name"
        case .repo: return "Repo"
        case .activity: return "Activity"
        }
    }
}

public enum WorkspaceSpaceSortDirection: String, Sendable {
    case ascending, descending
}

/// UI-free Space view: combine subjects with measurements, sort, filter, format.
/// Observation only — never walks disk, never writes git or worktree meta.
public enum WorkspaceSpaceProjection {
    public static let maxTopLevelItems = 48
    public static let filterQueryMaxBytes = 2 * 1024
    public static let remoteUnavailableMessage =
        "Remote worktrees are not scanned from this machine."

    public static func canDelete(subject: WorkspaceSpaceSubject,
                                 status: WorkspaceSpaceScanStatus) -> Bool {
        !subject.isMainWorktree
            && !subject.isRemote
            && subject.recordID != nil
            && status != .unavailable
    }

    public static func reclaimableBytes(isMainWorktree: Bool, status: WorkspaceSpaceScanStatus,
                                        sizeBytes: Int) -> Int {
        (isMainWorktree || status != .ok) ? 0 : sizeBytes
    }

    public static func snapshot(subjects: [WorkspaceSpaceSubject],
                                measurements: [String: WorkspaceSpaceMeasurement],
                                scannedAt: Date?) -> WorkspaceSpaceSnapshot {
        let rows = subjects.map { subject -> WorkspaceSpaceRow in
            let measurement: WorkspaceSpaceMeasurement
            if subject.isRemote {
                measurement = .unavailable(remoteUnavailableMessage)
            } else {
                measurement = measurements[subject.id] ?? .unscanned
            }
            return row(subject: subject, measurement: measurement)
        }
        return WorkspaceSpaceSnapshot(scannedAt: scannedAt, rows: rows)
    }

    public static func row(subject: WorkspaceSpaceSubject,
                           measurement: WorkspaceSpaceMeasurement) -> WorkspaceSpaceRow {
        WorkspaceSpaceRow(
            subject: subject,
            status: measurement.status,
            error: measurement.error,
            sizeBytes: measurement.sizeBytes,
            reclaimableBytes: reclaimableBytes(
                isMainWorktree: subject.isMainWorktree,
                status: measurement.status,
                sizeBytes: measurement.sizeBytes),
            skippedEntryCount: measurement.skippedEntryCount,
            topLevelItems: measurement.topLevelItems,
            omittedTopLevelItemCount: measurement.omittedTopLevelItemCount,
            omittedTopLevelSizeBytes: measurement.omittedTopLevelSizeBytes)
    }

    public static func sort(_ rows: [WorkspaceSpaceRow],
                            key: WorkspaceSpaceSortKey,
                            direction: WorkspaceSpaceSortDirection) -> [WorkspaceSpaceRow] {
        let multiplier = direction == .ascending ? 1 : -1
        return rows.sorted { left, right in
            let primary = compare(left, right, key: key) * multiplier
            if primary != 0 { return primary < 0 }
            if left.sizeBytes != right.sizeBytes { return left.sizeBytes > right.sizeBytes }
            return left.displayName.localizedCompare(right.displayName) == .orderedAscending
        }
    }

    public static func filter(_ rows: [WorkspaceSpaceRow], query: String,
                              onlyDeletable: Bool) -> [WorkspaceSpaceRow] {
        if isFilterQueryTooLarge(query) { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            if onlyDeletable && !row.canDelete { return false }
            if needle.isEmpty { return true }
            return row.searchText.contains(needle)
        }
    }

    public static func groups(_ rows: [WorkspaceSpaceRow]) -> [WorkspaceSpaceRepoGroup] {
        var order: [String] = []
        var byRepo: [String: [WorkspaceSpaceRow]] = [:]
        var names: [String: String] = [:]
        var remote: [String: Bool] = [:]
        for row in rows {
            if byRepo[row.subject.repoID] == nil {
                order.append(row.subject.repoID)
                names[row.subject.repoID] = row.repoName
                remote[row.subject.repoID] = row.isRemote
            }
            byRepo[row.subject.repoID, default: []].append(row)
        }
        return order.map { id in
            WorkspaceSpaceRepoGroup(
                repoID: id,
                repoName: names[id] ?? id,
                isRemote: remote[id] ?? false,
                rows: byRepo[id] ?? [])
        }
    }

    public static func compactTopLevelItems(_ items: [WorkspaceSpaceItem])
        -> (items: [WorkspaceSpaceItem], omittedCount: Int, omittedBytes: Int) {
        let sorted = items.sorted { left, right in
            if left.sizeBytes != right.sizeBytes { return left.sizeBytes > right.sizeBytes }
            return left.name.localizedCompare(right.name) == .orderedAscending
        }
        if sorted.count <= maxTopLevelItems {
            return (sorted, 0, 0)
        }
        let visible = Array(sorted.prefix(maxTopLevelItems - 1))
        let omitted = Array(sorted.dropFirst(maxTopLevelItems - 1))
        let omittedBytes = omitted.reduce(0) { $0 + $1.sizeBytes }
        let other = WorkspaceSpaceItem(
            name: "Other", path: "", kind: .other, sizeBytes: omittedBytes)
        return (visible + [other], omitted.count, omittedBytes)
    }

    public static func isFilterQueryTooLarge(_ query: String) -> Bool {
        query.utf8.count > filterQueryMaxBytes
    }

    public static func branchLabel(branch: String, isMain: Bool) -> String {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("refs/heads/")
            ? String(trimmed.dropFirst("refs/heads/".count))
            : trimmed
        if stripped.isEmpty { return isMain ? "main worktree" : "detached" }
        return stripped
    }

    /// Binary-prefix sizes, matching Vault's retention preview shape.
    public static func byteLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(max(0, bytes)) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }

    public static func sizeFraction(sizeBytes: Int, largestBytes: Int) -> Double {
        guard largestBytes > 0 else { return 0 }
        return min(1, Double(max(0, sizeBytes)) / Double(largestBytes))
    }

    public static func largestRowSize(_ rows: [WorkspaceSpaceRow]) -> Int {
        rows.map(\.sizeBytes).max() ?? 0
    }

    private static func compare(_ left: WorkspaceSpaceRow, _ right: WorkspaceSpaceRow,
                                key: WorkspaceSpaceSortKey) -> Int {
        switch key {
        case .size:
            return left.sizeBytes < right.sizeBytes ? -1
                : left.sizeBytes > right.sizeBytes ? 1 : 0
        case .name:
            return compareText(left.displayName, right.displayName)
        case .repo:
            let repo = compareText(left.repoName, right.repoName)
            return repo != 0 ? repo : compareText(left.displayName, right.displayName)
        case .activity:
            if left.subject.lastActivityAt < right.subject.lastActivityAt { return -1 }
            if left.subject.lastActivityAt > right.subject.lastActivityAt { return 1 }
            return 0
        }
    }

    private static func compareText(_ left: String, _ right: String) -> Int {
        switch left.localizedCompare(right) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }
}
