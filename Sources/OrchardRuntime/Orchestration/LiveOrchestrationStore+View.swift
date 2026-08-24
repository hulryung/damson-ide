import Foundation
import OrchardOrchestration

// Read-only snapshot for the in-app orchestration view (T44). Observation
// only — these methods never write the store. Archive text uses the same
// `worker_terminal_archives` row `worker-read` serves.

extension LiveOrchestrationStore {
    /// Runs → tasks → dispatches, projected from the live store. Cheap enough
    /// for a focus refresh plus a modest timer; not wired to the hot path.
    public func viewSnapshot() throws -> OrchestrationViewSnapshot {
        let runs = try store.listRuns()
        let tasks = try store.listTasks()
        let workers = try store.listWorkerRows()
        var archived = Set<String>()
        for worker in workers {
            if try store.workerTerminalArchive(dispatchID: worker.dispatchID) != nil {
                archived.insert(worker.dispatchID)
            }
        }
        return OrchestrationProjection.snapshot(
            runs: runs, tasks: tasks, workers: workers, archivedDispatchIDs: archived)
    }

    /// The pinned archive for a dispatch, decoded the way `worker-read` answers
    /// (`lines` / `rawLines` or a transcript `content` field). Nil when nothing
    /// was preserved — a live worker has no archive yet.
    public func viewArchive(dispatchID: String) throws -> OrchestrationArchiveView? {
        guard let archive = try store.workerTerminalArchive(dispatchID: dispatchID) else {
            return nil
        }
        return OrchestrationProjection.archiveView(
            dispatchID: dispatchID,
            kind: archive.kind.rawValue,
            contentJSON: archive.content)
    }
}
