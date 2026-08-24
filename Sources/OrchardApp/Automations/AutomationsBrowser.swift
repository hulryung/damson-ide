import Foundation
import OrchardRuntime

/// Observation of the in-process automation service. Refreshed on window
/// focus, a modest timer (next-fire labels), and `AutomationService.changes()`.
@MainActor
final class AutomationsBrowser: ObservableObject {
    static let refreshInterval: TimeInterval = 8

    @Published var snapshot = AutomationViewSnapshot.empty
    @Published var automations: [Automation] = []
    @Published var selection: String?
    @Published var runs: [AutomationRunRow] = []
    @Published var lastError: String?
    @Published var lastRefreshed: Date?
    @Published var editor: AutomationEditorMode?
    @Published var pendingDelete: AutomationListRow?

    private var observeTask: Task<Void, Never>?

    func refresh(from store: AppStore) async {
        guard let service = store.runtime?.automationService else {
            snapshot = .empty
            automations = []
            runs = []
            lastError = store.runtime == nil
                ? "Runtime is unavailable; automations cannot be read."
                : nil
            return
        }
        automations = await service.list()
        snapshot = await service.viewSnapshot()
        lastError = nil
        lastRefreshed = Date()
        await loadRuns(from: service)
        if let selection, !snapshot.rows.contains(where: { $0.id == selection }) {
            self.selection = snapshot.rows.first?.id
            await loadRuns(from: service)
        }
    }

    func select(_ id: String?, store: AppStore) async {
        selection = id
        guard let service = store.runtime?.automationService else {
            runs = []
            return
        }
        await loadRuns(from: service)
    }

    func startObserving(store: AppStore) {
        observeTask?.cancel()
        observeTask = Task { [weak self] in
            guard let service = store.runtime?.automationService else { return }
            for await _ in await service.changes() {
                guard !Task.isCancelled else { break }
                await self?.refresh(from: store)
            }
        }
    }

    func stopObserving() {
        observeTask?.cancel()
        observeTask = nil
    }

    func setEnabled(_ id: String, enabled: Bool, store: AppStore) async {
        guard let service = store.runtime?.automationService else { return }
        do {
            _ = try await service.setEnabled(id, enabled: enabled)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh(from: store)
    }

    func save(_ automation: Automation, isNew: Bool, store: AppStore) async -> String? {
        guard let service = store.runtime?.automationService else {
            return "Runtime is unavailable."
        }
        do {
            if isNew {
                _ = try await service.create(automation)
            } else {
                _ = try await service.replace(automation)
            }
            lastError = nil
            editor = nil
            selection = automation.id
            await refresh(from: store)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    func confirmDelete(store: AppStore) async {
        guard let pending = pendingDelete,
              let service = store.runtime?.automationService else { return }
        do {
            _ = try await service.remove(pending.id)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        pendingDelete = nil
        if selection == pending.id { selection = nil }
        await refresh(from: store)
    }

    func selectedRow() -> AutomationListRow? {
        snapshot.rows.first { $0.id == selection }
    }

    func selectedAutomation() -> Automation? {
        guard let selection else { return nil }
        return automations.first { $0.id == selection }
    }

    private func loadRuns(from service: AutomationService) async {
        guard let selection else {
            runs = []
            return
        }
        runs = await service.runs(automationId: selection).map(AutomationProjection.runRow)
    }
}

enum AutomationEditorMode: Identifiable {
    case create
    case edit(Automation)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let automation): return automation.id
        }
    }

    var existing: Automation? {
        switch self {
        case .create: return nil
        case .edit(let automation): return automation
        }
    }
}
