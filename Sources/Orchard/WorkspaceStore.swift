import AppKit
import Combine
import UserNotifications
import DamsonTerminal
import DamsonOrchestrator

/// One orchestration workspace: a git repo plus its `OrchestratorController` (the brain
/// that spawns/drives agents in that repo's worktrees).
@MainActor
final class Workspace: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let repo: URL
    let controller: OrchestratorController

    init(repo: URL, settings: OrchardSettings) throws {
        self.repo = repo
        self.name = repo.lastPathComponent
        // Worktrees live outside the checkout (`~/Orchard/worktrees/<repo>/…` by default) so
        // file watchers, test globs, and language servers in the primary checkout never see
        // N copies of the project.
        self.controller = OrchestratorController(
            baseRepo: repo,
            worktreesRoot: settings.worktreeRoot(for: repo),
            configTemplate: settings.terminalConfig()
        )
        try controller.start()
        controller.setMaxConcurrency(settings.maxConcurrency)
        controller.runsSetupScripts = settings.runSetupScripts
        // An explicit override wins over whatever `start()` detected from the repo.
        let prefix = settings.branchPrefixOverride.trimmingCharacters(in: .whitespaces)
        if !prefix.isEmpty { controller.overrideBranchPrefix(prefix) }
        let base = settings.defaultBaseRefOverride.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty { controller.overrideBaseRef(base) }
    }
}

/// Top-level app state: workspaces, what's selected, which pane is showing, and the sheets
/// currently routed. Workspaces and theme persist across launches via `UserDefaults`;
/// worktrees persist in git itself and are restored by each controller.
@MainActor
final class WorkspaceStore: ObservableObject {
    /// Which view the main pane is showing for the selected worktree.
    enum MainTab: String, Hashable, CaseIterable {
        case agent, diff, terminal

        var label: String {
            switch self {
            case .agent: return "Agent"
            case .diff: return "Diff"
            case .terminal: return "Terminal"
            }
        }

        var symbol: String {
            switch self {
            case .agent: return "sparkles"
            case .diff: return "plusminus"
            case .terminal: return "terminal"
            }
        }
    }

    /// Layout the control CLI's `new-session` command can request.
    enum DetailMode: Hashable { case grid, tabs }

    /// What fills the main pane.
    ///
    /// The project root is a peer of the worktrees, not a fallback: a directory you've opened
    /// is usable — a terminal rooted there, its own diff — whether or not it has worktrees,
    /// and whether or not it's even a git repo. Without this, opening a fresh project put you
    /// in a dead-end empty state with nothing to type into.
    enum DetailSelection: Hashable {
        case projectRoot(Workspace.ID)
        case worktree(UUID)
    }

    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: Workspace.ID?
    @Published var selection: DetailSelection?
    @Published var mainTab: MainTab = .agent

    /// Non-nil drives the new-worktree composer for that workspace.
    @Published var composerWorkspaceID: Workspace.ID?
    /// Worktree pending a delete confirmation.
    @Published var pendingDeletion: WorktreeRecord?
    @Published var isJumpPaletteOpen = false

    /// Grid-of-all-terminals overview instead of the single focused worktree.
    @Published var showsGridOverview = false
    /// Retained so the orchard-cli `focus` command can name an agent.
    @Published var focusedAgentID: UUID?

    /// User preferences. The single owner of theme/font/concurrency — the store used to keep
    /// its own copy of the theme, which meant two sources of truth for one value.
    let settings: OrchardSettings

    private let defaults = UserDefaults.standard
    private let workspacesKey = "orchard.workspaces"
    private var notificationsAuthorized = false

    // Not defaulted: a default argument is evaluated in a nonisolated context, and
    // `OrchardSettings.init` is main-actor bound.
    init(settings: OrchardSettings) {
        self.settings = settings
        requestNotificationPermission()

        // Settings changes have to reach objects that already exist, not just future ones.
        settings.onConcurrencyChange = { [weak self] limit in
            self?.workspaces.forEach { $0.controller.setMaxConcurrency(limit) }
        }
        settings.onTerminalConfigChange = { [weak self] in
            self?.applyTerminalConfigToAll()
        }
    }

    var theme: DamsonTheme { settings.theme }

    /// Kept so the sidebar's quick theme menu can bind directly.
    var themeName: String {
        get { settings.themeName }
        set { settings.themeName = newValue }
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// The worktree the main pane is showing, or `nil` when the project root is selected.
    var selectedWorktree: WorktreeRecord? {
        guard case let .worktree(id) = selection else { return nil }
        for ws in workspaces {
            if let match = ws.controller.worktrees.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    /// Whether the main pane is showing the project root rather than a worktree.
    var showsProjectRoot: Bool {
        if case .projectRoot = selection { return true }
        return false
    }

    /// Retained for the control CLI, which addresses worktrees by id.
    var selectedWorktreeID: UUID? {
        if case let .worktree(id) = selection { return id }
        return nil
    }

    /// The workspace a worktree belongs to.
    func workspace(owning record: WorktreeRecord) -> Workspace? {
        workspaces.first { ws in ws.controller.worktrees.contains { $0.id == record.id } }
    }

    /// Every worktree across every open workspace, for the jump palette.
    var allWorktrees: [(workspace: Workspace, record: WorktreeRecord)] {
        workspaces.flatMap { ws in ws.controller.worktrees.map { (ws, $0) } }
    }

    // MARK: - Selection

    func select(_ record: WorktreeRecord, in workspace: Workspace? = nil) {
        if let workspace { selectedWorkspaceID = workspace.id }
        selection = .worktree(record.id)
        showsGridOverview = false
        record.hasUnseenActivity = false
        Task { await record.refresh() }
    }

    /// Show the project's own checkout — a terminal rooted there and its working-tree diff.
    func selectProjectRoot(_ workspace: Workspace) {
        selectedWorkspaceID = workspace.id
        selection = .projectRoot(workspace.id)
        showsGridOverview = false
    }

    /// What to show when a project is first opened: its newest worktree if it has one,
    /// otherwise the project root — never an empty pane.
    private func defaultSelection(for workspace: Workspace) -> DetailSelection {
        if let last = workspace.controller.worktrees.last { return .worktree(last.id) }
        return .projectRoot(workspace.id)
    }

    // MARK: - Workspaces

    /// Re-open workspaces saved from a previous launch (quietly skips missing/invalid repos).
    func restore() {
        guard let paths = defaults.stringArray(forKey: workspacesKey) else { return }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            addWorkspace(repo: url, silent: true)
        }
    }

    /// Choose a git repo and open it as a workspace.
    func addWorkspaceViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a git repository to orchestrate agents in."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addWorkspace(repo: url)
    }

    func addWorkspace(repo: URL, silent: Bool = false) {
        if let existing = workspaces.first(where: { $0.repo.standardizedFileURL == repo.standardizedFileURL }) {
            selectedWorkspaceID = existing.id
            selection = defaultSelection(for: existing)
            return
        }
        do {
            let ws = try Workspace(repo: repo, settings: settings)
            wireNotifications(for: ws)
            workspaces.append(ws)
            selectedWorkspaceID = ws.id
            selection = defaultSelection(for: ws)
            persistWorkspaces()
        } catch {
            guard !silent else { return }
            let alert = NSAlert()
            alert.messageText = "Couldn't open project"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    func removeWorkspace(_ ws: Workspace) {
        ws.controller.shutdown(removeWorktrees: false)
        workspaces.removeAll { $0.id == ws.id }
        if selectedWorkspaceID == ws.id {
            selectedWorkspaceID = workspaces.first?.id
            selection = workspaces.first.map(defaultSelection(for:))
        }
        persistWorkspaces()
    }

    // MARK: - Composer / actions

    /// Whether the selected project can host worktrees at all (a plain folder can't).
    var canCreateWorktree: Bool {
        selectedWorkspace?.controller.isGitRepository ?? false
    }

    /// Open the new-worktree composer for the selected workspace, or prompt to open a repo
    /// first if there isn't one.
    func requestNewWorktree() {
        guard let ws = selectedWorkspace else {
            addWorkspaceViaPanel()
            return
        }
        guard ws.controller.isGitRepository else { return }
        composerWorkspaceID = ws.id
    }

    /// Maximize one agent (kept for orchard-cli `focus`).
    func focus(_ agentID: UUID) {
        focusedAgentID = agentID
        if let ws = workspaces.first(where: { $0.controller.agents.contains { $0.id == agentID } }),
           let record = ws.controller.worktrees.first(where: { $0.agent?.id == agentID }) {
            select(record, in: ws)
        }
    }

    /// Kept for the control CLI's `add-task` / Cmd-T entry points.
    func requestAddTaskForSelected() { requestNewWorktree() }

    func requestNewSession(mode: DetailMode) {
        showsGridOverview = (mode == .grid)
        requestNewWorktree()
    }

    func shutdownAll() {
        for ws in workspaces { ws.controller.shutdown(removeWorktrees: false) }
    }

    /// Shells opened by views (Terminal tabs, project roots, the Agent tab's fallback).
    ///
    /// Agents are owned by their controller, but these are owned by SwiftUI view state, so
    /// they have to register to be reachable. This is the fix for a real bug: appearance
    /// settings used to reach agents only, which meant changing the font did nothing at all
    /// if you were looking at a shell — and a shell is what the app now opens by default.
    private var shells: [WeakShell] = []

    private struct WeakShell {
        weak var holder: ShellHolder?
    }

    func registerShell(_ holder: ShellHolder) {
        shells.removeAll { $0.holder == nil || $0.holder === holder }
        shells.append(WeakShell(holder: holder))
        holder.apply(settings.terminalConfig())
    }

    /// Push theme and font into every live terminal — agents *and* shells — so changing them
    /// in Settings is visible immediately rather than only in the next session you start.
    private func applyTerminalConfigToAll() {
        let config = settings.terminalConfig()
        for ws in workspaces {
            ws.controller.applyTerminalConfig(config)
        }
        shells.removeAll { $0.holder == nil }
        for shell in shells { shell.holder?.apply(config) }
        objectWillChange.send()
    }

    /// Live terminal appearance, for `orchard-cli terminal-info` — the only way to confirm
    /// from outside the app that a settings change actually landed.
    func terminalInfo() -> [String] {
        var out: [String] = ["settings: \(settings.fontFamily) \(settings.fontSize) / \(settings.themeName)"]
        for ws in workspaces {
            for agent in ws.controller.agents {
                let c = agent.damsonSession.config
                out.append("agent \(agent.shortID): \(c.fontFamily) \(c.fontSize) / \(c.theme.name)")
            }
        }
        shells.removeAll { $0.holder == nil }
        for (index, shell) in shells.enumerated() {
            guard let config = shell.holder?.session?.config else { continue }
            out.append("shell \(index): \(config.fontFamily) \(config.fontSize) / \(config.theme.name)")
        }
        return out
    }

    private func persistWorkspaces() {
        defaults.set(workspaces.map { $0.repo.path }, forKey: workspacesKey)
    }

    // MARK: - Notifications

    /// An agent that needs attention while the user is looking at a different worktree is
    /// the whole reason to run several at once — so the signal has to reach outside the app.
    private func wireNotifications(for ws: Workspace) {
        ws.controller.onAgentNeedsAttention = { [weak self, weak ws] record, state in
            guard let self, let ws else { return }
            let isOnScreen = self.selectedWorkspaceID == ws.id
                && self.selectedWorktree?.id == record.id
                && NSApp.isActive
            guard !isOnScreen else { return }
            record.hasUnseenActivity = true
            self.notify(record: record, workspace: ws, state: state)
        }
        ws.controller.onError = { message in
            NSLog("orchard: %@", message)
        }
    }

    private func requestNotificationPermission() {
        // Only a bundled app has a notification-capable bundle id; running the bare binary
        // (ORCHARD_NO_TRAMPOLINE=1, as the CLI harness does) would trap inside
        // UNUserNotificationCenter rather than merely failing to authorize.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.notificationsAuthorized = granted }
            }
    }

    private func notify(record: WorktreeRecord, workspace: Workspace, state: WorktreeDisplayState) {
        guard notificationsAuthorized, settings.notificationsEnabled else { return }
        // "Only when blocked" still covers a failure — an agent that died needs you just as
        // much as one waiting on approval, it just can't ask.
        if settings.notifyOnlyWhenBlocked, !state.isBlocking, state != .failed { return }
        let content = UNMutableNotificationContent()
        content.title = "\(record.title) · \(workspace.name)"
        switch state {
        case .needsApproval: content.body = "Waiting for your approval."
        case .needsInput: content.body = "Waiting for your input."
        case .done: content.body = "Finished."
        case .failed: content.body = "Stopped with an error."
        default: content.body = "Finished a turn."
        }
        content.sound = state.isBlocking ? .default : nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: record.id.uuidString,
                                  content: content, trigger: nil))
    }
}
