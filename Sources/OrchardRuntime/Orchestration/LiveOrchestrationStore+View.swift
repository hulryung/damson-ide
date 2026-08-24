import Foundation
import OrchardOrchestration
import OrchardProtocol

// In-app orchestration view (T44 read snapshot, T47 guarded mutations).
// Snapshot/archive stay observation-only. Mutations call the same verb
// methods the CLI handlers use — no parallel store writes.

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
        let pendingGates = try store.listGates(status: .pending).map { gate in
            OrchestrationProjection.gateRow(
                id: gate.id, taskID: gate.taskID, question: gate.question,
                options: gate.options, status: gate.status.rawValue)
        }
        return OrchestrationProjection.snapshot(
            runs: runs, tasks: tasks, workers: workers,
            archivedDispatchIDs: archived, pendingGates: pendingGates)
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

    /// `worker-release` with the CLI flag vocabulary. The receipt or typed
    /// refusal is returned — never swallowed.
    public func viewWorkerRelease(dispatchID: String, runtime: WorkerRuntimeContext)
        async -> OrchestrationViewMutationResult {
        await viewPerform(action: OrchestrationViewControls.workerRelease, target: dispatchID) {
            try await self.workerRelease(["dispatch": .string(dispatchID)], runtime: runtime)
        }
    }

    /// `worker-retain` with the CLI flag vocabulary.
    public func viewWorkerRetain(dispatchID: String) async -> OrchestrationViewMutationResult {
        await viewPerform(action: OrchestrationViewControls.workerRetain, target: dispatchID) {
            try await self.workerRetain(["dispatch": .string(dispatchID)])
        }
    }

    /// `worker-stop` with the CLI flag vocabulary.
    public func viewWorkerStop(dispatchID: String, runtime: WorkerRuntimeContext)
        async -> OrchestrationViewMutationResult {
        await viewPerform(action: OrchestrationViewControls.workerStop, target: dispatchID) {
            try await self.workerStop(["dispatch": .string(dispatchID)], runtime: runtime)
        }
    }

    /// `gate-resolve` with the CLI flag vocabulary (`--id`, `--resolution`).
    public func viewGateResolve(gateID: String, resolution: String)
        async -> OrchestrationViewMutationResult {
        await viewPerform(action: OrchestrationViewControls.gateResolve, target: gateID) {
            try await self.gateResolve(["id": .string(gateID), "resolution": .string(resolution)])
        }
    }

    private func viewPerform(
        action: String, target: String, _ body: () async throws -> JSONValue
    ) async -> OrchestrationViewMutationResult {
        do {
            return OrchestrationViewControls.result(
                action: action, target: target, receipt: try await body())
        } catch let error as RPCServiceError {
            return OrchestrationViewControls.result(
                action: action, target: target, error: error)
        } catch let error as OrchestrationError {
            return OrchestrationViewControls.result(
                action: action, target: target, code: error.code, message: error.message)
        } catch {
            return OrchestrationViewControls.result(
                action: action, target: target,
                code: "orchestration_error", message: String(describing: error))
        }
    }
}
