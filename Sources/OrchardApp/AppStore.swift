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
    @Published var selection: WorkbenchKey?
    @Published var filterProjectID: UUID?
    /// Board-column id from the workspace-status vocabulary (defaults + custom).
    @Published var filterStatusID: String?
    /// Archived cards stay hidden until this filter is on.
    @Published var showArchived = false
    @Published var ordering: CardOrdering = .manual

    @Published var composerProjectID: UUID?
    @Published var pendingDeletion: PendingDeletion?
    @Published var isJumpPaletteOpen = false

    /// Single unread source for cards and the dashboard. Views must not keep
    /// their own sets — fold events through `UnreadReducer`.
    @Published private(set) var unread = UnreadState()
    /// File the palette / `file open` asked the workbench to show.
    @Published var pendingOpenPath: String?
    /// Live `AgentStatusSnapshot` per agent, observation-only from the status stream.
    @Published private(set) var agentStatusByID: [UUID: AgentStatusSnapshot] = [:]
    /// Last completed T20 port sweep (attributed listeners only).
    @Published private(set) var portSnapshot = PortScanSnapshot.empty

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
    var showSettings: (() -> Void)?

    private var shells: [UUID: DamsonSession] = [:]
    /// T29: what a remote pane's PTY ending proved, in verdict language. Keyed by tab
    /// id. Published so the pane can say "the connection ended" instead of implying the
    /// remote work died — loss of contact is never evidence of death.
    @Published private(set) var connectionNotes: [UUID: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard
    /// Pre-T8 sidebar list. Imported once into the registry, then deleted.
    private let legacyWorkspacesKey = "orchard.workspaces"
    private var repoObserveTask: Task<Void, Never>?
    private var portObserveTask: Task<Void, Never>?
    private var statusListenTasks: [UUID: Task<Void, Never>] = [:]
    private var notificationsAuthorized = false

    struct PendingDeletion: Identifiable {
        let id: UUID
        let projectID: UUID
        let record: WorktreeRecord
    }

    init(settings: OrchardSettings, meta: WorkspaceMetaStore? = nil) {
        self.settings = settings
        let dataDirectory = OrchardRuntimeHost.defaultDataDirectory()
        // The factory injects ORCHARD_* into service-created PTYs; supervisor-spawned
        // PTYs get the same identity via attach().
        let factory = DamsonTerminalFactory.make(
            template: settings.terminalConfig(),
            context: TerminalHostContext(cliCommand: "orchard", dataPath: dataDirectory.path))
        let runtime = try? OrchardRuntimeHost(terminalFactory: factory)
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
        selectedProject?.worktrees.isGitRepository ?? false
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
        Task { await record.refresh() }
    }

    func selectProjectRoot(_ project: ProjectSession) {
        selectedProjectID = project.id
        selection = .projectRoot(project.id)
        ensureLayout(for: .projectRoot(project.id))
        Task { await project.refreshCheckout() }
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
        case .newWorktree:
            requestNewWorktree()
        case .toggleChat:
            toggleFocusedViewMode()
        case .openDashboard:
            showDashboard?()
        case .settings:
            showSettings?()
        }
    }

    func openBrowserTab(workspaceKey: String) {
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

    /// Bring `projects` in line with the registry. Missing directories are
    /// skipped (a `ProjectSession` cannot start). Newly added repos from the
    /// CLI appear here; Open Project creates the session itself and dedups.
    private func applyRegistry(_ repos: [RepoRecord], selectNewProjects: Bool) {
        var wanted: [String: RepoRecord] = [:]
        for record in repos {
            wanted[Self.standardizedPath(record.path)] = record
        }
        for project in projects where wanted[project.repo.standardizedFileURL.path] == nil {
            detachProject(project)
        }
        var opened: [ProjectSession] = []
        for record in repos {
            let url = URL(fileURLWithPath: record.path)
            if let existing = project(at: url) {
                existing.repoID = record.id
                continue
            }
            guard Self.isExistingDirectory(url) else { continue }
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
                preferredHookPort: keeperHookPortHints[repo.standardizedFileURL.path])
            project.onEvent = { [weak self] project, event in
                self?.handle(event, from: project)
            }
            if let runtime {
                // Supervisor PTYs get ORCHARD_* identity and land in the
                // terminal registry so worktree meta keys use `<repoId>::<path>`.
                runtime.attach(project.agents)
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
        return projects.first { $0.repo.standardizedFileURL.path == path }
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
        guard project.worktrees.isGitRepository else { return }
        composerProjectID = project.id
    }

    func compose(project: ProjectSession, name: String, prompt: String,
                 engineID: String, baseRef: String?, count: Int) throws {
        guard AgentEngineRegistry.engine(id: engineID) != nil else {
            throw GitError("engine '\(engineID)' isn't registered in this build.")
        }
        var first: WorktreeRecord?
        for _ in 0..<max(1, count) {
            let record = try project.worktrees.createWorktree(
                name: name, baseRef: baseRef, title: name)
            project.worktrees.runSetupScriptIfEnabled(for: record)
            registerMetaKey(record, in: project)
            _ = meta.ensure(record.id, status: .inProgress)
            meta.setStatus(.inProgress, for: record.id)
            let size = paneSpawnSize()
            let agent = try project.agents.spawnAgent(
                engineID: engineID, prompt: prompt, in: record.worktree, title: name,
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

    func startAgent(in record: WorktreeRecord, project: ProjectSession, engineID: String) throws {
        guard AgentEngineRegistry.engine(id: engineID) != nil else {
            throw GitError("engine '\(engineID)' isn't registered in this build.")
        }
        let size = paneSpawnSize()
        let agent = try project.agents.spawnAgent(
            engineID: engineID,
            prompt: record.lastPrompt ?? "",
            in: record.worktree,
            title: record.title,
            workspaceID: workspaceID(for: record, in: project),
            initialCols: size.cols, initialRows: size.rows)
        record.agentState = agent.state
        bindAgentTab(agent, key: .worktree(record.id))
        select(record, in: project)
    }

    func requestDelete(_ record: WorktreeRecord, in project: ProjectSession) {
        pendingDeletion = PendingDeletion(id: record.id, projectID: project.id, record: record)
    }

    func deleteWorktree(_ record: WorktreeRecord, in project: ProjectSession,
                        force: Bool, deleteBranch: Bool) throws -> Bool {
        project.agents.retireAgents(inWorktree: record.id)
        let deletion = try project.worktrees.deleteWorktree(
            record, force: force, deleteBranch: deleteBranch)
        guard deletion.removed else { return false }
        meta.remove(record.id)
        layouts[.worktree(record.id)] = nil
        if case .worktree(let id) = selection, id == record.id {
            selection = defaultSelection(for: project)
        }
        project.syncRecords()
        return true
    }

    // MARK: - Workbench

    func layout(for key: WorkbenchKey) -> SplitNode {
        ensureLayout(for: key)
        return layouts[key] ?? .makeDefault()
    }

    @discardableResult
    func ensureLayout(for key: WorkbenchKey) -> SplitNode {
        if let existing = layouts[key] { return existing }
        let node = SplitNode.makeDefault()
        layouts[key] = node
        focusedGroupID = node.firstGroupID()
        return node
    }

    func updateLayout(_ key: WorkbenchKey, _ body: (inout SplitNode) -> Void) {
        var node = layout(for: key)
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
        updateLayout(key) { node in
            _ = node.mutateGroup(groupID) { group in
                guard group.tabs.count > 1 else { return }
                group.tabs.removeAll { $0.id == tabID }
                if group.selectedID == tabID {
                    group.selectedID = group.tabs.last?.id ?? group.selectedID
                }
            }
        }
    }

    func splitFocused(axis: SplitAxis) {
        guard let key = selection, let groupID = focusedGroupID else { return }
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
    /// shells are owned here so views never spawn a PTY.
    func damsonSession(for tab: WorkbenchTab, cwd: URL) -> DamsonSession? {
        if let agentID = tab.agentID {
            for project in projects {
                if let agent = project.agents.agents.first(where: { $0.id == agentID }),
                   let session = (agent.terminal as? DamsonTerminalSession)?.session {
                    return session
                }
            }
        }
        if let existing = shells[tab.id] { return existing }
        var config = settings.terminalConfig()
        config.cwd = cwd.path
        // A remote pane runs `ssh -tt <host>` locally. If its host is no longer
        // registered the pane opens nothing at all: silently falling back to a local
        // shell under a remote label is the one outcome the host rules forbid.
        let host = tab.executionHostId.flatMap { ExecutionHostId(rawValue: $0) } ?? .local
        if host.isLocal {
            config.argv = DamsonConfig.defaultArgv()
        } else if let record = try? runtime?.hostRegistry.require(host: host) {
            config.argv = SSHCommand.remoteShellArgv(for: record)
        } else {
            // No session, and deliberately no local fallback. The reason is computed
            // on demand by `paneUnavailableDetail` rather than stored here: this runs
            // inside a view update, where publishing state is not allowed.
            return nil
        }
        let size = paneSpawnSize()
        let session = DamsonSession(config: config,
                                    initialCols: size.cols, initialRows: size.rows)
        // The PTY ending is the *connection* ending for a remote pane; what it proves
        // about the far side runs through the one verdict vocabulary.
        let tabID = tab.id
        session.onExit = { [weak self] code in
            Task { @MainActor in
                self?.connectionNotes[tabID] =
                    HostLiveness.describeConnectionEnd(host: host, exitCode: code)
            }
        }
        shells[tab.id] = session
        return session
    }

    /// Why a terminal pane has no session. A remote pane whose host is not registered
    /// says so instead of silently opening a local shell.
    func paneUnavailableDetail(for tab: WorkbenchTab) -> String {
        if let note = connectionNotes[tab.id] { return note }
        if let host = tab.remoteHostLabel {
            return "No host named \(host) is registered, so nothing was launched. "
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
