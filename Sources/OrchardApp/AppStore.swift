import AppKit
import Combine
import DamsonTerminal
import Foundation
import UserNotifications
import OrchardCore
import OrchardRuntime
import OrchardTerminals

/// Top-level app client of the in-process runtime.
///
/// The app hosts `OrchardRuntimeHost` in-process: the unix-socket control plane,
/// the live orchestration store, and the terminal/workspace services boot with the
/// app, and every `AgentSupervisor` is attached so its PTYs carry the ORCHARD_*
/// identity env and register into T3's terminal registry. The UI still drives
/// `WorktreeService` / `AgentSupervisor` directly and observes their
/// `AsyncStream<OrchardEvent>`. Views must not spawn PTYs or keep engine
/// sessions of their own — shells live here, keyed by tab id.
///
/// Sidebar project membership is the runtime repo registry (`orchard-data.json`),
/// not UserDefaults. Open Project and `orchard repo add` both write that
/// registry; the store observes `WorkspaceService.repoChanges()`.
@MainActor
final class AppStore: ObservableObject {
    let settings: OrchardSettings
    let meta: WorkspaceMetaStore
    /// The in-process runtime (nil only if its data directory is unusable).
    let runtime: OrchardRuntimeHost?
    /// Same instance the CLI `repo-add` handler mutates when the host is live.
    let workspaceService: WorkspaceService
    /// T10: WKWebView host for the runtime's browser service (nil with no runtime).
    let browser: BrowserManager?

    @Published var projects: [ProjectSession] = []
    @Published var selectedProjectID: UUID?
    @Published var selection: WorkbenchKey? {
        // Every selection path (card tap, restore, deletion fallback) must leave a
        // stored layout behind so rendering never has to create one (see layout(for:)).
        didSet {
            guard let selection else { return }
            let node = ensureLayout(for: selection)
            // Menubar split/new-tab act on the focused group; retarget it when
            // the workspace changes (ensureLayout only sets it on first create).
            focusedGroupID = node.firstGroupID()
        }
    }
    @Published var filterProjectID: UUID?
    /// Board-column id from the workspace-status vocabulary (defaults + custom).
    @Published var filterStatusID: String?
    /// Archived cards stay hidden until this filter is on.
    @Published var showArchived = false
    /// When on, cards are grouped by user-set board column instead of by repo.
    @Published var groupByStatus = false
    @Published var ordering: CardOrdering = .manual

    @Published var composerProjectID: UUID?
    @Published var pendingDeletion: PendingDeletion?
    @Published var isJumpPaletteOpen = false
    @Published var isOpenRemotePresented = false

    /// Single unread source for cards and the dashboard. Views must not keep
    /// their own sets — fold events through `UnreadReducer`.
    @Published private(set) var unread = UnreadState()
    /// File the palette / `file open` asked the workbench to show.
    @Published var pendingOpenPath: String?
    /// Live `AgentStatusSnapshot` per agent, observation-only from the status stream.
    @Published private(set) var agentStatusByID: [UUID: AgentStatusSnapshot] = [:]
    /// Last completed T20 port sweep (attributed listeners only).
    @Published private(set) var portSnapshot = PortScanSnapshot.empty
    /// T45: last published per-host reachability. Presentation-only — a status
    /// change never folds into workspace, worktree, terminal, or worker state.
    @Published private(set) var hostLiveness = HostLivenessSnapshot.empty

    /// Currently focused tab group, so split/new-tab commands have a target.
    @Published var focusedGroupID: UUID?

    /// T23: standardized repo path → hook-server port persisted at keeper handoff.
    /// Filled by `KeeperRestart.prepareBoot` before `restore()` opens projects, so
    /// each restored project's supervisor rebinds the port its surviving agents'
    /// installed hook configs already point at.
    var keeperHookPortHints: [String: UInt16] = [:]

    @Published var layouts: [WorkbenchKey: SplitNode] = [:]

    /// Bounded chat transcripts keyed by tab id (app-session lifetime).
    private var chatControllers: [UUID: ChatPaneController] = [:]
    /// Open editor buffers, keyed by workspace root + relative path.
    let editorSessions = EditorSessionStore()

    var focusMainWindow: (() -> Void)?
    var showDashboard: (() -> Void)?
    var showOrchestration: (() -> Void)?
    var showAutomations: (() -> Void)?
    var showVault: (() -> Void)?
    var showSettings: (() -> Void)?
    var showFloatingTerminal: (() -> Void)?
    var hideFloatingTerminal: (() -> Void)?

    /// The one floating-terminal window's binding. Nil means the window is
    /// closed; the pane's session is not terminated.
    @Published var floatingTerminal: FloatingTerminalTarget?

    /// Truthful control-plane presence for the Dock / app menu (T51).
    /// "Alive" only when this process has a listening runtime socket — not merely
    /// because the app process is still running after the workbench closed.
    var runtimePresence: WindowLifecycle.RuntimeIndication {
        WindowLifecycle.runtimeIndication(
            hostConstructed: runtime != nil,
            socketListening: runtime?.socketServer != nil,
            runtimeId: runtime?.runtimeId)
    }

    private var shells: [UUID: DamsonSession] = [:]
    /// T29: what a remote pane's PTY ending proved, in verdict language. Keyed by tab
    /// id. Published so the pane can say "the connection ended" instead of implying the
    /// remote work died — loss of contact is never evidence of death.
    @Published private(set) var connectionNotes: [UUID: String] = [:]
    /// T43: the durable pane key behind each remote terminal tab, so a pane whose
    /// connection ended can be reopened under the SAME pane identity instead of being
    /// replaced by a second, unrelated connection sitting in the same tab.
    private var remotePaneKeys: [UUID: String] = [:]
    /// What a restored remote pane says about its connection, keyed by pane key. Set
    /// at adoption (the only moment that knows whether the keeper answered), read when
    /// a tab binds to the pane — which happens later, and in a view update.
    private var endedPaneNotes: [String: String] = [:]
    /// Bumped when a tab's PTY is replaced under it (a reconnect). The terminal
    /// surface binds its session at construction, so the identity has to change for
    /// the new PTY to be shown — and it *should* change: a reconnect is a different
    /// channel to the same pane, not the old one resumed.
    @Published private(set) var paneGeneration: [UUID: Int] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard
    /// Pre-T8 sidebar list. Imported once into the registry, then deleted.
    private let legacyWorkspacesKey = "orchard.workspaces"
    private var repoObserveTask: Task<Void, Never>?
    private var portObserveTask: Task<Void, Never>?
    private var hostLivenessObserveTask: Task<Void, Never>?
    private var statusListenTasks: [UUID: Task<Void, Never>] = [:]
    private var notificationsAuthorized = false

    struct PendingDeletion: Identifiable {
        let id: UUID
        let projectID: UUID
        let record: WorktreeRecord
    }

    /// Which existing pane the floating terminal is showing. The window never
    /// owns a PTY of its own.
    struct FloatingTerminalTarget: Equatable {
        let tabID: UUID
        let key: WorkbenchKey
        let title: String
    }

    init(settings: OrchardSettings, meta: WorkspaceMetaStore? = nil) {
        self.settings = settings
        let dataDirectory = OrchardRuntimeHost.defaultDataDirectory()
        // The factory injects ORCHARD_* into service-created PTYs; supervisor-spawned
        // PTYs get the same identity via attach().
        // T35: workers are told an absolute CLI path (the `orchard` binary shipped
        // beside this app or installed on PATH), never a bare `orchard` their login
        // shell cannot resolve.
        let cliCommand = OrchardCLIPath.resolve()
        let factory = DamsonTerminalFactory.make(
            template: settings.terminalConfig(),
            context: TerminalHostContext(cliCommand: cliCommand, dataPath: dataDirectory.path))
        let runtime = try? OrchardRuntimeHost(terminalFactory: factory, cliCommand: cliCommand)
        self.runtime = runtime
        self.browser = runtime.map { BrowserManager(service: $0.browserService) }
        let dataStore = runtime?.dataStore
            ?? OrchardDataStore(url: dataDirectory.appendingPathComponent("orchard-data.json"))
        self.workspaceService = runtime?.workspaceService ?? WorkspaceService(store: dataStore)
        self.meta = meta ?? WorkspaceMetaStore(store: dataStore)
        if let runtime {
            do {
                _ = try runtime.startSocketServer()
            } catch {
                NSLog("orchard: control-plane socket failed to start: %@", String(describing: error))
            }
        }
        settings.onTerminalConfigChange = { [weak self] in
            self?.applyTerminalConfigToAll()
        }
        settings.onSubsystemSettingsChange = { [weak self] in
            self?.applyLiveSubsystemSettings()
        }
        applyLiveSubsystemSettings()
        self.meta.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        requestNotificationPermission()
    }

    var selectedProject: ProjectSession? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedRecord: WorktreeRecord? {
        guard case let .worktree(id) = selection else { return nil }
        for project in projects {
            if let record = project.record(id: id) { return record }
        }
        return nil
    }

    var canCreateWorktree: Bool {
        guard let project = selectedProject, !project.isRemote else { return false }
        return project.worktrees.isGitRepository
    }

    /// Why the New Worktree control is disabled, or nil when it is available.
    var newWorktreeUnavailableReason: String? {
        if let project = selectedProject, project.isRemote {
            return RemoteWorkspacePolicy.unsupportedExplanation(.composer, hostId: project.hostId)
        }
        return selectedProject?.worktrees.worktreeUnavailableReason
    }

    var visibleProjects: [ProjectSession] {
        if let filterProjectID {
            return projects.filter { $0.id == filterProjectID }
        }
        return projects
    }

    func visibleRecords(in project: ProjectSession) -> [WorktreeRecord] {
        var cards = project.records
        if !showArchived {
            cards = cards.filter { !meta.isArchived(for: $0.id) }
        }
        if let filterStatusID {
            cards = cards.filter { meta.statusID(for: $0.id) == filterStatusID }
        }
        switch ordering {
        case .manual:
            cards.sort { meta.sortOrder(for: $0.id) < meta.sortOrder(for: $1.id) }
        case .recent:
            cards.sort { meta.lastActivity(for: $0.id) > meta.lastActivity(for: $1.id) }
        }
        return cards
    }

    /// Flattened visible cards grouped by board column (empty lanes omitted).
    var visibleStatusGroups: [WorkspaceStatusGroup<SidebarWorktreeCard>] {
        let cards = visibleProjects.flatMap { project in
            visibleRecords(in: project).map { SidebarWorktreeCard(project: project, record: $0) }
        }
        return WorkspaceStatusGrouping.groups(cards, vocabulary: statusVocabulary) {
            meta.statusID(for: $0.record.id)
        }
    }

    func project(owning record: WorktreeRecord) -> ProjectSession? {
        projects.first { $0.record(id: record.id) != nil }
    }

    func project(containingAgent id: UUID) -> ProjectSession? {
        projects.first { $0.agents.agents.contains { $0.id == id } }
    }

    // MARK: - Selection

    func select(_ record: WorktreeRecord, in project: ProjectSession) {
        selectedProjectID = project.id
        selection = .worktree(record.id)
        applyUnread(.focusedWorkspace(record.id))
        meta.touch(record.id)
        ensureLayout(for: .worktree(record.id))
        if project.isRemote {
            // Opening a remote worktree attaches its ssh pane. Local git status
            // must not run against the remote path.
            refreshRemoteListing(project)
            return
        }
        Task { await record.refresh() }
    }

    func selectProjectRoot(_ project: ProjectSession) {
        selectedProjectID = project.id
        selection = .projectRoot(project.id)
        ensureLayout(for: .projectRoot(project.id))
        if project.isRemote {
            refreshRemoteListing(project)
            return
        }
        Task { await project.refreshCheckout() }
    }

    private func refreshRemoteListing(_ project: ProjectSession) {
        guard let repoID = project.repoID,
              let repo = workspaceService.repo(id: repoID) else { return }
        hydrateRemoteWorktrees(project, repo: repo, refresh: true)
    }

    func focus(agentID: UUID) {
        guard let project = project(containingAgent: agentID),
              let agent = project.agents.agents.first(where: { $0.id == agentID })
        else { return }
        applyUnread(.focusedAgent(agentID))
        if let worktreeID = agent.worktree?.id, let record = project.record(id: worktreeID) {
            select(record, in: project)
            bindAgentTab(agent, key: .worktree(worktreeID))
        } else {
            selectProjectRoot(project)
            bindAgentTab(agent, key: .projectRoot(project.id))
        }
        focusMainWindow?()
    }

    /// Whether this app currently hosts a pane for `handle` (live registry or
    /// a supervisor-bound agent). Jump-to-terminal is offered only then.
    func workerPaneExists(handle: String) -> Bool {
        if resolvedWorkerHandle(handle) != nil { return true }
        return agentMatching(handle: handle) != nil
    }

    /// Whether a workspace identity is currently projected in the sidebar.
    func workspaceIdentityExists(_ identity: String) -> Bool {
        for project in projects {
            if let repoID = project.repoID,
               "\(repoID)::\(project.repo.path)" == identity {
                return true
            }
            for record in project.records {
                if workspaceIdentity(for: record, in: project) == identity { return true }
            }
        }
        return false
    }

    /// Focus a workspace by runtime identity (`repoId::path`). Returns false
    /// when that checkout is no longer open in this app.
    @discardableResult
    func focusWorkspaceIdentity(_ identity: String) -> Bool {
        guard selectWorkspace(identity: identity) else { return false }
        focusMainWindow?()
        return true
    }

    /// Focus the live worker pane when it exists in this app. Returns false
    /// when the handle is not a pane we can show — never invents a terminal.
    @discardableResult
    func focusWorkerTerminal(handle: String) -> Bool {
        if let agent = agentMatching(handle: handle) {
            focus(agentID: agent.id)
            return true
        }
        guard let resolved = resolvedWorkerHandle(handle),
              let summary = try? runtime?.terminalService.summary(handle: resolved),
              let worktreeId = summary.worktreeId,
              selectWorkspace(identity: worktreeId) else {
            return false
        }
        focusMainWindow?()
        return true
    }

    private func resolvedWorkerHandle(_ handle: String) -> String? {
        guard let service = runtime?.terminalService else { return nil }
        do {
            _ = try service.summary(handle: handle)
            return handle
        } catch TerminalServiceError.handleStale(_, let replacement) {
            return replacement
        } catch {
            return nil
        }
    }

    private func agentMatching(handle: String) -> AgentSession? {
        let resolved = resolvedWorkerHandle(handle)
        for project in projects {
            for agent in project.agents.agents {
                if agent.terminalHandle == handle { return agent }
                if let resolved, agent.terminalHandle == resolved { return agent }
                if let paneKey = agent.paneKey,
                   runtime?.terminalService.liveHandle(forPaneKey: paneKey) == handle
                    || runtime?.terminalService.liveHandle(forPaneKey: paneKey) == resolved {
                    return agent
                }
            }
        }
        return nil
    }

    @discardableResult
    private func selectWorkspace(identity: String) -> Bool {
        for project in projects {
            if let repoID = project.repoID,
               "\(repoID)::\(project.repo.path)" == identity {
                selectProjectRoot(project)
                return true
            }
            for record in project.records {
                if workspaceIdentity(for: record, in: project) == identity {
                    select(record, in: project)
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Live status (observation-only)

    /// Four defaults plus any custom columns stored in orchard-data.json.
    var statusVocabulary: [WorkspaceStatusDefinition] {
        workspaceService.statusVocabulary()
    }

    func statusAppearance(for recordID: UUID) -> WorkspaceStatusAppearance {
        WorkspaceStatusAppearance.resolve(id: meta.statusID(for: recordID),
                                          vocabulary: statusVocabulary)
    }

    func setWorkspaceStatus(_ statusID: String, for recordID: UUID) {
        meta.setStatusID(statusID, for: recordID)
    }

    func addWorkspaceStatus(label: String, color: String, icon: String = "flag") throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.slugStatusID(trimmed)
        try workspaceService.addStatusDefinition(
            WorkspaceStatusDefinition(id: slug, label: trimmed, color: color, icon: icon))
        objectWillChange.send()
    }

    func isUnread(workspace id: UUID) -> Bool { unread.isUnread(workspace: id) }

    func isUnread(agent id: UUID) -> Bool { unread.isUnread(agent: id) }

    func setArchived(_ archived: Bool, for record: WorktreeRecord, in project: ProjectSession) {
        meta.setArchived(archived, for: record.id)
        if archived, !showArchived, case .worktree(let id) = selection, id == record.id {
            selection = defaultSelection(for: project)
        }
    }

    /// UI-free kanban board for the agent dashboard. Caps each bucket so a huge
    /// fleet cannot blank the popout (inventory §6).
    func dashboardBoard() -> DashboardBoard {
        var inputs: [DashboardCardInput] = []
        for project in projects {
            for agent in project.agents.agents {
                inputs.append(dashboardInput(for: agent, in: project))
            }
        }
        return DashboardProjection.board(from: inputs)
    }

    /// Status-bar workspace chip: selected worktree title + branch, or the
    /// project checkout name + `rootSubtitle` (branch / folder / remote).
    var statusBarWorkspace: (name: String?, branch: String?) {
        switch selection {
        case .worktree:
            guard let record = selectedRecord else { return (nil, nil) }
            return (record.title, record.branch)
        case .projectRoot(let id):
            guard let project = projects.first(where: { $0.id == id }) else { return (nil, nil) }
            return (project.name, project.rootSubtitle)
        case nil:
            return (nil, nil)
        }
    }

    /// Live agent counts by T67 dashboard bucket. Reads `dashboardBoard()`; does
    /// not re-bucket.
    func statusBarBucketCounts() -> [StatusBarBucketCount] {
        let board = dashboardBoard()
        return DashboardBucket.allCases.map { bucket in
            let glyph: DashboardDotState
            switch bucket {
            case .attention: glyph = .blocked
            case .working: glyph = .working
            case .done: glyph = .done
            case .idle: glyph = .idle
            }
            return StatusBarBucketCount(
                id: bucket.rawValue,
                glyph: DashboardProjection.glyph(for: glyph),
                count: board.total(in: bucket))
        }
    }

    func dashboardInput(for agent: AgentSession, in project: ProjectSession) -> DashboardCardInput {
        let snapshot = agentStatusByID[agent.id]
        let paneKey = snapshot?.paneKey ?? agent.paneKey ?? "agent:\(agent.id.uuidString)"
        let parsed = DashboardProjection.parsePaneKey(paneKey)
        let worktree = agent.worktree.flatMap { project.record(id: $0.id) }
        let status = worktree.map { statusAppearance(for: $0.id) }
        let finishedAtMs = agent.task?.finishedAt.map { $0.timeIntervalSince1970 * 1000 }
        return DashboardCardInput(
            paneKey: paneKey,
            agentType: agentTypeName(for: agent),
            snapshot: snapshot,
            runtime: agent.state,
            unseen: unread.isUnread(agent: agent.id),
            taskTitle: agent.task.flatMap { $0.title.isEmpty ? nil : $0.title },
            taskPrompt: agent.task.flatMap { $0.prompt.isEmpty ? nil : $0.prompt },
            parentPaneKey: nil,
            workspaceName: workspaceName(for: agent, in: project),
            workspaceStatusId: status?.id,
            workspaceStatusLabel: status?.label,
            repoId: project.repoID,
            worktreeId: snapshot?.worktreeId
                ?? worktree.flatMap { workspaceIdentity(for: $0, in: project) },
            tabId: parsed?.tabId,
            leafId: parsed?.leafId,
            agentID: agent.id,
            startedAtMs: agent.startedAt.timeIntervalSince1970 * 1000,
            finishedAtMs: finishedAtMs,
            interactivePrompt: snapshot?.interactivePrompt)
    }

    func focus(dashboardCard card: DashboardCard) {
        focus(agentID: card.focus.agentID)
    }

    func dashboardBucket(for agent: AgentSession) -> DashboardBucket {
        let unseen = unread.isUnread(agent: agent.id)
        if let snapshot = agentStatusByID[agent.id] {
            return DashboardProjection.bucket(snapshot: snapshot, unseen: unseen)
        }
        return DashboardProjection.bucket(runtime: agent.state, unseen: unseen)
    }

    func displayDotState(for agent: AgentSession) -> DashboardDotState {
        let unseen = unread.isUnread(agent: agent.id)
        let dot = agentStatusByID[agent.id].map(DashboardProjection.dotState(from:))
            ?? DashboardProjection.dotState(runtime: agent.state)
        return DashboardProjection.displayState(dotState: dot, unseen: unseen)
    }

    func stateStartedAt(for agent: AgentSession) -> Date {
        if let snapshot = agentStatusByID[agent.id] {
            return Date(timeIntervalSince1970: snapshot.stateStartedAt / 1000)
        }
        return agent.startedAt
    }

    func detailLine(for agent: AgentSession) -> String? {
        if let snapshot = agentStatusByID[agent.id] {
            return DashboardProjection.detailLine(
                prompt: snapshot.prompt,
                lastAssistant: snapshot.lastAssistantMessage
                    ?? snapshot.lastCompletedAssistantMessage)
        }
        return agent.task.flatMap { $0.prompt.isEmpty ? nil : $0.prompt }
    }

    func workspaceName(for agent: AgentSession, in project: ProjectSession) -> String {
        if let worktreeID = agent.worktree?.id, let record = project.record(id: worktreeID) {
            return record.title
        }
        return project.name
    }

    func agentTypeName(for agent: AgentSession) -> String {
        if let type = agentStatusByID[agent.id]?.agentType, !type.isEmpty {
            return type
        }
        return agent.engine.displayName
    }

    private func attachStatusStream(for agent: AgentSession) {
        guard let service = runtime?.terminalService else { return }
        let handle: String
        if let paneKey = agent.paneKey, let live = service.liveHandle(forPaneKey: paneKey) {
            handle = live
        } else if let spawned = agent.terminalHandle {
            handle = spawned
        } else {
            return
        }
        statusListenTasks[agent.id]?.cancel()
        let agentID = agent.id
        statusListenTasks[agentID] = Task { [weak self] in
            do {
                let stream = try service.agentStatusUpdates(handle: handle)
                for await snapshot in stream {
                    guard !Task.isCancelled else { break }
                    self?.agentStatusByID[agentID] = snapshot
                    self?.objectWillChange.send()
                }
            } catch {
                // Observation-only: a missing handle is not a dashboard error.
            }
        }
    }

    private func detachStatusStream(_ agentID: UUID) {
        statusListenTasks[agentID]?.cancel()
        statusListenTasks[agentID] = nil
        agentStatusByID[agentID] = nil
        applyUnread(.agentRetired(agentID))
    }

    private func applyUnread(_ event: UnreadEvent) {
        unread = UnreadReducer.reduce(unread, event)
    }

    /// Ports interval and the automations master switch are live: the services
    /// already expose setters / start-stop, so the app writes them on every change.
    func applyLiveSubsystemSettings() {
        guard let runtime else { return }
        runtime.portService.setInterval(PortService.clamp(settings.portsSweepInterval))
        if settings.automationsEnabled {
            runtime.automationScheduler.start()
        } else {
            runtime.automationScheduler.stop()
        }
    }

    /// Jump-palette file activation. Default is the editor; pass `.diff` when
    /// the caller held Option (documented on `JumpPalette.activateFile`).
    func openPaletteFile(_ relativePath: String, in record: WorktreeRecord, project: ProjectSession,
                         mode: FileOpenRequest.Mode = .edit) {
        if project.isRemote { return }
        select(record, in: project)
        pendingOpenPath = relativePath
        if mode == .diff {
            selectKind(.diff)
        } else {
            openEditor(relativePath)
        }
        runtime?.fileOpenCenter.post(FileOpenRequest(
            worktreeId: workspaceIdentity(for: record, in: project) ?? "",
            worktreePath: record.path.path,
            relativePath: relativePath,
            mode: mode))
    }

    func runPaletteCommand(_ command: PaletteCommand) {
        switch command {
        case .openDashboard:
            showDashboard?()
        case .openOrchestration:
            showOrchestration?()
        case .openAutomations:
            showAutomations?()
        case .openVault:
            showVault?()
        case .showTerminal:
            focusMainWindow?()
            selectKind(.terminal)
        case .showDiff:
            focusMainWindow?()
            selectKind(.diff)
        case .showEditor:
            focusMainWindow?()
            selectKind(.editor)
        case .showBrowser:
            focusMainWindow?()
            selectKind(.browser)
        case .refreshDiff:
            if let key = selection { Task { await refreshGit(for: key) } }
        case .newWorktree:
            requestNewWorktree()
        case .toggleChat:
            toggleFocusedViewMode()
        case .settings:
            showSettings?()
        }
    }

    func openBrowserTab(workspaceKey: String) {
        if let key = selection, unsupportedReason(RemoteAffordance.browser, for: key) != nil { return }
        Task {
            await applyDefaultBrowserProfile(workspaceKey: workspaceKey)
            _ = try? await browser?.service.createTab(workspace: workspaceKey)
        }
    }

    func applyDefaultBrowserProfile(workspaceKey: String) async {
        guard let service = runtime?.browserService else { return }
        let wanted = settings.defaultBrowserProfileID.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, wanted != BrowserProfile.defaultProfile.id else { return }
        let bound = await service.boundProfile(workspace: workspaceKey)
        if bound.profile.id == BrowserProfile.defaultProfile.id {
            _ = try? await service.bindProfile(workspace: workspaceKey, profile: wanted)
        }
    }

    private static func slugStatusID(_ label: String) -> String {
        let slug = label.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "status" : slug
    }

    // MARK: - Projects

    func restore() {
        migrateLegacyWorkspacesIfNeeded()
        applyRegistry(workspaceService.listRepos(), selectNewProjects: true)
        observeRepoRegistry()
        observePorts()
        observeHostLiveness()
    }

    func ports(for record: WorktreeRecord, in project: ProjectSession) -> [WorkspaceListeningPort] {
        guard let id = workspaceIdentity(for: record, in: project) else { return [] }
        return portSnapshot.ports(forWorktreeId: id)
    }

    func workspaceIdentity(for record: WorktreeRecord, in project: ProjectSession) -> String? {
        project.repoID.map { record.worktree.workspaceId(repoId: $0) }
    }

    func addProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a git repository to orchestrate agents in."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(repo: url)
    }

    /// Register a remote checkout through the same `addRemoteRepo` path the CLI
    /// uses. Probe failures throw `WorkspaceError` so the sheet can show them
    /// in verdict language.
    func addRemoteProject(host: HostRecord, path: String) async throws {
        guard let hostId = host.executionHostId else {
            throw WorkspaceError("unknown_host", "no registered host named '\(host.name)'")
        }
        let record = try await workspaceService.addRemoteRepo(path: path, host: hostId)
        applyRegistry(workspaceService.listRepos(), selectNewProjects: true)
        if let project = projects.first(where: { $0.repoID == record.id }) {
            selectedProjectID = project.id
            selection = defaultSelection(for: project)
        }
    }

    func addProject(repo: URL, silent: Bool = false) {
        if let existing = project(at: repo) {
            selectedProjectID = existing.id
            selection = defaultSelection(for: existing)
            return
        }
        do {
            let record = try workspaceService.addRepo(path: repo)
            if let existing = project(at: repo) {
                existing.repoID = record.id
                selectedProjectID = existing.id
                selection = defaultSelection(for: existing)
                return
            }
            if let project = openProject(repo: repo, record: record, silent: silent) {
                selectedProjectID = project.id
                selection = defaultSelection(for: project)
            }
        } catch {
            guard !silent else { return }
            presentOpenFailure(error)
        }
    }

    func removeProject(_ project: ProjectSession) {
        let selector = project.repoID ?? project.repo.path
        detachProject(project)
        _ = try? workspaceService.removeRepo(selector)
    }

    private func defaultSelection(for project: ProjectSession) -> WorkbenchKey {
        if let last = project.records.last { return .worktree(last.id) }
        return .projectRoot(project.id)
    }

    /// One-time import of the pre-T8 UserDefaults path list into the registry.
    /// The key is then deleted so it cannot fight `orchard-data.json` later.
    private func migrateLegacyWorkspacesIfNeeded() {
        guard let paths = defaults.stringArray(forKey: legacyWorkspacesKey) else { return }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard Self.isExistingDirectory(url) else { continue }
            _ = try? workspaceService.addRepo(path: url)
        }
        defaults.removeObject(forKey: legacyWorkspacesKey)
    }

    private func observeRepoRegistry() {
        repoObserveTask?.cancel()
        let stream = workspaceService.repoChanges()
        repoObserveTask = Task { [weak self] in
            for await repos in stream {
                guard !Task.isCancelled else { break }
                self?.applyRegistry(repos, selectNewProjects: false)
            }
        }
    }

    private func observePorts() {
        portObserveTask?.cancel()
        guard let service = runtime?.portService else { return }
        portSnapshot = service.snapshot()
        portObserveTask = Task { [weak self] in
            for await snapshot in service.snapshots() {
                guard !Task.isCancelled else { break }
                self?.portSnapshot = snapshot
            }
        }
    }

    private func observeHostLiveness() {
        hostLivenessObserveTask?.cancel()
        guard let service = runtime?.hostLiveness else { return }
        hostLiveness = service.snapshot()
        hostLivenessObserveTask = Task { [weak self] in
            for await snapshot in service.snapshots() {
                guard !Task.isCancelled else { break }
                self?.hostLiveness = snapshot
            }
        }
    }

    /// Freshness for Open Remote: run a sweep if the producer is awake, and
    /// one-shot any registered host the snapshot does not yet cover. Publishing
    /// into the liveness service only — never a workspace or worker mutation.
    func refreshHostLiveness() async {
        guard let service = runtime?.hostLiveness else { return }
        let snapshot = await service.sweep()
        let known = Set(snapshot.hosts.keys)
        // Idle (no remote repo/pane): one-shot every registered host so the
        // picker is not blank. Awake: fill in unused registered hosts only.
        let missing = registeredHosts.filter { snapshot.idle || !known.contains($0.name) }
        for host in missing {
            service.publish(await HostProbe.check(host: host))
        }
        hostLiveness = service.snapshot()
    }

    /// Bring `projects` in line with the registry. Missing *local* directories
    /// are skipped (a `ProjectSession` cannot start). Remote repos have no
    /// local directory and are opened from the last-known worktree set.
    /// Newly added repos from the CLI appear here; Open Project creates the
    /// session itself and dedups.
    private func applyRegistry(_ repos: [RepoRecord], selectNewProjects: Bool) {
        var wanted: [String: RepoRecord] = [:]
        for record in repos {
            wanted[Self.registryKey(for: record)] = record
        }
        for project in projects where wanted[Self.registryKey(for: project)] == nil {
            detachProject(project)
        }
        var opened: [ProjectSession] = []
        for record in repos {
            if let existing = project(matching: record) {
                existing.repoID = record.id
                if existing.isRemote {
                    hydrateRemoteWorktrees(existing, repo: record, refresh: false)
                }
                continue
            }
            let url = URL(fileURLWithPath: record.path)
            if !RemoteWorkspacePolicy.isRemote(hostId: record.hostId) {
                guard Self.isExistingDirectory(url) else { continue }
            }
            if let project = openProject(repo: url, record: record, silent: true) {
                opened.append(project)
            }
        }
        if selectNewProjects, let last = opened.last {
            selectedProjectID = last.id
            selection = defaultSelection(for: last)
        } else if selectedProjectID == nil, let last = projects.last {
            selectedProjectID = last.id
            selection = defaultSelection(for: last)
        }
    }

    @discardableResult
    private func openProject(repo: URL, record: RepoRecord, silent: Bool) -> ProjectSession? {
        do {
            let project = try ProjectSession(
                repo: repo, settings: settings, repoID: record.id,
                displayName: record.displayName,
                preferredHookPort: keeperHookPortHints[repo.standardizedFileURL.path],
                hostId: record.hostId)
            project.onEvent = { [weak self] project, event in
                self?.handle(event, from: project)
            }
            if let runtime {
                // Supervisor PTYs get ORCHARD_* identity and land in the
                // terminal registry so worktree meta keys use `<repoId>::<path>`.
                runtime.attach(project.agents)
            }
            if project.isRemote {
                hydrateRemoteWorktrees(project, repo: record, refresh: true)
            }
            for worktree in project.records {
                registerMetaKey(worktree, in: project)
                _ = meta.ensure(worktree.id)
            }
            projects.append(project)
            for agent in project.agents.agents {
                attachStatusStream(for: agent)
            }
            return project
        } catch {
            guard !silent else { return nil }
            presentOpenFailure(error)
            return nil
        }
    }

    private func detachProject(_ project: ProjectSession) {
        guard projects.contains(where: { $0.id == project.id }) else { return }
        for agent in project.agents.agents {
            detachStatusStream(agent.id)
        }
        project.shutdown()
        dropWorkbench(for: project)
        projects.removeAll { $0.id == project.id }
        if filterProjectID == project.id { filterProjectID = nil }
        if composerProjectID == project.id { composerProjectID = nil }
        if selectedProjectID == project.id {
            selectedProjectID = projects.first?.id
            selection = projects.first.map(defaultSelection(for:))
        }
    }

    private func project(at url: URL) -> ProjectSession? {
        let path = url.standardizedFileURL.path
        return projects.first {
            !$0.isRemote && $0.repo.standardizedFileURL.path == path
        }
    }

    private func project(matching record: RepoRecord) -> ProjectSession? {
        if let byID = projects.first(where: { $0.repoID == record.id }) {
            return byID
        }
        if RemoteWorkspacePolicy.isRemote(hostId: record.hostId) {
            return projects.first {
                $0.isRemote && $0.hostId == record.hostId && $0.repo.path == record.path
            }
        }
        return project(at: URL(fileURLWithPath: record.path))
    }

    /// Last-known remote worktrees (and an optional live refresh). A failed
    /// refresh leaves the stored set intact — an unreachable host is not an
    /// empty sidebar.
    private func hydrateRemoteWorktrees(_ project: ProjectSession, repo: RepoRecord,
                                        refresh: Bool) {
        let apply: () -> Void = { [weak self, weak project] in
            guard let self, let project else { return }
            let data = self.workspaceService.store.load()
            project.applyRemoteWorkspaces(
                self.workspaceService.storedRemoteWorkspaces(for: repo, data: data),
                repo: repo)
            for worktree in project.records {
                self.registerMetaKey(worktree, in: project)
                _ = self.meta.ensure(worktree.id)
            }
        }
        apply()
        guard refresh else { return }
        Task { [weak self] in
            do {
                _ = try await self?.workspaceService.refreshRemoteWorktrees(repo: repo)
            } catch {
                // Loss of contact is not evidence the worktrees stopped.
            }
            apply()
        }
    }

    private static func registryKey(for record: RepoRecord) -> String {
        if RemoteWorkspacePolicy.isRemote(hostId: record.hostId) {
            return "\(record.hostId)|\(record.path)"
        }
        return standardizedPath(record.path)
    }

    private static func registryKey(for project: ProjectSession) -> String {
        if project.isRemote {
            return "\(project.hostId)|\(project.repo.path)"
        }
        return project.repo.standardizedFileURL.path
    }

    private func presentOpenFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open project"
        alert.informativeText = String(describing: error)
        alert.runModal()
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func shutdownAll() {
        repoObserveTask?.cancel()
        repoObserveTask = nil
        portObserveTask?.cancel()
        portObserveTask = nil
        hostLivenessObserveTask?.cancel()
        hostLivenessObserveTask = nil
        for task in statusListenTasks.values { task.cancel() }
        statusListenTasks.removeAll()
        agentStatusByID.removeAll()
        for project in projects { project.shutdown() }
        for session in shells.values { session.terminate() }
        shells.removeAll()
        runtime?.shutdown()
    }

    /// Bind a record's meta to its worktree id once the owning repo is registered.
    private func registerMetaKey(_ record: WorktreeRecord, in project: ProjectSession) {
        guard let repoID = project.repoID else { return }
        meta.register(record.id, key: record.worktree.workspaceId(repoId: repoID))
    }

    /// The RPC-facing worktree identity for a record (`ORCHARD_WORKTREE_ID`).
    private func workspaceID(for record: WorktreeRecord, in project: ProjectSession) -> String? {
        workspaceIdentity(for: record, in: project)
    }

    // MARK: - Composer / delete

    func requestNewWorktree() {
        guard let project = selectedProject else {
            addProjectViaPanel()
            return
        }
        guard !project.isRemote else { return }
        guard project.worktrees.isGitRepository else { return }
        composerProjectID = project.id
    }

    func presentOpenRemote() {
        isOpenRemotePresented = true
    }

    func compose(project: ProjectSession, name: String, prompt: String,
                 engineID: String, baseRef: String?, count: Int,
                 workspaceStatus: String = WorkspaceStatus.inProgress.rawValue) throws {
        if project.isRemote {
            throw GitError(RemoteWorkspacePolicy.unsupportedExplanation(
                .composer, hostId: project.hostId)
                ?? "agents cannot run on a remote host yet")
        }
        if let error = ComposerPlanning.validationError(name: name, count: count) {
            throw GitError(error)
        }
        guard AgentEngineRegistry.engine(id: engineID) != nil else {
            throw GitError("engine '\(engineID)' isn't registered in this build.")
        }
        // Plan names up front so cards get `-2`/`-3` titles, then spawn every
        // agent immediately — v2 has no scheduler, so fan-out is just N creates.
        let names = ComposerPlanning.fanOutNames(
            name: name, count: count, taken: project.worktrees.takenNames)
        var first: WorktreeRecord?
        for leaf in names {
            let record = try project.worktrees.createWorktree(
                name: leaf, baseRef: baseRef, title: leaf)
            project.worktrees.runSetupScriptIfEnabled(for: record)
            registerMetaKey(record, in: project)
            _ = meta.ensure(record.id)
            meta.setStatusID(workspaceStatus, for: record.id)
            let size = paneSpawnSize()
            let agent = try project.agents.spawnAgent(
                engineID: engineID, prompt: prompt, in: record.worktree, title: leaf,
                workspaceID: workspaceID(for: record, in: project),
                initialCols: size.cols, initialRows: size.rows)
            record.agentState = agent.state
            record.lastPrompt = prompt.isEmpty ? nil : prompt
            bindAgentTab(agent, key: .worktree(record.id))
            if first == nil { first = record }
        }
        project.syncRecords()
        if let first { select(first, in: project) }
    }

    /// Spawn into an existing worktree (agent-first). Prompt is optional — an
    /// empty string leaves the engine waiting at its input box, matching ⌘N
    /// with a blank prompt. Used by the card start/restart row.
    func startAgent(in record: WorktreeRecord, project: ProjectSession,
                    engineID: String, prompt: String? = nil) throws {
        if project.isRemote {
            throw GitError(RemoteWorkspacePolicy.unsupportedExplanation(
                .agents, hostId: project.hostId)
                ?? "agents cannot run on a remote host yet")
        }
        guard AgentEngineRegistry.engine(id: engineID) != nil else {
            throw GitError("engine '\(engineID)' isn't registered in this build.")
        }
        for agent in project.liveAgents(in: record.id) where agent.state.isTerminal {
            project.agents.retire(agent)
        }
        let delivered = prompt ?? record.lastPrompt ?? ""
        let size = paneSpawnSize()
        let agent = try project.agents.spawnAgent(
            engineID: engineID,
            prompt: delivered,
            in: record.worktree,
            title: record.title,
            workspaceID: workspaceID(for: record, in: project),
            initialCols: size.cols, initialRows: size.rows)
        record.agentState = agent.state
        if !delivered.isEmpty { record.lastPrompt = delivered }
        bindAgentTab(agent, key: .worktree(record.id))
        select(record, in: project)
    }

    func requestDelete(_ record: WorktreeRecord, in project: ProjectSession) {
        guard !project.isRemote else { return }
        pendingDeletion = PendingDeletion(id: record.id, projectID: project.id, record: record)
    }

    func deleteWorktree(_ record: WorktreeRecord, in project: ProjectSession,
                        force: Bool, deleteBranch: Bool, forceBranch: Bool = false)
                        throws -> WorktreeService.DeletionResult {
        if project.isRemote {
            throw GitError("remote worktrees are removed through the orchard CLI")
        }
        project.agents.retireAgents(inWorktree: record.id)
        // Same runtime path as `orchard worktree rm --delete-branch` / `--force-branch`:
        // WorktreeService → WorktreeManager.remove. The checkbox is not a parallel
        // delete; it is the same flag the CLI sends.
        let deletion = try project.worktrees.deleteWorktree(
            record, force: force, deleteBranch: deleteBranch, forceBranch: forceBranch)
        guard deletion.removed else { return deletion }
        meta.remove(record.id)
        layouts[.worktree(record.id)] = nil
        if case .worktree(let id) = selection, id == record.id {
            selection = defaultSelection(for: project)
        }
        project.syncRecords()
        return deletion
    }

    // MARK: - Workbench

    func layout(for key: WorkbenchKey) -> SplitNode {
        // Pure read: mutating @Published state during view rendering makes
        // SwiftUI drop updates (selection, add-tab, and split all went dead).
        // Stored layouts are created when the selection changes, never here.
        if let existing = layouts[key] { return existing }
        let hostId = executionHostId(for: key)
        let remote = RemoteWorkspacePolicy.isRemote(hostId: hostId)
        return SplitNode.makeDefault(
            executionHostId: remote ? hostId : nil,
            includeLocalOnlyTabs: !remote)
    }

    @discardableResult
    func ensureLayout(for key: WorkbenchKey) -> SplitNode {
        if let existing = layouts[key] { return existing }
        let hostId = executionHostId(for: key)
        let remote = RemoteWorkspacePolicy.isRemote(hostId: hostId)
        let node = SplitNode.makeDefault(
            executionHostId: remote ? hostId : nil,
            includeLocalOnlyTabs: !remote)
        layouts[key] = node
        focusedGroupID = node.firstGroupID()
        return node
    }

    /// Execution host stamped on the workspace this workbench is showing.
    func executionHostId(for key: WorkbenchKey) -> String? {
        switch key {
        case .projectRoot(let id):
            return projects.first { $0.id == id }?.hostId
        case .worktree(let id):
            for project in projects {
                if project.record(id: id) != nil { return project.hostId }
            }
            return nil
        }
    }

    func isRemote(_ key: WorkbenchKey) -> Bool {
        RemoteWorkspacePolicy.isRemote(hostId: executionHostId(for: key))
    }

    func unsupportedReason(_ affordance: RemoteAffordance, for key: WorkbenchKey?) -> String? {
        guard let key else { return nil }
        return RemoteWorkspacePolicy.unsupportedExplanation(
            affordance, hostId: executionHostId(for: key))
    }

    func unsupportedReason(_ kind: TabKind, for key: WorkbenchKey?) -> String? {
        guard let affordance = kind.remoteAffordance else { return nil }
        return unsupportedReason(affordance, for: key)
    }

    // MARK: - Conflict review (T68)

    /// Last known conflict state per workbench. Cached rather than recomputed on every
    /// view update: each summary is two git subprocesses, and the tab strip reads it on
    /// every redraw.
    @Published private(set) var conflictSummaries: [WorkbenchKey: GitConflictSummary] = [:]
    /// Conflict tabs Orchard opened on its own. Tracked so it can take back exactly those
    /// and no others — a tab the user opened is the user's to close.
    private var autoConflictTabs: [WorkbenchKey: UUID] = [:]
    private let conflictService = GitConflictService()

    func conflictSummary(for key: WorkbenchKey?) -> GitConflictSummary {
        guard let key else { return .none }
        return conflictSummaries[key] ?? .none
    }

    /// Re-read the worktree's unmerged state and open (or retract) its conflict tab.
    /// Git runs off the main actor — a conflicted repo is exactly when the user is
    /// clicking around, and a stuttering tab strip is the last thing that helps.
    func refreshConflicts(for key: WorkbenchKey) async {
        guard !isRemote(key), let root = workspaceRoot(for: key) else {
            conflictSummaries[key] = .none
            return
        }
        let service = conflictService
        let summary = await Task.detached(priority: .utility) {
            service.summary(worktree: root)
        }.value
        conflictSummaries[key] = summary
        syncConflictTab(for: key, summary: summary)
    }

    /// A worktree that is mid-merge grows a conflict tab without being asked — the tab is
    /// added but never selected, because stealing the pane out from under someone mid-typing
    /// is worse than a badge they have to notice. When the conflicts are gone the tab is
    /// retracted, unless it is the tab they are currently reading.
    private func syncConflictTab(for key: WorkbenchKey, summary: GitConflictSummary) {
        let existing = ensureLayout(for: key).findTab(kind: .conflicts)
        if summary.isActive {
            guard existing == nil,
                  let groupID = ensureLayout(for: key).firstGroupID() else { return }
            let tab = WorkbenchTab(kind: .conflicts)
            updateLayout(key) { node in
                _ = node.mutateGroup(groupID) { group in group.tabs.append(tab) }
            }
            autoConflictTabs[key] = tab.id
            return
        }
        guard let existing, autoConflictTabs[key] == existing.tabID,
              ensureLayout(for: key).selectedTab(in: existing.groupID)?.id != existing.tabID
        else { return }
        closeTab(existing.tabID, in: existing.groupID, key: key)
        autoConflictTabs[key] = nil
    }

    func updateLayout(_ key: WorkbenchKey, _ body: (inout SplitNode) -> Void) {
        var node = ensureLayout(for: key)
        body(&node)
        layouts[key] = node
    }

    /// The hosts a "Remote Shell" menu can offer. Empty until `orchard host add`
    /// registers one — Orchard never invents a connection target.
    var registeredHosts: [HostRecord] { runtime?.hostRegistry.list() ?? [] }

    /// Open a terminal tab whose shell runs on `host`. The PTY is local; its child is
    /// `ssh -tt <host>`, and the tab carries the execution host so its label says so.
    func addRemoteShellTab(host: HostRecord, to groupID: UUID, key: WorkbenchKey) {
        guard let hostId = host.executionHostId else { return }
        let tab = WorkbenchTab(kind: .terminal, title: host.name,
                               executionHostId: hostId.rawValue)
        updateLayout(key) { node in
            _ = node.mutateGroup(groupID) { group in
                group.tabs.append(tab)
                group.selectedID = tab.id
            }
        }
    }

    func addTab(_ kind: TabKind, to groupID: UUID, key: WorkbenchKey, agentID: UUID? = nil) {
        guard unsupportedReason(kind, for: key) == nil else { return }
        let tab = WorkbenchTab(kind: kind, agentID: agentID)
        updateLayout(key) { node in
            _ = node.mutateGroup(groupID) { group in
                group.tabs.append(tab)
                group.selectedID = tab.id
            }
        }
    }

    func selectTab(_ tabID: UUID, in groupID: UUID, key: WorkbenchKey) {
        updateLayout(key) { node in
            _ = node.mutateGroup(groupID) { group in
                group.selectedID = tabID
            }
        }
        focusedGroupID = groupID
    }

    func closeTab(_ tabID: UUID, in groupID: UUID, key: WorkbenchKey) {
        dropChat(tabID)
        if let tab = layout(for: key).tab(id: tabID), tab.kind == .editor,
           let path = tab.filePath, let root = workspaceRoot(for: key) {
            editorSessions.drop(root: root, path: path)
        }
        if let session = shells.removeValue(forKey: tabID) {
            session.terminate()
        }
        connectionNotes[tabID] = nil
        remotePaneKeys[tabID] = nil
        paneGeneration[tabID] = nil
        updateLayout(key) { node in
            _ = node.mutateGroup(groupID) { group in
                guard group.tabs.count > 1 else { return }
                group.tabs.removeAll { $0.id == tabID }
                if group.selectedID == tabID {
                    group.selectedID = group.tabs.last?.id ?? group.selectedID
                }
            }
        }
        if floatingTerminal?.tabID == tabID {
            closeFloatingTerminal()
        }
    }

    /// Bind the floating window to this pane's existing session. No-op when the
    /// tab is not a live terminal — we never spawn a PTY just to float it.
    func openFloatingTerminal(tab: WorkbenchTab, key: WorkbenchKey) {
        guard tab.kind == .terminal else { return }
        guard existingDamsonSession(for: tab) != nil else { return }
        let bound = FloatingTerminalPolicy.binding(
            current: floatingTerminal?.tabID, opening: tab.id)
        floatingTerminal = FloatingTerminalTarget(tabID: bound, key: key, title: tab.title)
        showFloatingTerminal?()
    }

    func closeFloatingTerminal(orderOut: Bool = true) {
        guard floatingTerminal != nil else { return }
        // `bindingAfterClose` is nil: drop the window binding, keep the session.
        floatingTerminal = nil
        if orderOut { hideFloatingTerminal?() }
    }

    func revealFloatingTerminal() {
        guard floatingTerminal != nil else { return }
        showFloatingTerminal?()
    }

    func floatingWorkbenchTab() -> WorkbenchTab? {
        guard let target = floatingTerminal else { return nil }
        return layout(for: target.key).tab(id: target.tabID)
    }

    /// Lookup only. Creating a session belongs to `damsonSession(for:key:cwd:)`
    /// so the floating window cannot mint a second PTY for the same pane.
    func existingDamsonSession(for tab: WorkbenchTab) -> DamsonSession? {
        if let agentID = tab.agentID {
            for project in projects {
                if let agent = project.agents.agents.first(where: { $0.id == agentID }),
                   let session = (agent.terminal as? DamsonTerminalSession)?.session {
                    return session
                }
            }
        }
        return shells[tab.id]
    }

    func split(_ groupID: UUID, key: WorkbenchKey, axis: SplitAxis) {
        updateLayout(key) { node in
            _ = node.splitGroup(groupID, axis: axis)
        }
        focusedGroupID = groupID
    }

    func splitFocused(axis: SplitAxis) {
        guard let key = selection,
              let groupID = focusedGroupID ?? ensureLayout(for: key).firstGroupID() else { return }
        updateLayout(key) { node in
            _ = node.splitGroup(groupID, axis: axis)
        }
    }

    func bindAgentTab(_ agent: AgentSession, key: WorkbenchKey) {
        var node = ensureLayout(for: key)
        var bound = false
        if let groupID = node.firstGroupID() {
            _ = node.mutateGroup(groupID) { group in
                if let index = group.tabs.firstIndex(where: { $0.agentID == agent.id }) {
                    group.selectedID = group.tabs[index].id
                    bound = true
                } else if let index = group.tabs.firstIndex(where: {
                    $0.kind == .terminal && $0.agentID == nil
                }) {
                    group.tabs[index].agentID = agent.id
                    group.tabs[index].title = agent.engine.displayName
                    group.selectedID = group.tabs[index].id
                    bound = true
                }
            }
        }
        if !bound, let groupID = node.firstGroupID() {
            let tab = WorkbenchTab(kind: .terminal, title: agent.engine.displayName, agentID: agent.id)
            _ = node.mutateGroup(groupID) { group in
                group.tabs.append(tab)
                group.selectedID = tab.id
            }
        }
        layouts[key] = node
        if let tab = node.selectedTab(in: node.firstGroupID() ?? UUID()), tab.agentID == agent.id {
            prepareChat(for: tab)
        }
        objectWillChange.send()
    }

    /// Flip an agent tab between the raw PTY and the chat overlay. Mode is stored
    /// on the tab for the app session; the PTY is not respawned.
    func toggleViewMode(_ tabID: UUID, in groupID: UUID, key: WorkbenchKey) {
        updateLayout(key) { node in
            _ = node.mutateGroup(groupID) { group in
                guard let index = group.tabs.firstIndex(where: { $0.id == tabID }),
                      group.tabs[index].isAgentTab else { return }
                group.tabs[index].viewMode = group.tabs[index].viewMode == .chat
                    ? .terminal : .chat
                group.selectedID = tabID
            }
        }
        focusedGroupID = groupID
    }

    func toggleFocusedViewMode() {
        guard let key = selection else { return }
        let node = layout(for: key)
        guard let groupID = focusedGroupID ?? node.firstGroupID(),
              let tab = node.selectedTab(in: groupID), tab.isAgentTab else { return }
        toggleViewMode(tab.id, in: groupID, key: key)
    }

    func chatController(for tab: WorkbenchTab) -> ChatPaneController {
        if let existing = chatControllers[tab.id] {
            attachChat(existing, tab: tab)
            return existing
        }
        let controller = ChatPaneController()
        chatControllers[tab.id] = controller
        attachChat(controller, tab: tab)
        return controller
    }

    func prepareChat(for tab: WorkbenchTab) {
        guard tab.isAgentTab else { return }
        _ = chatController(for: tab)
    }

    func submitChat(for tab: WorkbenchTab) async {
        guard let service = runtime?.terminalService,
              let handle = chatHandle(for: tab) else {
            chatController(for: tab).refusal = chatHandle(for: tab) == nil
                ? "No agent is attached to this tab."
                : "Runtime is unavailable."
            return
        }
        await chatController(for: tab).submit(handle: handle, service: service)
    }

    func chatHandle(for tab: WorkbenchTab) -> String? {
        guard let agent = agentSession(for: tab) else { return nil }
        if let paneKey = agent.paneKey,
           let handle = runtime?.terminalService.liveHandle(forPaneKey: paneKey) {
            return handle
        }
        return agent.terminalHandle
    }

    func agentSession(for tab: WorkbenchTab) -> AgentSession? {
        guard let agentID = tab.agentID else { return nil }
        for project in projects {
            if let agent = project.agents.agents.first(where: { $0.id == agentID }) {
                return agent
            }
        }
        return nil
    }

    private func attachChat(_ controller: ChatPaneController, tab: WorkbenchTab) {
        guard let service = runtime?.terminalService,
              let handle = chatHandle(for: tab) else { return }
        controller.start(handle: handle, service: service)
    }

    private func dropChat(_ tabID: UUID) {
        chatControllers[tabID]?.stop()
        chatControllers[tabID] = nil
    }

    func selectKind(_ kind: TabKind) {
        guard let key = selection else { return }
        guard unsupportedReason(kind, for: key) == nil else { return }
        let node = layout(for: key)
        guard let groupID = focusedGroupID ?? node.firstGroupID() else { return }
        if let tab = node.selectedTab(in: groupID), tab.kind == kind { return }
        var found: UUID?
        _ = {
            var copy = node
            _ = copy.mutateGroup(groupID) { group in
                found = group.tabs.first { $0.kind == kind }?.id
            }
        }()
        if let found {
            selectTab(found, in: groupID, key: key)
        } else {
            addTab(kind, to: groupID, key: key)
        }
    }

    func workspaceRoot(for key: WorkbenchKey) -> URL? {
        switch key {
        case .projectRoot(let id):
            return projects.first { $0.id == id }?.repo
        case .worktree(let id):
            for project in projects {
                if let record = project.record(id: id) { return record.path }
            }
            return nil
        }
    }

    func editorController(root: URL, path: String) -> EditorDocumentController {
        editorSessions.controller(root: root, path: path,
                                  files: runtime?.fileService ?? FileService())
    }

    /// Open (or focus) an editor tab for `relativePath` in the selected workbench.
    func openEditor(_ relativePath: String) {
        pendingOpenPath = relativePath
        guard let key = selection else { return }
        guard unsupportedReason(RemoteAffordance.editor, for: key) == nil else { return }
        var node = layout(for: key)
        if let found = node.findEditor(path: relativePath) {
            selectTab(found.tabID, in: found.groupID, key: key)
            prepareEditor(relativePath, key: key)
            return
        }
        guard let groupID = focusedGroupID ?? node.firstGroupID() else { return }
        var reused = false
        _ = node.mutateGroup(groupID) { group in
            if let index = group.tabs.firstIndex(where: { $0.kind == .editor && $0.filePath == nil }) {
                group.tabs[index].filePath = relativePath
                group.tabs[index].title = (relativePath as NSString).lastPathComponent
                group.tabs[index].isDirty = false
                group.selectedID = group.tabs[index].id
                reused = true
            }
        }
        if reused {
            layouts[key] = node
            focusedGroupID = groupID
            objectWillChange.send()
            prepareEditor(relativePath, key: key)
            return
        }
        let tab = WorkbenchTab(kind: .editor, filePath: relativePath)
        updateLayout(key) { node in
            _ = node.mutateGroup(groupID) { group in
                group.tabs.append(tab)
                group.selectedID = tab.id
            }
        }
        focusedGroupID = groupID
        prepareEditor(relativePath, key: key)
    }

    func openDiff(_ relativePath: String) {
        guard unsupportedReason(RemoteAffordance.diff, for: selection) == nil else { return }
        pendingOpenPath = relativePath
        selectKind(.diff)
    }

    func setEditorDirty(_ tabID: UUID, _ dirty: Bool, key: WorkbenchKey) {
        if layout(for: key).tab(id: tabID)?.isDirty == dirty { return }
        updateLayout(key) { node in
            _ = node.mutateTab(tabID) { $0.isDirty = dirty }
        }
    }

    func saveFocusedEditor() {
        guard let key = selection else { return }
        let node = layout(for: key)
        guard let groupID = focusedGroupID ?? node.firstGroupID(),
              let tab = node.selectedTab(in: groupID),
              tab.kind == .editor,
              let path = tab.filePath,
              let root = workspaceRoot(for: key) else { return }
        let saved = editorSessions.save(root: root, path: path)
        if saved {
            setEditorDirty(tab.id, false, key: key)
            Task { await refreshGit(for: key) }
        }
    }

    func refreshGit(for key: WorkbenchKey) async {
        if isRemote(key) { return }
        switch key {
        case .worktree(let id):
            for project in projects {
                if let record = project.record(id: id) {
                    await record.refresh()
                    return
                }
            }
        case .projectRoot(let id):
            if let project = projects.first(where: { $0.id == id }) {
                await project.refreshCheckout()
            }
        }
    }

    private func prepareEditor(_ relativePath: String, key: WorkbenchKey) {
        guard let root = workspaceRoot(for: key) else { return }
        _ = editorController(root: root, path: relativePath)
    }

    /// Damson session for a terminal tab. Agent tabs use the supervisor's session;
    /// local shells are created through the terminal service so a clean quit can
    /// hand them to the keeper and the next boot re-attaches the adopted PTY
    /// (T31). Views never spawn a PTY of their own.
    func damsonSession(for tab: WorkbenchTab, key: WorkbenchKey, cwd: URL) -> DamsonSession? {
        if let agentID = tab.agentID {
            for project in projects {
                if let agent = project.agents.agents.first(where: { $0.id == agentID }),
                   let session = (agent.terminal as? DamsonTerminalSession)?.session {
                    return session
                }
            }
        }
        if let existing = shells[tab.id] { return existing }
        let worktreeId = workspaceId(for: key)
        let workspaceHost = executionHostId(for: key).flatMap { ExecutionHostId(rawValue: $0) }
        let tabHost = tab.executionHostId.flatMap { ExecutionHostId(rawValue: $0) }
        // A remote workspace owns the host. A tab-only remote host (the T29
        // Remote Shell menu on a local workspace) keeps a login shell.
        let host = (workspaceHost?.isLocal == false ? workspaceHost : nil) ?? tabHost ?? .local
        if !host.isLocal {
            return openRemoteShell(tab: tab, key: key, host: host, worktreeId: worktreeId,
                                   workspaceIsRemote: workspaceHost?.isLocal == false)
        }
        if let worktreeId,
           let adopted = runtime?.terminalService.adoptedShellDamsonSession(worktreeId: worktreeId),
           !shells.values.contains(where: { $0 === adopted }) {
            shells[tab.id] = adopted
            return adopted
        }
        var config = settings.terminalConfig()
        config.cwd = cwd.path
        config.argv = DamsonConfig.defaultArgv()
        let size = paneSpawnSize()
        if let runtime {
            do {
                let summary = try runtime.terminalService.create(
                    worktreeId: worktreeId, cwd: cwd.path, engineID: "shell",
                    title: tab.title, executionHostId: host.rawValue,
                    initialCols: size.cols, initialRows: size.rows)
                if let session = runtime.terminalService.damsonSession(handle: summary.handle) {
                    shells[tab.id] = session
                    return session
                }
            } catch {
                NSLog("orchard: failed to register shell pane: %@", String(describing: error))
            }
        }
        let session = DamsonSession(config: config,
                                    initialCols: size.cols, initialRows: size.rows)
        shells[tab.id] = session
        return session
    }

    /// Open the ssh pane the runtime already knows how to spawn: `ssh -tt`
    /// plus `cd <remote path> && exec $SHELL -l` when the workspace is remote.
    /// Never hands the remote path to a local `chdir`.
    private func openRemoteShell(tab: WorkbenchTab, key: WorkbenchKey,
                                 host: ExecutionHostId, worktreeId: String?,
                                 workspaceIsRemote: Bool) -> DamsonSession? {
        if let worktreeId,
           let adopted = runtime?.terminalService.adoptedShellDamsonSession(worktreeId: worktreeId),
           !shells.values.contains(where: { $0 === adopted }) {
            attachConnectionNote(tabID: tab.id, host: host, session: adopted)
            shells[tab.id] = adopted
            return adopted
        }
        // A pane restored from the keeper whose `ssh` ended while we were gone (T43).
        // Opening a fresh connection here would be the wrong answer twice over: it
        // would silently replace a pane the user has not been told about, and it would
        // do it without them ever seeing that the previous connection ended. The tab
        // shows the verdict and a Reconnect button instead.
        if let ended = endedRemotePane(worktreeId: worktreeId, host: host, tabID: tab.id) {
            // Only the (unpublished) binding is recorded here: this runs inside a view
            // update, and the sentence the tab shows is derived on read instead.
            remotePaneKeys[tab.id] = ended.paneKey
            return nil
        }
        guard let record = try? runtime?.hostRegistry.require(host: host) else {
            return nil
        }
        let remoteCommand: String?
        if workspaceIsRemote, let path = remotePath(for: key), !path.isEmpty {
            remoteCommand = SSHCommand.cdAndLoginShellCommand(directory: path)
        } else {
            remoteCommand = nil
        }
        let prompt = SSHCommand.remoteShellCommandLine(for: record, command: remoteCommand)
        let size = paneSpawnSize()
        if let runtime {
            do {
                let summary = try runtime.terminalService.create(
                    worktreeId: worktreeId, cwd: nil, engineID: "shell",
                    prompt: prompt, title: tab.title,
                    executionHostId: host.rawValue,
                    initialCols: size.cols, initialRows: size.rows,
                    remoteCwd: workspaceIsRemote ? remotePath(for: key) : nil)
                if let session = runtime.terminalService.damsonSession(handle: summary.handle) {
                    attachConnectionNote(tabID: tab.id, host: host, session: session)
                    remotePaneKeys[tab.id] = summary.paneKey
                    shells[tab.id] = session
                    return session
                }
            } catch {
                NSLog("orchard: failed to open remote pane: %@", String(describing: error))
            }
        }
        var config = settings.terminalConfig()
        config.cwd = NSHomeDirectory()
        config.argv = SSHCommand.remoteShellArgv(for: record, command: remoteCommand)
        let session = DamsonSession(config: config,
                                    initialCols: size.cols, initialRows: size.rows)
        attachConnectionNote(tabID: tab.id, host: host, session: session)
        shells[tab.id] = session
        return session
    }

    private func remotePath(for key: WorkbenchKey) -> String? {
        switch key {
        case .projectRoot(let id):
            return projects.first { $0.id == id }?.repo.path
        case .worktree(let id):
            for project in projects {
                if let record = project.record(id: id) { return record.path.path }
            }
            return nil
        }
    }

    private func attachConnectionNote(tabID: UUID, host: ExecutionHostId, session: DamsonSession) {
        session.onExit = { [weak self] code in
            Task { @MainActor in
                self?.connectionNotes[tabID] =
                    HostLiveness.describeConnectionEnd(host: host, exitCode: code)
            }
        }
    }

    /// A restored remote pane for this tab's workspace whose connection has ended.
    ///
    /// Matched on the workspace *and* the host, because two hosts can hold panes with
    /// the same worktree id (design §5): adopting one host's dead pane into another
    /// host's tab would offer to reconnect to the wrong machine.
    private func endedRemotePane(worktreeId: String?, host: ExecutionHostId,
                                 tabID: UUID) -> TerminalSummary? {
        // A tab with no workspace identity has nothing to match on, and matching on
        // "any dead remote pane" would hand it somebody else's connection.
        guard let worktreeId,
              let summary = runtime?.terminalService.endedRemotePane(worktreeId: worktreeId),
              summary.executionHostId == host.rawValue else { return nil }
        // One dead pane, one tab: whichever tab already claimed it keeps it, so two
        // tabs can never offer to reconnect the same pane twice.
        if let owner = remotePaneKeys.first(where: { $0.value == summary.paneKey })?.key,
           owner != tabID { return nil }
        return summary
    }

    /// Whether this tab is showing a remote pane whose connection ended and can be
    /// reopened. The button appears only when there is a real pane behind it — an
    /// affordance that might do nothing is worse than none.
    func reconnectablePaneKey(for tab: WorkbenchTab) -> String? {
        endedRemoteSummary(for: tab).map(\.paneKey)
    }

    /// What this tab's remote pane says about its connection, or nil when there is
    /// nothing to say.
    ///
    /// The live verdict wins when the PTY ended during this app run —
    /// `HostLiveness.describeConnectionEnd` had a status to read there, and it may say
    /// the remote command itself exited. A pane restored with its connection already
    /// gone has no status at all, which is the stronger `unverifiable`, and gets the
    /// restart wording.
    func connectionEndedNote(for tab: WorkbenchTab) -> String? {
        if let note = connectionNotes[tab.id] { return note }
        guard let summary = endedRemoteSummary(for: tab) else { return nil }
        if let recorded = endedPaneNotes[summary.paneKey] { return recorded }
        guard let host = ExecutionHostId(rawValue: summary.executionHostId) else { return nil }
        return RemotePaneRestoration.describeEndedWhileHeld(host: host)
    }

    /// Record what a pane restored without a connection says about itself (T43). The
    /// wording is decided by the boot path, which is the only place that knows whether
    /// the keeper answered at all.
    func noteEndedRemotePane(paneKey: String, note: String) {
        endedPaneNotes[paneKey] = note
    }

    private func endedRemoteSummary(for tab: WorkbenchTab) -> TerminalSummary? {
        guard let paneKey = remotePaneKeys[tab.id],
              let summary = runtime?.terminalService.summary(paneKey: paneKey),
              !summary.connected else { return nil }
        return summary
    }

    /// Reopen the connection behind this tab: a fresh `ssh` from the pane's own
    /// recorded spec, under the same pane key with the next incarnation. The tab then
    /// binds the new PTY — a different channel to the same pane, which is why the
    /// surface is rebuilt rather than re-pointed.
    func reconnectRemotePane(tab: WorkbenchTab) {
        guard let paneKey = reconnectablePaneKey(for: tab), let runtime else { return }
        do {
            let summary = try runtime.terminalService.reconnectRemote(paneKey: paneKey)
            connectionNotes[tab.id] = nil
            endedPaneNotes[paneKey] = nil
            if let session = runtime.terminalService.damsonSession(handle: summary.handle) {
                if let host = ExecutionHostId(rawValue: summary.executionHostId) {
                    attachConnectionNote(tabID: tab.id, host: host, session: session)
                }
                shells[tab.id] = session
            }
            paneGeneration[tab.id, default: 0] += 1
        } catch {
            connectionNotes[tab.id] =
                "Reconnect failed: \(String(describing: error)). Nothing on the host was "
                    + "touched."
        }
    }

    /// RPC worktree identity for a workbench key, used to stamp UI shells so
    /// keeper adoption can re-attach them to the same workspace on the next boot.
    private func workspaceId(for key: WorkbenchKey) -> String? {
        switch key {
        case .worktree(let id):
            for project in projects {
                if let record = project.record(id: id) {
                    return workspaceIdentity(for: record, in: project)
                }
            }
            return nil
        case .projectRoot(let id):
            guard let project = projects.first(where: { $0.id == id }),
                  let repoID = project.repoID else { return nil }
            return "\(repoID)::\(project.repo.path)"
        }
    }

    /// Why a terminal pane has no session. A remote pane whose host is not registered
    /// says so instead of silently opening a local shell.
    func paneUnavailableDetail(for tab: WorkbenchTab, key: WorkbenchKey? = nil) -> String {
        if let note = connectionNotes[tab.id] { return note }
        let hostName = tab.remoteHostLabel
            ?? key.flatMap { executionHostId(for: $0) }.map { RemoteWorkspacePolicy.hostLabel($0) }
        if let hostName, hostName != "Local" {
            return "No host named \(hostName) is registered, so nothing was launched. "
                + "Register it with `orchard host add`."
        }
        return "Could not attach a terminal to this tab."
    }

    /// The spawn geometry for a new PTY pane. Every terminal pane renders in the same
    /// workbench chrome, so a session that is already attached carries the live answer
    /// in its grid; only the very first terminal after launch falls back to the default.
    /// Either way the view still resizes the session on attach — this only decides what
    /// size the child sees at spawn, before the first SIGWINCH.
    private func paneSpawnSize() -> (cols: Int, rows: Int) {
        if let session = shells.values.first {
            return (session.grid.cols, session.grid.rows)
        }
        for project in projects {
            for agent in project.agents.agents {
                if let session = (agent.terminal as? DamsonTerminalSession)?.session {
                    return (session.grid.cols, session.grid.rows)
                }
            }
        }
        return (TerminalSpawnDefaults.cols, TerminalSpawnDefaults.rows)
    }

    func applyShellAppearance(_ config: DamsonConfig) {
        for session in shells.values {
            var updated = session.config
            updated.theme = config.theme
            updated.fontSize = config.fontSize
            updated.fontFamily = config.fontFamily
            session.updateConfig(updated)
        }
    }

    private func applyTerminalConfigToAll() {
        let config = settings.terminalConfig()
        for project in projects {
            project.apply(settings)
            project.applyTerminalConfig(config)
        }
        applyShellAppearance(config)
        objectWillChange.send()
    }

    private func dropWorkbench(for project: ProjectSession) {
        let keys: [WorkbenchKey] = [.projectRoot(project.id)]
            + project.records.map { .worktree($0.id) }
        for key in keys {
            if let node = layouts[key] { dropChat(in: node) }
            layouts[key] = nil
        }
    }

    private func dropChat(in node: SplitNode) {
        switch node {
        case .group(let group):
            for tab in group.tabs { dropChat(tab.id) }
        case .split(_, _, let first, let second):
            dropChat(in: first)
            dropChat(in: second)
        }
    }

    // MARK: - Events

    private func handle(_ event: OrchardEvent, from project: ProjectSession) {
        switch event {
        case .agentSpawned(let agentID, let worktreeID, _):
            meta.touch(worktreeID ?? project.id)
            if let agent = project.agents.agents.first(where: { $0.id == agentID }) {
                attachStatusStream(for: agent)
                if let worktreeID {
                    bindAgentTab(agent, key: .worktree(worktreeID))
                }
            }
        case .agentStateChanged(_, let worktreeID, let state):
            if let worktreeID { meta.touch(worktreeID) }
            if case .finished = state { /* highlighted via needsAttention */ break }
            if case .errored = state { break }
            _ = state
        case .agentRetired(let agentID, _):
            detachStatusStream(agentID)
        case .agentNeedsAttention(let agentID, let worktreeID, let state):
            applyUnread(.agentActivity(agentID: agentID, workspaceID: worktreeID))
            let onScreen: Bool = {
                guard case let .worktree(id) = selection, id == worktreeID else { return false }
                return NSApp.isActive
            }()
            if !onScreen, let worktreeID, let record = project.record(id: worktreeID) {
                notify(record: record, project: project, state: state)
            }
        case .worktreeCreated(let worktree):
            if let repoID = project.repoID {
                meta.register(worktree.id, key: worktree.workspaceId(repoId: repoID))
            }
            _ = meta.ensure(worktree.id)
        case .worktreeRemoved(let worktreeID, _):
            applyUnread(.workspaceRemoved(worktreeID))
            meta.remove(worktreeID)
            layouts[.worktree(worktreeID)] = nil
        default:
            break
        }
        objectWillChange.send()
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.notificationsAuthorized = granted }
            }
    }

    private func notify(record: WorktreeRecord, project: ProjectSession, state: AgentRuntimeState) {
        guard notificationsAuthorized, settings.notificationsEnabled else { return }
        if settings.notifyOnlyWhenBlocked {
            switch state {
            case .awaitingApproval, .awaitingInput, .errored: break
            default: return
            }
        }
        let content = UNMutableNotificationContent()
        content.title = "\(record.title) · \(project.name)"
        switch state {
        case .awaitingApproval: content.body = "Waiting for your approval."
        case .awaitingInput: content.body = "Waiting for your input."
        case .finished: content.body = "Finished."
        case .errored: content.body = "Stopped with an error."
        default: content.body = "Finished a turn."
        }
        content.sound = (state == .awaitingApproval || state == .awaitingInput) ? .default : nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
    }
}
