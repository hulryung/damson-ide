import Foundation
import OrchardRuntime

/// Observation of local workspace disk usage. Subjects come from the in-memory
/// sidebar (projects + extra worktrees) so a refresh never asks git. The walk
/// itself is off the main actor.
@MainActor
final class SpaceBrowser: ObservableObject {
    @Published var snapshot = WorkspaceSpaceSnapshot.empty
    @Published var subjects: [WorkspaceSpaceSubject] = []
    @Published var query = ""
    @Published var sortKey: WorkspaceSpaceSortKey = .size
    @Published var sortAscending = false
    @Published var onlyDeletable = false
    @Published var selection: String?
    @Published var isScanning = false
    @Published var scannedCount = 0
    @Published var lastError: String?
    @Published var lastRefreshed: Date?
    @Published var pendingDeletion: AppStore.PendingDeletion?

    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?

    var visibleRows: [WorkspaceSpaceRow] {
        let direction: WorkspaceSpaceSortDirection = sortAscending ? .ascending : .descending
        let filtered = WorkspaceSpaceProjection.filter(
            snapshot.rows, query: query, onlyDeletable: onlyDeletable)
        return WorkspaceSpaceProjection.sort(filtered, key: sortKey, direction: direction)
    }

    var visibleGroups: [WorkspaceSpaceRepoGroup] {
        WorkspaceSpaceProjection.groups(visibleRows)
    }

    var selectedRow: WorkspaceSpaceRow? {
        guard let selection else { return nil }
        return snapshot.row(id: selection) ?? visibleRows.first { $0.id == selection }
    }

    var largestVisibleBytes: Int {
        WorkspaceSpaceProjection.largestRowSize(visibleRows)
    }

    var progressLabel: String? {
        guard isScanning else { return nil }
        if subjects.isEmpty { return "Scanning workspace sizes" }
        return "Scanning \(scannedCount) of \(subjects.count)"
    }

    func refresh(from store: AppStore) {
        let next = Self.subjects(from: store)
        subjects = next
        scanGeneration += 1
        let generation = scanGeneration
        scanTask?.cancel()
        scannedCount = 0
        isScanning = !next.isEmpty
        lastError = nil
        if next.isEmpty {
            snapshot = .empty
            isScanning = false
            lastRefreshed = Date()
            return
        }
        snapshot = WorkspaceSpaceProjection.snapshot(
            subjects: next, measurements: [:], scannedAt: nil)
        let captured = next
        scanTask = Task.detached(priority: .utility) { [weak self] in
            var measurements: [String: WorkspaceSpaceMeasurement] = [:]
            for (index, subject) in captured.enumerated() {
                if Task.isCancelled { return }
                let measured: WorkspaceSpaceMeasurement
                if subject.isRemote {
                    measured = .unavailable(WorkspaceSpaceProjection.remoteUnavailableMessage)
                } else {
                    measured = WorkspaceSpaceScanner.measure(path: subject.path)
                }
                measurements[subject.id] = measured
                let snapshot = WorkspaceSpaceProjection.snapshot(
                    subjects: captured, measurements: measurements, scannedAt: Date())
                let done = index + 1
                let total = captured.count
                await self?.applyScanProgress(
                    generation: generation, snapshot: snapshot, done: done, total: total)
            }
        }
    }

    private func applyScanProgress(generation: Int, snapshot: WorkspaceSpaceSnapshot,
                                   done: Int, total: Int) {
        guard scanGeneration == generation else { return }
        self.snapshot = snapshot
        scannedCount = done
        isScanning = done < total
        if done == total {
            lastRefreshed = Date()
        }
        if let selection,
           !snapshot.rows.contains(where: { $0.id == selection }) {
            self.selection = snapshot.rows.first?.id
        } else if selection == nil {
            selection = snapshot.rows.first?.id
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func requestDelete(_ row: WorkspaceSpaceRow, store: AppStore) {
        guard row.canDelete, let recordID = row.subject.recordID else { return }
        guard let project = store.projects.first(where: { $0.id == row.subject.projectID }),
              let record = project.record(id: recordID) else { return }
        pendingDeletion = AppStore.PendingDeletion(
            id: record.id, projectID: project.id, record: record)
    }

    func open(_ row: WorkspaceSpaceRow, store: AppStore) {
        _ = store.focusWorkspaceIdentity(row.id)
    }

    /// Sidebar-shaped inventory: each project's primary checkout plus every
    /// extra worktree card. Remote subjects are marked, never walked.
    static func subjects(from store: AppStore) -> [WorkspaceSpaceSubject] {
        var out: [WorkspaceSpaceSubject] = []
        for project in store.projects {
            let repoID = project.repoID ?? project.id.uuidString
            let repoPath = project.repo.standardizedFileURL.path
            let primaryID = "\(repoID)::\(repoPath)"
            let kind = (!project.isRemote && !project.worktrees.isGitRepository)
                ? "folder" : "worktree"
            out.append(WorkspaceSpaceSubject(
                id: primaryID,
                recordID: nil,
                projectID: project.id,
                repoID: repoID,
                repoName: project.name,
                displayName: project.name,
                path: repoPath,
                branch: project.rootSubtitle,
                hostId: project.hostId,
                isMainWorktree: true,
                isRemote: project.isRemote,
                isArchived: false,
                lastActivityAt: Date.distantPast,
                kind: kind))
            for record in project.records {
                let identity = store.workspaceIdentity(for: record, in: project)
                    ?? "\(repoID)::\(record.path.standardizedFileURL.path)"
                out.append(WorkspaceSpaceSubject(
                    id: identity,
                    recordID: record.id,
                    projectID: project.id,
                    repoID: repoID,
                    repoName: project.name,
                    displayName: record.title,
                    path: record.path.standardizedFileURL.path,
                    branch: record.branch,
                    hostId: project.hostId,
                    isMainWorktree: false,
                    isRemote: project.isRemote,
                    isArchived: record.meta.isArchived,
                    lastActivityAt: record.meta.lastActivityAt,
                    kind: kind))
            }
        }
        return out
    }
}
