import Foundation
import OrchardRuntime

/// One workspace's in-memory browser state for the pane: ordered tabs plus the
/// visible selection. Lives for the app session, so switching workspaces (or
/// closing and reopening the pane) keeps every workspace's tabs.
@MainActor
final class WorkspaceBrowserController: ObservableObject, Identifiable {
    nonisolated let key: String
    @Published fileprivate(set) var tabs: [BrowserTabModel] = []
    @Published fileprivate(set) var activeTabID: String?

    init(key: String) {
        self.key = key
    }

    var activeTab: BrowserTabModel? {
        tabs.first { $0.id == activeTabID } ?? tabs.first
    }
}

/// The app half of the browser seam: implements `BrowserWebHost` over real
/// `WKWebView`s and hands the pane per-workspace controllers. All mutations of
/// tab structure flow through the runtime `BrowserService` (UI actions call its
/// verbs; the service calls back in here), so the CLI and the pane always see
/// the same tabs and snapshot invalidation happens in exactly one place.
@MainActor
final class BrowserManager: ObservableObject {
    let service: BrowserService

    // Not @Published: `controller(for:)` runs during SwiftUI body evaluation
    // (the pane materializes its workspace's controller on first render), and
    // publishing there would mutate state mid-update. Views observe the
    // controllers themselves, never this map.
    private var controllers: [String: WorkspaceBrowserController] = [:]
    private var tabsByID: [String: (tab: BrowserTabModel, workspaceKey: String)] = [:]

    init(service: BrowserService) {
        self.service = service
        Task { await service.attach(host: self) }
    }

    func controller(for key: String) -> WorkspaceBrowserController {
        if let existing = controllers[key] { return existing }
        let controller = WorkspaceBrowserController(key: key)
        controllers[key] = controller
        return controller
    }

    func tab(for pageId: String) -> BrowserTabModel? {
        tabsByID[pageId]?.tab
    }

    // MARK: - UI actions (all routed through the service's verbs)

    func openURL(_ text: String, workspaceKey: String, pageId: String?) {
        Task {
            do {
                _ = try await service.goto(workspace: workspaceKey, page: pageId, url: text)
            } catch {
                NSLog("orchard browser: goto failed: %@", String(describing: error))
            }
        }
    }

    func newTab(workspaceKey: String) {
        Task { _ = try? await service.createTab(workspace: workspaceKey) }
    }

    func closeTab(workspaceKey: String, pageId: String) {
        Task { try? await service.closeTab(workspace: workspaceKey, page: pageId) }
    }

    func selectTab(workspaceKey: String, pageId: String) {
        Task { _ = try? await service.switchTab(workspace: workspaceKey, page: pageId) }
    }

    func goBack(workspaceKey: String, pageId: String) {
        Task { _ = try? await service.goBack(workspace: workspaceKey, page: pageId) }
    }

    func goForward(workspaceKey: String, pageId: String) {
        Task { _ = try? await service.goForward(workspace: workspaceKey, page: pageId) }
    }

    func reload(workspaceKey: String, pageId: String) {
        Task { _ = try? await service.reload(workspace: workspaceKey, page: pageId) }
    }
}

// MARK: - BrowserWebHost

extension BrowserManager: BrowserWebHost {
    func createPage(workspace: String, pageId: String) async throws {
        let controller = controller(for: workspace)
        let tab = BrowserTabModel(id: pageId)
        tab.onCommit = { [service] id, url in
            Task { await service.pageDidCommitNavigation(pageId: id, url: url) }
        }
        tab.onStateChange = { [service] id, state in
            Task { await service.pageDidUpdate(pageId: id, state: state) }
        }
        controller.tabs.append(tab)
        if controller.activeTabID == nil { controller.activeTabID = pageId }
        tabsByID[pageId] = (tab, workspace)
    }

    func closePage(pageId: String) async {
        guard let entry = tabsByID.removeValue(forKey: pageId) else { return }
        entry.tab.tearDown()
        if let controller = controllers[entry.workspaceKey] {
            controller.tabs.removeAll { $0.id == pageId }
            if controller.activeTabID == pageId {
                controller.activeTabID = controller.tabs.last?.id
            }
        }
    }

    func showPage(pageId: String) async {
        guard let entry = tabsByID[pageId] else { return }
        controllers[entry.workspaceKey]?.activeTabID = pageId
    }

    func navigate(pageId: String, url: URL) async throws {
        try requireTab(pageId).load(url)
    }

    func goBack(pageId: String) async throws {
        try requireTab(pageId).goBack()
    }

    func goForward(pageId: String) async throws {
        try requireTab(pageId).goForward()
    }

    func reload(pageId: String) async throws {
        try requireTab(pageId).reload()
    }

    func evaluateJavaScript(pageId: String, script: String) async throws -> String {
        try await requireTab(pageId).evaluate(script)
    }

    func pageState(pageId: String) async throws -> BrowserPageState {
        try requireTab(pageId).pageState
    }

    func takeScreenshot(pageId: String) async throws -> Data {
        try await requireTab(pageId).takeScreenshot()
    }

    func consoleEntries(pageId: String) async throws -> [BrowserConsoleEntry] {
        try requireTab(pageId).consoleEntries
    }

    private func requireTab(_ pageId: String) throws -> BrowserTabModel {
        guard let entry = tabsByID[pageId] else {
            throw BrowserError.tabNotFound(pageId)
        }
        return entry.tab
    }
}
