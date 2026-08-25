import Foundation
import OrchardCore
import OrchardOrchestration
import OrchardProtocol
import OrchardTerminals

/// The live runtime assembly: one place that owns the orchestration store, the
/// terminal service, the workspace service, and the handler registry, and can put a
/// unix socket in front of them (docs/REBUILD-PLAN.md "runtime-first").
///
/// The app boots this in-process; tests boot it against a scoped `FileManager` and a
/// scripted terminal factory. Either way, the registry is identical — which is what
/// makes "proven in-process ⇒ proven on the wire" true.
@MainActor
public final class OrchardRuntimeHost {
    public nonisolated let runtimeId: String
    public nonisolated let dataDirectory: URL
    public nonisolated let cliCommand: String
    public nonisolated let mode: RuntimeMode

    public nonisolated let dataStore: OrchardDataStore
    public let terminalService: TerminalService
    public let workspaceService: WorkspaceService
    public nonisolated let fileService: FileService
    public nonisolated let fileOpenCenter: FileOpenCenter
    public nonisolated let orchestration: LiveOrchestrationStore
    /// Same worker-verb context the CLI `WorkerCommandHandler` uses, so the
    /// in-app orchestration view cannot bypass terminal identity checks.
    public nonisolated let workerRuntime: WorkerRuntimeContext
    public nonisolated let waitCenter: MessageWaitCenter
    /// T10: per-workspace embedded browser. WebKit-free here — the app attaches
    /// a `BrowserWebHost` over its WKWebViews; without one the verbs fail typed.
    public nonisolated let browserService: BrowserService
    public nonisolated let automationService: AutomationService
    public nonisolated let automationScheduler: AutomationScheduler
    /// T20: debounced listening-port sweep, attributed by process cwd containment.
    public nonisolated let portService: PortService
    /// T29: the registered remote hosts behind `ssh:<name>` execution host ids.
    public nonisolated let hostRegistry: HostRegistry
    /// T45: periodic bounded host-reachability producer. Idle unless a remote repo
    /// or remote pane exists; publishes presentation-only status through the registry.
    public nonisolated let hostLiveness: HostLivenessService
    /// T39: the local end of the Tier-1 hook channel, used by remote agent panes whose
    /// hooks arrive through an SSH reverse tunnel. Binds lazily on first use, so a
    /// runtime that never opens one holds no listening socket.
    public nonisolated let hookChannel: HookServerChannel

    public nonisolated let registry: CommandRegistry
    /// In-process client of the same registry (the app's path; no socket involved).
    public nonisolated let inMemory: InMemoryRuntimeServer
    public private(set) var socketServer: UnixSocketServer?

    private let fileManager: FileManager

    /// `cliCommand` defaults to the resolved absolute path of this machine's
    /// `orchard` binary (T35): it becomes `ORCHARD_CLI_COMMAND` in every worker PTY
    /// and the command string the dispatch preamble tells workers to run, and a bare
    /// `orchard` is not on a worker's PATH.
    public init(fileManager: FileManager = .default,
                terminalFactory: @escaping TerminalSessionFactory,
                cliCommand: String = OrchardCLIPath.resolve(), dataDirectory: URL? = nil,
                mode: RuntimeMode = .app) throws {
        self.fileManager = fileManager
        self.cliCommand = cliCommand
        self.mode = mode
        self.runtimeId = "rt_" + UUID().uuidString.lowercased()
        let paths = try RuntimePaths.prepare(fileManager: fileManager, dataDirectory: dataDirectory)
        self.dataDirectory = paths.data

        self.dataStore = OrchardDataStore(
            url: paths.data.appendingPathComponent("orchard-data.json"))
        let terminalService = TerminalService(factory: terminalFactory)
        self.terminalService = terminalService
        self.workspaceService = WorkspaceService(store: dataStore)
        self.hostRegistry = HostRegistry(store: dataStore)
        // The channel a remote agent pane's hooks come home through (T39). Handed to
        // the terminal service so a pane created with `statusDetection: .hooks`
        // subscribes its token, and to the terminal handler so the launch path can read
        // the port before it writes the far side's config.
        let hookChannel = HookServerChannel()
        self.hookChannel = hookChannel
        terminalService.hookChannel = hookChannel
        self.fileService = FileService()
        self.fileOpenCenter = FileOpenCenter()

        let waitCenter = MessageWaitCenter()
        self.waitCenter = waitCenter
        // The orchestration verbs see terminals only through these projections —
        // group expansion needs the directory, lifecycle authority needs paneKeys.
        let context = OrchestrationRuntimeContext(
            cliCommand: cliCommand,
            terminals: {
                await MainActor.run {
                    terminalService.list().map { summary in
                        (entry: TerminalDirectoryEntry(handle: summary.handle,
                                                       title: summary.title,
                                                       worktreeID: summary.worktreeId),
                         agentStatus: summary.agentState?.rawValue)
                    }
                }
            },
            paneKey: { handle in
                await MainActor.run { Self.resolvePaneKey(terminalService, handle: handle) }
            })
        self.orchestration = try LiveOrchestrationStore(
            databasePath: paths.data.appendingPathComponent("orchestration.db").path,
            waitCenter: waitCenter,
            context: context)

        // T11: every PTY end flows into worker-process-exit reconciliation — a live
        // supervised dispatch fails, and non-deliberate exits escalate to the Run.
        let orchestration = self.orchestration
        terminalService.onTerminalExit = { event in
            Task { await orchestration.handleWorkerTerminalExit(event) }
        }

        // Browser workspaces are keyed by worktree path; CLI selectors resolve
        // through the workspace registry when possible, else pass through raw.
        // The data store carries T21 session profiles + per-workspace bindings.
        let workspaceService = self.workspaceService
        self.browserService = BrowserService(resolver: { selector in
            await MainActor.run { (try? workspaceService.show(selector: selector))?.path }
        }, store: dataStore)

        let workerRuntime = WorkerRuntimeContext.live(cliCommand: cliCommand,
                                                      workspaces: workspaceService,
                                                      terminals: terminalService)
        self.workerRuntime = workerRuntime
        let automationService = AutomationService(store: dataStore) { automation in
            switch automation.target {
            case .repo(let selector):
                let runValue = try await orchestration.runCreate([
                    "objective": .string("Automation: \(automation.name)")])
                guard let runID = runValue.field("runId")?.stringValue else {
                    throw AutomationScheduleError.invalid("could not create automation run")
                }
                let taskValue = try await orchestration.taskCreate([
                    "run": .string(runID), "spec": .string(automation.prompt),
                    "task-title": .string(automation.name)])
                guard let taskID = taskValue.field("taskId")?.stringValue else {
                    throw AutomationScheduleError.invalid("could not create automation task")
                }
                var start: [String: JSONValue] = [
                    "task": .string(taskID), "repo": .string(selector),
                    "worktree": .string("new-top-level"), "agent": .string(automation.provider),
                    "name": .string("automation-\(automation.id.suffix(8))-\(Int(Date().timeIntervalSince1970))"),
                    "setup": .string("run")]
                // T60: a shell provider gets its prompt as an executable command line
                // (run → worker_done with the exit status → exit), never the agent
                // preamble, which zsh cannot execute and would hold in pending input.
                if AutomationShellDispatch.isShellProvider(automation.provider) {
                    start[AutomationShellDispatch.workerStartParam] = .string(AutomationShellDispatch.shellCommandMode)
                }
                let value = try await orchestration.workerStart(start, runtime: workerRuntime)
                return AutomationFireReceipt(worktreeId: value.field("effects")?.arrayValue?
                    .first(where: { $0.field("kind")?.stringValue == "worktree" })?.field("id")?.stringValue,
                    terminalId: value.field("effects")?.arrayValue?
                    .first(where: { $0.field("kind")?.stringValue == "terminal" })?.field("id")?.stringValue,
                    runId: value.field("runId")?.stringValue,
                    dispatchId: value.field("dispatchId")?.stringValue)
            case .workspace(let selector):
                let workspace = try await workspaceService.resolveWorkspace(selector, cwd: nil)
                let terminals = await terminalService.list(worktreeId: workspace.id)
                guard let terminal = terminals.first(where: {
                    $0.agentState != nil && $0.engine == automation.provider
                }) else {
                    throw AutomationScheduleError.invalid("workspace has no \(automation.provider) agent terminal")
                }
                let sent = try await terminalService.send(handle: terminal.handle,
                    text: automation.prompt, enter: true, requireAgent: true)
                guard sent.accepted else {
                    throw AutomationScheduleError.invalid(
                        "agent prompt refused: \(sent.refusedReason?.rawValue ?? "unknown")")
                }
                return AutomationFireReceipt(worktreeId: workspace.id, terminalId: terminal.handle)
            }
        }
        self.automationService = automationService
        let automationScheduler = AutomationScheduler(service: automationService)
        self.automationScheduler = automationScheduler

        let workspaceServiceForPorts = self.workspaceService
        let portService = PortService(
            workspaces: {
                await MainActor.run {
                    // Local workspaces only: port attribution matches a listening
                    // process's cwd against a workspace path, and a remote path that
                    // happened to match a local process's cwd would attribute another
                    // machine's port to this one (T32).
                    ((try? workspaceServiceForPorts.listWorkspaces()) ?? [])
                        .filter { !WorkspaceService.isRemote($0) }
                        .map { workspace in
                            PortWorkspaceProbe(
                                id: workspace.id, repoId: workspace.repoId,
                                displayName: workspace.displayName.isEmpty
                                    ? workspace.path : workspace.displayName,
                                path: workspace.path)
                        }
                }
            },
            interval: PortService.intervalFromEnvironment())
        self.portService = portService

        let hostRegistryForLiveness = self.hostRegistry
        let workspaceServiceForLiveness = self.workspaceService
        let terminalServiceForLiveness = terminalService
        let hostLiveness = HostLivenessService(
            hosts: { hostRegistryForLiveness.list() },
            surface: {
                await MainActor.run {
                    HostLivenessSurface.collect(
                        repos: workspaceServiceForLiveness.listRepos(),
                        terminals: terminalServiceForLiveness.list())
                }
            },
            interval: HostLivenessService.intervalFromEnvironment())
        self.hostLiveness = hostLiveness

        var registry = CommandRegistry()
        registry.register(StatusHandler(runtimeId: runtimeId, mode: mode,
                                        cliCommand: cliCommand))
        registry.register(OrchestrationCommandHandler(store: orchestration))
        // T7: the supervised-worker lifecycle verbs, driving the same orchestration
        // actor plus the live terminal/workspace seams.
        registry.register(WorkerCommandHandler(
            store: orchestration,
            runtime: workerRuntime))
        registry.register(TerminalCommandHandler(service: terminalService,
                                                 workspaces: workspaceService,
                                                 hosts: hostRegistry,
                                                 hookChannel: hookChannel))
        registry.register(HostCommandHandler(registry: hostRegistry,
                                             liveness: hostLiveness))
        // T43: reopening a remote pane's connection is a host-layer decision (typed
        // refusals for local panes, live panes, and hosts that left the registry), so
        // it registers its own verb rather than widening the terminal handler.
        registry.register(RemotePaneReconnectHandler(service: terminalService,
                                                     hosts: hostRegistry))
        registry.register(WorkspaceCommandHandler(service: workspaceService))
        registry.register(RepoRegistryHandler(service: workspaceService))
        registry.register(FileCommandHandler(files: fileService,
                                             workspaces: workspaceService,
                                             opens: fileOpenCenter))
        registry.register(BrowserCommandHandler(service: browserService))
        registry.register(AutomationCommandHandler(service: automationService))
        registry.register(PortCommandHandler(
            ports: portService, workspaces: workspaceService, terminals: terminalService))
        self.registry = registry
        self.inMemory = InMemoryRuntimeServer(registry: registry, runtimeId: runtimeId)
        automationScheduler.start()
        portService.start()
        hostLiveness.start()
    }

    /// Where the production runtime keeps its state; exposed so the app can build a
    /// terminal factory with `ORCHARD_DATA_PATH` before constructing the host.
    public nonisolated static func defaultDataDirectory(fileManager: FileManager = .default) -> URL {
        RuntimePaths.applicationSupport(fileManager: fileManager)
    }

    /// Bind the unix socket and publish `orchard-runtime.json` (runtimeId, pid,
    /// socketPath, authToken) so the `orchard` CLI can find this runtime.
    @discardableResult
    public func startSocketServer(authToken: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) throws -> RuntimeMetadata {
        if let existing = socketServer { return existing.metadata }
        let server = try UnixSocketServer(registry: registry, fileManager: fileManager,
                                          runtimeId: runtimeId, authToken: authToken,
                                          dataDirectory: dataDirectory, mode: mode,
                                          cliCommand: cliCommand)
        server.start()
        socketServer = server
        return server.metadata
    }

    /// Wire an `AgentSupervisor` into this runtime: its PTYs get the ORCHARD_* host
    /// facts, and every spawn is adopted into T3's terminal registry so the injected
    /// handle is real (resolvable, remintable) rather than provisional.
    public func attach(_ supervisor: AgentSupervisor) {
        supervisor.hostContext = TerminalHostContext(cliCommand: cliCommand,
                                                     dataPath: dataDirectory.path)
        supervisor.onSpawnRegistration = { [weak self] agent, spec in
            guard let self else { return }
            do {
                _ = try self.terminalService.adopt(agentSession: agent, spec: spec)
            } catch {
                NSLog("orchard: failed to adopt spawned agent terminal: %@",
                      String(describing: error))
            }
        }
    }

    /// The worker-start seam: agent-first workspace creation launches through the
    /// given supervisor, and the returned terminal handle is the registry-real one.
    public func installAgentLauncher(_ supervisor: AgentSupervisor) {
        attach(supervisor)
        workspaceService.agentLauncher = AgentSupervisorLauncher(supervisor: supervisor)
    }

    public func shutdown() {
        automationScheduler.stop()
        portService.stop()
        hostLiveness.stop()
        socketServer?.stop(fileManager: fileManager)
        socketServer = nil
    }

    /// Handle → durable paneKey, following one remint hop: a stale handle still names
    /// its pane, so lifecycle authority keeps working across handle churn.
    static func resolvePaneKey(_ service: TerminalService, handle: String) -> String? {
        do {
            return try service.agentStatus(handle: handle).paneKey
        } catch TerminalServiceError.handleStale(_, let replacement) {
            guard let replacement else { return nil }
            return try? service.agentStatus(handle: replacement).paneKey
        } catch {
            return nil
        }
    }
}
