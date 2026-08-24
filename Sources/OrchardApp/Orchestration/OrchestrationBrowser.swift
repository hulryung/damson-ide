import Foundation
import OrchardRuntime

/// Cheap observation of the in-process orchestration store, plus guarded
/// mutations that call the same worker/gate verbs the CLI uses.
@MainActor
final class OrchestrationBrowser: ObservableObject {
    static let refreshInterval: TimeInterval = 8

    @Published var snapshot = OrchestrationViewSnapshot.empty
    @Published var selection: OrchestrationSelection?
    @Published var archive: OrchestrationArchiveView?
    @Published var showRaw = false
    @Published var lastError: String?
    @Published var lastRefreshed: Date?
    @Published var audit: [OrchestrationViewMutationResult] = []
    @Published var lastOutcome: OrchestrationViewMutationResult?
    @Published var pendingConfirm: OrchestrationPendingConfirm?
    @Published var mutating = false
    @Published var freeformResolution = ""

    func refresh(from store: AppStore) async {
        guard let orchestration = store.runtime?.orchestration else {
            snapshot = .empty
            archive = nil
            lastError = store.runtime == nil
                ? "Runtime is unavailable; orchestration state cannot be read."
                : nil
            return
        }
        do {
            snapshot = try await orchestration.viewSnapshot()
            lastError = nil
            lastRefreshed = Date()
            await loadArchive(from: store)
        } catch {
            lastError = String(describing: error)
        }
    }

    func select(_ selection: OrchestrationSelection?, store: AppStore) async {
        self.selection = selection
        showRaw = false
        freeformResolution = ""
        await loadArchive(from: store)
    }

    private func loadArchive(from store: AppStore) async {
        guard case .dispatch(let id) = selection,
              let orchestration = store.runtime?.orchestration else {
            archive = nil
            return
        }
        do {
            archive = try await orchestration.viewArchive(dispatchID: id)
        } catch {
            archive = nil
            lastError = String(describing: error)
        }
    }

    func run(id: String) -> OrchestrationRunRow? {
        snapshot.runs.first { $0.id == id }
    }

    func task(id: String) -> OrchestrationTaskRow? {
        snapshot.runs.lazy.flatMap(\.tasks).first { $0.id == id }
    }

    func dispatch(id: String) -> OrchestrationDispatchRow? {
        snapshot.runs.lazy.flatMap(\.tasks).flatMap(\.dispatches).first { $0.id == id }
    }

    func task(forDispatch id: String) -> OrchestrationTaskRow? {
        snapshot.runs.lazy.flatMap(\.tasks).first { task in
            task.dispatches.contains { $0.id == id }
        }
    }

    func enablement(for dispatch: OrchestrationDispatchRow) -> OrchestrationViewEnablement {
        OrchestrationViewControls.enablement(
            dispatchStatus: dispatch.dispatchStatus,
            workerState: dispatch.workerState,
            terminalState: dispatch.terminalState,
            agentHandle: dispatch.agentHandle)
    }

    func requestRelease(_ dispatch: OrchestrationDispatchRow) {
        pendingConfirm = .release(dispatchID: dispatch.id, terminalHandle: dispatch.agentHandle)
    }

    func requestStop(_ dispatch: OrchestrationDispatchRow) {
        let title = task(forDispatch: dispatch.id)?.label ?? dispatch.id
        pendingConfirm = .stop(dispatchID: dispatch.id, taskTitle: title)
    }

    func confirmPending(store: AppStore) async {
        guard let pending = pendingConfirm else { return }
        pendingConfirm = nil
        switch pending {
        case .release(let dispatchID, _):
            await perform(store: store) { orch, runtime in
                await orch.viewWorkerRelease(dispatchID: dispatchID, runtime: runtime)
            }
        case .stop(let dispatchID, _):
            await perform(store: store) { orch, runtime in
                await orch.viewWorkerStop(dispatchID: dispatchID, runtime: runtime)
            }
        }
    }

    func retain(dispatchID: String, store: AppStore) async {
        await perform(store: store) { orch, _ in
            await orch.viewWorkerRetain(dispatchID: dispatchID)
        }
    }

    func resolveGate(gateID: String, resolution: String, store: AppStore) async {
        await perform(store: store) { orch, _ in
            await orch.viewGateResolve(gateID: gateID, resolution: resolution)
        }
    }

    private func perform(
        store: AppStore,
        _ body: (LiveOrchestrationStore, WorkerRuntimeContext) async -> OrchestrationViewMutationResult
    ) async {
        guard !mutating else { return }
        mutating = true
        defer { mutating = false }
        guard let runtime = store.runtime else {
            record(OrchestrationViewControls.result(
                action: "view", target: "runtime",
                code: "runtime_unavailable",
                message: "Runtime is unavailable; orchestration mutations cannot run."))
            return
        }
        record(await body(runtime.orchestration, runtime.workerRuntime))
        await refresh(from: store)
    }

    private func record(_ result: OrchestrationViewMutationResult) {
        lastOutcome = result
        audit.append(result)
    }
}

enum OrchestrationSelection: Hashable {
    case run(String)
    case task(String)
    case dispatch(String)
}

enum OrchestrationPendingConfirm: Identifiable, Equatable {
    case release(dispatchID: String, terminalHandle: String?)
    case stop(dispatchID: String, taskTitle: String)

    var id: String {
        switch self {
        case .release(let dispatchID, _): return "release:\(dispatchID)"
        case .stop(let dispatchID, _): return "stop:\(dispatchID)"
        }
    }

    var title: String {
        switch self {
        case .release(_, let handle):
            return OrchestrationViewControls.releaseConfirmTitle(terminalHandle: handle)
        case .stop(_, let taskTitle):
            return OrchestrationViewControls.stopConfirmTitle(taskTitle: taskTitle)
        }
    }

    var body: String {
        switch self {
        case .release(_, let handle):
            return OrchestrationViewControls.releaseConfirmBody(terminalHandle: handle)
        case .stop:
            return OrchestrationViewControls.stopConfirmBody()
        }
    }

    var confirmLabel: String {
        switch self {
        case .release: return "Release"
        case .stop: return "Stop"
        }
    }
}
