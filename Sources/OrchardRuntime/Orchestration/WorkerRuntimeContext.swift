import Foundation
import OrchardTerminals

/// The slice of live workspace + terminal capability the worker verbs consume, as
/// `@Sendable` closures so the verb logic (actor-isolated on `LiveOrchestrationStore`)
/// stays fully testable without git worktrees or PTYs — the same seam pattern as
/// `OrchestrationRuntimeContext`.
///
/// Each closure maps to one worker-start pipeline stage or observation need
/// (docs/research/orca-inventory.md §1.7-1.8); the `live` factory bridges them to T4's
/// `WorkspaceService` and T3's `TerminalService` on the main actor.
public struct WorkerRuntimeContext: Sendable {
    public enum ProviderTranscriptResolution: Sendable, Equatable {
        case resolved(content: String, path: String, truncated: Bool)
        case unavailable(reason: String)
    }

    /// What a best-effort worktree rollback did after a failed worker-start.
    public enum WorktreeRollback: Sendable, Equatable {
        /// The worktree was deleted; nothing of it remains.
        case removed
        /// Deliberately left in place, with the reason a caller can act on
        /// (`worktree_dirty`, `remote_unsupported`, `unknown_worktree`, …).
        case retained(reason: String)
    }

    public static let transcriptPinByteLimit = 2_000_000
    public var cliCommand: String

    /// `worktree_create`: run the worker-start-shaped composition (T4's helper) without
    /// an agent — the terminal is spawned as its own stage so failures attribute.
    public var createWorktree: @Sendable (WorkerWorktreeSpec) async throws -> WorkerWorktreeReceipt
    /// Resolve an existing workspace placement selector (`current` needs `cwd`).
    public var resolveWorktree: @Sendable (_ selector: String, _ cwd: String?) async throws -> WorkerWorktreeReceipt
    /// `terminal_create`: spawn an agent terminal in a worktree via T3's registry.
    /// The placement carries the workspace's host, so a remote dispatch opens a pane
    /// *on that host* instead of a local PTY sitting in a path that only exists there
    /// (T80).
    public var createAgentTerminal: @Sendable (
        _ engineID: String, _ placement: WorkerTerminalPlacement
    ) async throws -> TerminalSummary
    /// T80's supervised-dispatch precondition: ask the host, before anything is
    /// created, whether a worker there could actually discharge a dispatch's duties.
    /// The default answers "this runtime cannot even ask", which is what a context
    /// with no host registry wired must say — never a hopeful yes.
    public var probeRemoteDispatch: @Sendable (_ hostId: String) async -> RemoteDispatchReadiness
    /// Observation: current summary + agent status for a handle, following one remint
    /// hop (a stale handle still names its pane; authority keys on the pane).
    public var lookupTerminal: @Sendable (_ handle: String) async -> WorkerTerminalLookup
    /// `agent_readiness`: `terminal wait --for tui-idle` (permission never satisfies).
    public var waitForAgentIdle: @Sendable (
        _ handle: String, _ timeout: TimeInterval
    ) async throws -> TerminalWaitResult
    /// `dispatch_input`: the verified injection pipeline (typed refusals preserved).
    public var injectPrompt: @Sendable (_ handle: String, _ text: String) async throws -> TerminalSendResult
    /// Clear whatever is pending in a pane's input (Ctrl-C).
    ///
    /// T82 uses it as the recovery half of shell-contract delivery: a shell whose line
    /// editor had not taken the tty back truncates a multi-kilobyte contract, and what
    /// is left sitting at the continuation prompt includes the dispatch capability.
    /// Interrupting is the manual fix T80's verification had to perform by hand, so
    /// `worker-start` performs it itself — before the pane is ever called ready.
    public var interruptTerminal: @Sendable (_ handle: String) async -> Void
    /// Bounded output read (stream cursor paging; `cursor: nil` = the tail).
    public var readTerminal: @Sendable (
        _ handle: String, _ cursor: Int?, _ limit: Int
    ) async throws -> TerminalReadResult
    /// Resolve the hook-attested provider session into a bounded durable copy.
    public var resolveProviderTranscript: @Sendable (
        _ handle: String, _ maximumBytes: Int
    ) async -> ProviderTranscriptResolution
    /// Close the pane's PTY and unregister it.
    public var closeTerminal: @Sendable (_ handle: String) async throws -> Void
    /// Roll back a worktree this worker-start created and then abandoned (T35).
    /// The deletion is NEVER forced: the workspace layer's own preflight decides, so
    /// an untouched fresh worktree disappears and anything with work in it is
    /// retained with a typed reason for the receipt's residual list.
    public var rollbackWorktree: @Sendable (_ worktreeID: String) async -> WorktreeRollback

    public init(
        cliCommand: String = "orchard",
        createWorktree: @escaping @Sendable (WorkerWorktreeSpec) async throws -> WorkerWorktreeReceipt,
        resolveWorktree: @escaping @Sendable (String, String?) async throws -> WorkerWorktreeReceipt,
        createAgentTerminal: @escaping @Sendable (String, WorkerTerminalPlacement) async throws -> TerminalSummary,
        lookupTerminal: @escaping @Sendable (String) async -> WorkerTerminalLookup,
        waitForAgentIdle: @escaping @Sendable (String, TimeInterval) async throws -> TerminalWaitResult,
        injectPrompt: @escaping @Sendable (String, String) async throws -> TerminalSendResult,
        interruptTerminal: @escaping @Sendable (String) async -> Void = { _ in },
        readTerminal: @escaping @Sendable (String, Int?, Int) async throws -> TerminalReadResult,
        resolveProviderTranscript: @escaping @Sendable (String, Int) async -> ProviderTranscriptResolution = { _, _ in .unavailable(reason: "provider_session_unavailable") },
        closeTerminal: @escaping @Sendable (String) async throws -> Void,
        rollbackWorktree: @escaping @Sendable (String) async -> WorktreeRollback = { _ in
            .retained(reason: "rollback_unsupported")
        },
        probeRemoteDispatch: @escaping @Sendable (String) async -> RemoteDispatchReadiness = { _ in
            .refused(code: RemoteDispatchProbe.notWired,
                     detail: "this runtime has no remote-host access wired")
        }
    ) {
        self.cliCommand = cliCommand
        self.createWorktree = createWorktree
        self.resolveWorktree = resolveWorktree
        self.createAgentTerminal = createAgentTerminal
        self.lookupTerminal = lookupTerminal
        self.waitForAgentIdle = waitForAgentIdle
        self.injectPrompt = injectPrompt
        self.interruptTerminal = interruptTerminal
        self.readTerminal = readTerminal
        self.resolveProviderTranscript = resolveProviderTranscript
        self.closeTerminal = closeTerminal
        self.rollbackWorktree = rollbackWorktree
        self.probeRemoteDispatch = probeRemoteDispatch
    }

    /// The production wiring against the runtime host's services.
    ///
    /// `hosts` / `dataPath` / `runtimeId` are what make T80's supervised remote
    /// dispatch possible: the first lets the runtime *ask* a host whether a worker
    /// there could report back, and the other two are the two facts the far side needs
    /// in order to reach this runtime rather than whichever one its own `HOME` holds.
    /// Passing `hosts: nil` keeps every remote placement refused, which is the correct
    /// answer for a runtime that has no way to reach another machine.
    public static func live(cliCommand: String,
                            workspaces: WorkspaceService,
                            terminals: TerminalService,
                            hosts: HostRegistry? = nil,
                            hookChannel: AgentHookChannel? = nil,
                            hostRunner: HostCommandRunner = ProcessHostCommandRunner(),
                            connections: RemoteConnectionPool? = nil,
                            dataPath: String = "",
                            runtimeId: String = "") -> WorkerRuntimeContext {
        let remotePanes = hosts.map {
            RemotePaneLauncher(service: terminals, hosts: $0,
                               localHookPort: { hookChannel?.localHookPort ?? 0 },
                               hostRunner: hostRunner)
        }
        let probe = hosts.map {
            RemoteDispatchProbe(hosts: $0, runner: hostRunner, cliCommand: cliCommand,
                                dataPath: dataPath, runtimeId: runtimeId)
        }
        return WorkerRuntimeContext(
            cliCommand: cliCommand,
            createWorktree: { spec in
                guard let repo = spec.repo else {
                    throw WorkspaceError("invalid_argument",
                                         "worker-start needs --repo to create a worktree")
                }
                let result = try await workspaces.startWorker(WorkspaceCreateRequest(
                    repo: repo,
                    name: spec.name,
                    displayName: spec.displayName,
                    baseBranch: spec.baseBranch,
                    noParent: !spec.newChild,
                    cwd: spec.cwd,
                    runSetup: spec.runSetup))
                return WorkerWorktreeReceipt(
                    id: result.worktreeId, instanceId: result.instanceId,
                    path: result.workspace.path, displayName: result.workspace.displayName,
                    warning: result.warning, hostId: result.workspace.hostId)
            },
            resolveWorktree: { selector, cwd in
                let workspace = try await workspaces.resolveWorkspace(selector, cwd: cwd)
                return WorkerWorktreeReceipt(
                    id: workspace.id, instanceId: workspace.instanceId,
                    path: workspace.path, displayName: workspace.displayName, warning: nil,
                    hostId: workspace.hostId)
            },
            createAgentTerminal: { engineID, placement in
                // A remote placement opens its pane through the same launcher
                // `terminal create --worktree <remote id>` uses. Spawning it here with
                // the default local host would put a local PTY in a path that only
                // exists on the far side — rule 1's forbidden downgrade.
                if let host = placement.remoteHost {
                    guard let remotePanes else {
                        throw WorkspaceError(
                            "remote_unsupported",
                            "this runtime cannot open panes on \(host.rawValue)")
                    }
                    guard let path = placement.path, !path.isEmpty else {
                        throw WorkspaceError(
                            "invalid_argument",
                            "worktree \(placement.worktreeID ?? "?") has no remote path to open")
                    }
                    return try await remotePanes.create(
                        engineID: engineID, host: host,
                        workspaceID: placement.worktreeID ?? "", path: path,
                        title: placement.title)
                }
                return try await terminals.create(
                    worktreeId: placement.worktreeID, cwd: placement.path,
                    engineID: engineID, prompt: "", title: placement.title)
            },
            lookupTerminal: { handle in
                await MainActor.run { Self.resolveSummary(terminals, handle: handle) }
            },
            waitForAgentIdle: { handle, timeout in
                try await terminals.wait(handle: handle, for: .tuiIdle, timeout: timeout)
            },
            injectPrompt: { handle, text in
                try await terminals.send(handle: handle, text: text, enter: true)
            },
            interruptTerminal: { handle in
                _ = try? await terminals.send(handle: handle, interrupt: true, requireAgent: false)
            },
            readTerminal: { handle, cursor, limit in
                try await terminals.read(handle: handle, cursor: cursor, limit: limit)
            },
            resolveProviderTranscript: { handle, maximumBytes in
                // A remote pane's transcript is a file on the far side. Deciding *which*
                // pane it is has to happen on the main actor (the registry lives there);
                // reading it must not, because it is an `ssh` round trip.
                let placement = await MainActor.run {
                    Self.transcriptPlacement(terminals, handle: handle)
                }
                switch placement {
                case .local:
                    return await MainActor.run {
                        Self.resolveClaudeTranscript(terminals, handle: handle,
                                                     maximumBytes: maximumBytes)
                    }
                case .unavailable(let reason):
                    return .unavailable(reason: reason)
                case .remote(let hostId, let remoteCwd, let sessionID):
                    guard let hosts, let id = ExecutionHostId(rawValue: hostId),
                          let record = try? hosts.require(host: id) else {
                        // The pane names a host this runtime cannot resolve. Refusing is
                        // the only honest answer: there is nobody to ask.
                        return .unavailable(reason: "remote_provider_transcript_unsupported")
                    }
                    let reader = RemoteProviderTranscript(
                        host: record, runner: hostRunner,
                        connection: connections?.connection(for: record))
                    return await reader.resolve(RemoteTranscriptRequest(
                        hostName: record.name, remoteCwd: remoteCwd,
                        sessionID: sessionID, maximumBytes: maximumBytes))
                }
            },
            closeTerminal: { handle in
                try await terminals.close(handle: handle)
            },
            rollbackWorktree: { worktreeID in
                do {
                    // force: false — the workspace preflight is the safety rule. A
                    // worktree with uncommitted work, an unpushed branch, or a live
                    // process comes back `removed: false` and stays a residual.
                    let result = try await workspaces.remove(selector: worktreeID, cwd: nil,
                                                             force: false, runHooks: false)
                    guard result.removed else {
                        let detail = result.preflightWarnings.joined(separator: "; ")
                        return .retained(reason: detail.isEmpty ? "worktree_dirty"
                                                 : "worktree_dirty: \(detail)")
                    }
                    return .removed
                } catch let error as WorkspaceError {
                    return .retained(reason: error.code)
                } catch {
                    return .retained(reason: String(describing: error))
                }
            },
            probeRemoteDispatch: { hostId in
                guard let probe else {
                    return .refused(
                        code: RemoteDispatchProbe.notWired,
                        detail: "this runtime has no host registry, so it cannot ask "
                            + "\(hostId) anything")
                }
                return await probe.probe(hostId: hostId)
            })
    }

    /// Which machine a pane's provider transcript lives on, and what is needed to read
    /// it there.
    ///
    /// Split out of `resolveClaudeTranscript` so the main-actor part (identity) and the
    /// off-actor part (an `ssh` round trip) are separable. The typed reasons are the
    /// same vocabulary the local resolver uses, so a caller reading a pin cannot tell
    /// from the reason alone which machine failed to produce it — only *what* was
    /// missing, which is the fact that matters.
    enum TranscriptPlacement: Sendable, Equatable {
        case local
        case remote(hostId: String, remoteCwd: String, sessionID: String)
        case unavailable(reason: String)
    }

    @MainActor
    static func transcriptPlacement(_ terminals: TerminalService,
                                    handle: String) -> TranscriptPlacement {
        let resolvedHandle: String
        let summary: TerminalSummary
        do {
            summary = try terminals.summary(handle: handle)
            resolvedHandle = handle
        } catch TerminalServiceError.handleStale(_, let replacement) {
            guard let replacement, let followed = try? terminals.summary(handle: replacement) else {
                return .unavailable(reason: "terminal_identity_unavailable")
            }
            summary = followed
            resolvedHandle = replacement
        } catch {
            return .unavailable(reason: "terminal_identity_unavailable")
        }
        guard RemoteWorkspacePolicy.isRemote(hostId: summary.executionHostId) else {
            return .local
        }
        guard let facts = terminals.remoteFacts(handle: resolvedHandle),
              let remoteCwd = facts.remoteCwd, !remoteCwd.isEmpty else {
            // A remote pane with no recorded far-side directory cannot be resolved
            // without guessing one, and the local cwd is only where `ssh` was launched
            // from — the guess T80 refused to make.
            return .unavailable(reason: "remote_working_directory_unavailable")
        }
        guard let sessionID = try? terminals.agentStatus(handle: resolvedHandle).providerSessionID,
              !sessionID.isEmpty else {
            return .unavailable(reason: "provider_session_unavailable")
        }
        return .remote(hostId: summary.executionHostId, remoteCwd: remoteCwd,
                       sessionID: sessionID)
    }

    @MainActor
    static func resolveClaudeTranscript(
        _ terminals: TerminalService, handle: String, maximumBytes: Int,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProviderTranscriptResolution {
        let resolvedHandle: String
        let summary: TerminalSummary
        do {
            summary = try terminals.summary(handle: handle)
            resolvedHandle = handle
        } catch TerminalServiceError.handleStale(_, let replacement) {
            guard let replacement, let followed = try? terminals.summary(handle: replacement) else {
                return .unavailable(reason: "terminal_identity_unavailable")
            }
            summary = followed
            resolvedHandle = replacement
        } catch {
            return .unavailable(reason: "terminal_identity_unavailable")
        }
        // Everything below reads `~/.claude/projects` on *this* machine, and a remote
        // pane's local working directory is only where `ssh` was launched from — so
        // resolving one here would either find nothing or, worse, pin some unrelated
        // local session's transcript and label it this worker's evidence.
        //
        // T89 gave remote panes a real answer (`RemoteProviderTranscript`), and
        // `transcriptPlacement` routes them there before this is ever called. This guard
        // is the backstop for a direct caller: the local resolver must never be the one
        // that answers for another machine.
        if RemoteWorkspacePolicy.isRemote(hostId: summary.executionHostId) {
            return .unavailable(reason: "remote_provider_transcript_unsupported")
        }
        guard let sessionID = try? terminals.agentStatus(handle: resolvedHandle).providerSessionID,
              !sessionID.isEmpty else {
            return .unavailable(reason: "provider_session_unavailable")
        }
        guard sessionID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            return .unavailable(reason: "provider_session_invalid")
        }
        guard let cwd = try? terminals.workingDirectory(handle: resolvedHandle), !cwd.isEmpty else {
            return .unavailable(reason: "working_directory_unavailable")
        }
        let encodedCWD = cwd.replacingOccurrences(of: "/", with: "-")
        let url = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encodedCWD, isDirectory: true)
            .appendingPathComponent(sessionID).appendingPathExtension("jsonl")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return .unavailable(reason: "provider_transcript_not_found")
        }
        var bounded = Data(data.count > maximumBytes ? data.suffix(maximumBytes) : data[...])
        if data.count > maximumBytes, let newline = bounded.firstIndex(of: 0x0A),
           newline < bounded.index(before: bounded.endIndex) {
            bounded.removeSubrange(bounded.startIndex...newline)
        }
        guard let content = String(data: bounded, encoding: .utf8) else {
            return .unavailable(reason: "provider_transcript_invalid_utf8")
        }
        return .resolved(content: content, path: url.path, truncated: data.count > maximumBytes)
    }

    /// Handle → (summary, status), following one remint hop like the assembly's
    /// paneKey resolver: a stale handle still names its pane.
    @MainActor
    static func resolveSummary(_ terminals: TerminalService, handle: String) -> WorkerTerminalLookup {
        func lookup(_ handle: String) throws -> WorkerTerminalLookup {
            .found(summary: try terminals.summary(handle: handle),
                   status: try terminals.agentStatus(handle: handle))
        }
        do {
            return try lookup(handle)
        } catch TerminalServiceError.handleStale(_, let replacement) {
            guard let replacement, let followed = try? lookup(replacement) else { return .missing }
            return followed
        } catch {
            return .missing
        }
    }
}

/// Where `worker-start`'s `terminal_create` stage should open its pane.
///
/// Before T80 this stage took a loose (worktreeID, cwd, title) triple and always spawned
/// a local PTY. The host had to join it: a supervised worker in a remote workspace needs
/// a pane *on that host*, and `cwd` means something different there — it is the far
/// side's directory, not a path a local `chdir` may be handed.
public struct WorkerTerminalPlacement: Sendable {
    public var worktreeID: String?
    /// Locally, the pane's working directory. For a remote placement, the directory on
    /// the far side; the local PTY deliberately keeps its own cwd.
    public var path: String?
    public var title: String?
    /// The workspace's stamped execution host (`local` / `ssh:<name>`), carried verbatim
    /// so an unparseable stamp can be refused rather than read as local.
    public var hostId: String?

    public init(worktreeID: String? = nil, path: String? = nil, title: String? = nil,
                hostId: String? = nil) {
        self.worktreeID = worktreeID
        self.path = path
        self.title = title
        self.hostId = hostId
    }

    /// The host this pane belongs to, or nil when it is local. An unparseable stamp is
    /// *not* local (`RemoteWorkspacePolicy.isRemote`) but has no host to dial either, so
    /// it comes back nil here and the caller's own remote gate refuses it.
    public var remoteHost: ExecutionHostId? {
        guard let hostId, RemoteWorkspacePolicy.isRemote(hostId: hostId) else { return nil }
        return ExecutionHostId(rawValue: hostId)
    }
}

/// What worker-start asks the workspace layer to create.
public struct WorkerWorktreeSpec: Sendable {
    public var repo: String?
    public var name: String?
    public var displayName: String?
    public var baseBranch: String?
    public var runSetup: Bool?
    /// `new-child` placement: capture the enclosing worktree as lineage parent when the
    /// caller supplied a cwd; `new-top-level` severs lineage (`noParent`).
    public var newChild: Bool
    public var cwd: String?

    public init(repo: String? = nil, name: String? = nil, displayName: String? = nil,
                baseBranch: String? = nil, runSetup: Bool? = nil,
                newChild: Bool = false, cwd: String? = nil) {
        self.repo = repo
        self.name = name
        self.displayName = displayName
        self.baseBranch = baseBranch
        self.runSetup = runSetup
        self.newChild = newChild
        self.cwd = cwd
    }
}

/// The workspace facts the worker verbs need back from a create/resolve.
public struct WorkerWorktreeReceipt: Sendable {
    public var id: String
    public var instanceId: String
    public var path: String
    public var displayName: String
    public var warning: String?
    /// Which machine this workspace's files live on (`local` / `ssh:<name>`), carried
    /// so `worker-start` can refuse a supervised dispatch into a remote workspace
    /// *before* it spawns anything (T39). nil means the caller did not stamp it, and
    /// the guard treats that as local — every live path here sets it.
    public var hostId: String?

    public init(id: String, instanceId: String, path: String,
                displayName: String, warning: String? = nil, hostId: String? = nil) {
        self.id = id
        self.instanceId = instanceId
        self.path = path
        self.displayName = displayName
        self.warning = warning
        self.hostId = hostId
    }
}

/// Terminal lookup result for observation: found (with current identity + status) or
/// missing. A closed/unknown handle is `missing` — worker-show reports it as such
/// rather than guessing about the process that used to live there.
public enum WorkerTerminalLookup: Sendable {
    case found(summary: TerminalSummary, status: AgentStatusSnapshot)
    case missing
}
