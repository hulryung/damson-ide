import Foundation
import OrchardRuntime

/// Cheap observation of the in-process orchestration store. Refreshed on
/// window focus and a modest timer — never subscribed to the hot path.
@MainActor
final class OrchestrationBrowser: ObservableObject {
    static let refreshInterval: TimeInterval = 8

    @Published var snapshot = OrchestrationViewSnapshot.empty
    @Published var selection: OrchestrationSelection?
    @Published var archive: OrchestrationArchiveView?
    @Published var showRaw = false
    @Published var lastError: String?
    @Published var lastRefreshed: Date?

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
}

enum OrchestrationSelection: Hashable {
    case run(String)
    case task(String)
    case dispatch(String)
}
