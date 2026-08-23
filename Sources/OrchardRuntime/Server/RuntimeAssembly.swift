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
    public nonisolated let waitCenter: MessageWaitCenter
    /// T10: per-workspace embedded browser. WebKit-free here — the app attaches
    /// a `BrowserWebHost` over its WKWebViews; without one the verbs fail typed.
    public nonisolated let browserService: BrowserService

    public nonisolated let registry: CommandRegistry
    /// In-process client of the same registry (the app's path; no socket involved).
    public nonisolated let inMemory: InMemoryRuntimeServer
    public private(set) var socketServer: UnixSocketServer?

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default,
                terminalFactory: @escaping TerminalSessionFactory,
                cliCommand: String = "orchard", dataDirectory: URL? = nil,
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

        // Browser workspaces are keyed by worktree path; CLI selectors resolve
        // through the workspace registry when possible, else pass through raw.
        let workspaceService = self.workspaceService
        self.browserService = BrowserService(resolver: { selector in
            await MainActor.run { (try? workspaceService.show(selector: selector))?.path }
        })

        var registry = CommandRegistry()
        registry.register(StatusHandler(runtimeId: runtimeId, mode: mode))
        registry.register(OrchestrationCommandHandler(store: orchestration))
        // T7: the supervised-worker lifecycle verbs, driving the same orchestration
        // actor plus the live terminal/workspace seams.
        registry.register(WorkerCommandHandler(
            store: orchestration,
            runtime: .live(cliCommand: cliCommand,
                           workspaces: workspaceService,
                           terminals: terminalService)))
        registry.register(TerminalCommandHandler(service: terminalService))
        registry.register(WorkspaceCommandHandler(service: workspaceService))
        registry.register(RepoRegistryHandler(service: workspaceService))
        registry.register(FileCommandHandler(files: fileService,
                                             workspaces: workspaceService,
                                             opens: fileOpenCenter))
        registry.register(BrowserCommandHandler(service: browserService))
        self.registry = registry
        self.inMemory = InMemoryRuntimeServer(registry: registry, runtimeId: runtimeId)
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
                                          dataDirectory: dataDirectory, mode: mode)
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
