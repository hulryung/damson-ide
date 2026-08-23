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

    public static let transcriptPinByteLimit = 2_000_000
    public var cliCommand: String

    /// `worktree_create`: run the worker-start-shaped composition (T4's helper) without
    /// an agent — the terminal is spawned as its own stage so failures attribute.
    public var createWorktree: @Sendable (WorkerWorktreeSpec) async throws -> WorkerWorktreeReceipt
    /// Resolve an existing workspace placement selector (`current` needs `cwd`).
    public var resolveWorktree: @Sendable (_ selector: String, _ cwd: String?) async throws -> WorkerWorktreeReceipt
    /// `terminal_create`: spawn an agent terminal in a worktree via T3's registry.
    public var createAgentTerminal: @Sendable (
        _ engineID: String, _ worktreeID: String?, _ cwd: String?, _ title: String?
    ) async throws -> TerminalSummary
    /// Observation: current summary + agent status for a handle, following one remint
    /// hop (a stale handle still names its pane; authority keys on the pane).
    public var lookupTerminal: @Sendable (_ handle: String) async -> WorkerTerminalLookup
    /// `agent_readiness`: `terminal wait --for tui-idle` (permission never satisfies).
    public var waitForAgentIdle: @Sendable (
        _ handle: String, _ timeout: TimeInterval
    ) async throws -> TerminalWaitResult
    /// `dispatch_input`: the verified injection pipeline (typed refusals preserved).
    public var injectPrompt: @Sendable (_ handle: String, _ text: String) async throws -> TerminalSendResult
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

    public init(
        cliCommand: String = "orchard",
        createWorktree: @escaping @Sendable (WorkerWorktreeSpec) async throws -> WorkerWorktreeReceipt,
        resolveWorktree: @escaping @Sendable (String, String?) async throws -> WorkerWorktreeReceipt,
        createAgentTerminal: @escaping @Sendable (String, String?, String?, String?) async throws -> TerminalSummary,
        lookupTerminal: @escaping @Sendable (String) async -> WorkerTerminalLookup,
        waitForAgentIdle: @escaping @Sendable (String, TimeInterval) async throws -> TerminalWaitResult,
        injectPrompt: @escaping @Sendable (String, String) async throws -> TerminalSendResult,
        readTerminal: @escaping @Sendable (String, Int?, Int) async throws -> TerminalReadResult,
        resolveProviderTranscript: @escaping @Sendable (String, Int) async -> ProviderTranscriptResolution = { _, _ in .unavailable(reason: "provider_session_unavailable") },
        closeTerminal: @escaping @Sendable (String) async throws -> Void
    ) {
        self.cliCommand = cliCommand
        self.createWorktree = createWorktree
        self.resolveWorktree = resolveWorktree
        self.createAgentTerminal = createAgentTerminal
        self.lookupTerminal = lookupTerminal
        self.waitForAgentIdle = waitForAgentIdle
        self.injectPrompt = injectPrompt
        self.readTerminal = readTerminal
        self.resolveProviderTranscript = resolveProviderTranscript
        self.closeTerminal = closeTerminal
    }

    /// The production wiring against the runtime host's services.
    public static func live(cliCommand: String,
                            workspaces: WorkspaceService,
                            terminals: TerminalService) -> WorkerRuntimeContext {
        WorkerRuntimeContext(
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
                    warning: result.warning)
            },
            resolveWorktree: { selector, cwd in
                let workspace = try await workspaces.resolveWorkspace(selector, cwd: cwd)
                return WorkerWorktreeReceipt(
                    id: workspace.id, instanceId: workspace.instanceId,
                    path: workspace.path, displayName: workspace.displayName, warning: nil)
            },
            createAgentTerminal: { engineID, worktreeID, cwd, title in
                try await terminals.create(worktreeId: worktreeID, cwd: cwd,
                                           engineID: engineID, prompt: "", title: title)
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
            readTerminal: { handle, cursor, limit in
                try await terminals.read(handle: handle, cursor: cursor, limit: limit)
            },
            resolveProviderTranscript: { handle, maximumBytes in
                await MainActor.run {
                    Self.resolveClaudeTranscript(terminals, handle: handle,
                                                 maximumBytes: maximumBytes)
                }
            },
            closeTerminal: { handle in
                try await terminals.close(handle: handle)
            })
    }

    @MainActor
    static func resolveClaudeTranscript(
        _ terminals: TerminalService, handle: String, maximumBytes: Int,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProviderTranscriptResolution {
        let resolvedHandle: String
        do {
            _ = try terminals.summary(handle: handle)
            resolvedHandle = handle
        } catch TerminalServiceError.handleStale(_, let replacement) {
            guard let replacement else { return .unavailable(reason: "terminal_identity_unavailable") }
            resolvedHandle = replacement
        } catch {
            return .unavailable(reason: "terminal_identity_unavailable")
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

    public init(id: String, instanceId: String, path: String,
                displayName: String, warning: String? = nil) {
        self.id = id
        self.instanceId = instanceId
        self.path = path
        self.displayName = displayName
        self.warning = warning
    }
}

/// Terminal lookup result for observation: found (with current identity + status) or
/// missing. A closed/unknown handle is `missing` — worker-show reports it as such
/// rather than guessing about the process that used to live there.
public enum WorkerTerminalLookup: Sendable {
    case found(summary: TerminalSummary, status: AgentStatusSnapshot)
    case missing
}
