import AppKit
import Combine
import DamsonTerminal
import Foundation
import OrchardCore
import OrchardRuntime
import OrchardTerminals

/// One opened repo: the in-process worktree + agent services, plus a merged
/// `OrchardEvent` feed. Views observe this object; they do not hold engine state.
///
/// Project identity comes from the runtime repo registry (`RepoRecord` path +
/// id). `id` stays a per-process SwiftUI identity; worktree restore and agent
/// lifecycle are unchanged.
///
/// A remote repo (`hostId` other than `local`) has no checkout on this machine.
/// Local `WorktreeService.start()` is skipped so a same-named local directory
/// cannot answer for files that live on the host (T32 / T37).
@MainActor
final class ProjectSession: ObservableObject, Identifiable {
    let id = UUID()
    let repo: URL
    let name: String
    let worktrees: WorktreeService
    let agents: AgentSupervisor
    /// Registry id for this repo. Worktree identities (`<repoId>::<path>`) hang off it.
    var repoID: String?
    /// Stamped at open from `RepoRecord.hostId`. Never inferred afterwards.
    let hostId: String

    /// Snapshot of `worktrees.worktrees` so SwiftUI sees list mutations. Individual
    /// records still publish their own git/agent fields.
    @Published private(set) var records: [WorktreeRecord] = []
    @Published var checkoutStatus: GitWorktreeStatus = .unknown

    /// Domain events from both services land here so the store can bind tabs,
    /// unread dots, and notifications without views subscribing themselves.
    var onEvent: ((ProjectSession, OrchardEvent) -> Void)?

    /// `preferredHookPort` (T23): the previous app generation's hook-server port for
    /// this repo, so keeper-restored agents' installed hook configs keep working.
    init(repo: URL, settings: OrchardSettings, repoID: String? = nil,
         displayName: String? = nil, preferredHookPort: UInt16? = nil,
         hostId: String = ExecutionHostId.local.rawValue) throws {
        self.repo = repo
        self.repoID = repoID
        self.hostId = hostId
        if let displayName, !displayName.isEmpty {
            self.name = displayName
        } else {
            self.name = repo.lastPathComponent
        }
        let service = WorktreeService(baseRepo: repo, worktreesRoot: settings.worktreeRoot(for: repo))
        self.worktrees = service
        self.agents = AgentSupervisor(
            configTemplate: settings.terminalConfig(),
            worktreeManager: service.manager)
        agents.preferredHookPort = preferredHookPort
        // A remote path is not a local checkout. Starting the local git stack
        // against it would either fail or — the T32 hazard — succeed against a
        // same-named directory on this machine.
        if !isRemote {
            try worktrees.start()
        }
        agents.start()
        apply(settings)
        if !isRemote {
            syncRecords()
            // Off the critical path: opening a project must not wait on a git read to
            // put its window up. The status arrives a moment later and the row updates.
            Task { [weak self] in await self?.refreshCheckout() }
        }
        listen()
    }

    var isRemote: Bool { RemoteWorkspacePolicy.isRemote(hostId: hostId) }

    var hostLabel: String? {
        guard isRemote else { return nil }
        return RemoteWorkspacePolicy.hostLabel(hostId)
    }

    /// Directory leaves already in the sidebar, so the composer can uniquify
    /// remotely the same way `WorktreeService.takenNames` does locally.
    var composerTakenNames: Set<String> {
        if isRemote { return Set(records.map { $0.path.lastPathComponent }) }
        return worktrees.takenNames
    }

    func composerSuggestedName() -> String {
        WorktreeNaming.suggestName(taken: composerTakenNames)
    }

    /// Sidebar / header subtitle. Remote repos never ask local git for a branch.
    var rootSubtitle: String {
        if isRemote { return hostLabel ?? "remote" }
        guard worktrees.isGitRepository else { return "folder" }
        return worktrees.currentBranchName ?? "detached"
    }

    func apply(_ settings: OrchardSettings) {
        worktrees.runsSetupScripts = settings.runSetupScripts
        guard !isRemote else {
            agents.configTemplate = settings.terminalConfig()
            return
        }
        let prefix = settings.branchPrefixOverride.trimmingCharacters(in: .whitespaces)
        if !prefix.isEmpty { worktrees.overrideBranchPrefix(prefix) }
        let base = settings.defaultBaseRefOverride.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty { worktrees.overrideBaseRef(base) }
        agents.configTemplate = settings.terminalConfig()
    }

    /// Replace the card list with the last-known remote worktrees. Primary
    /// checkout stays on `ProjectRootRow`; only extra worktrees become cards.
    func applyRemoteWorkspaces(_ workspaces: [Workspace], repo: RepoRecord) {
        let existing = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var next: [WorktreeRecord] = []
        for workspace in workspaces where !Self.isPrimary(workspace, repo: repo) {
            let id = UUID(uuidString: workspace.instanceId) ?? UUID()
            if let found = existing[id],
               found.worktree.path.path == workspace.path,
               found.worktree.branch == workspace.branch {
                found.meta.displayName = workspace.displayName
                next.append(found)
                continue
            }
            let wt = Worktree(
                id: id,
                baseRepo: URL(fileURLWithPath: repo.path),
                path: URL(fileURLWithPath: workspace.path),
                branch: workspace.branch,
                baseRef: workspace.baseRef,
                title: workspace.displayName)
            var meta = WorktreeMeta.defaults(for: wt)
            meta.displayName = workspace.displayName
            meta.workspaceStatus = workspace.workspaceStatus
            meta.isArchived = workspace.isArchived
            meta.sortOrder = workspace.sortOrder
            next.append(WorktreeRecord(worktree: wt, manager: worktrees.manager, meta: meta))
        }
        records = next
        objectWillChange.send()
    }

    static func isPrimary(_ workspace: Workspace, repo: RepoRecord) -> Bool {
        workspace.path == repo.path
            || workspace.id.caseInsensitiveCompare(
                WorktreeIdentity.make(repoId: repo.id, path: repo.path)) == .orderedSame
    }

    func syncRecords() {
        records = worktrees.worktrees
        objectWillChange.send()
    }

    func liveAgents(in worktreeID: UUID) -> [AgentSession] {
        agents.agents.filter { $0.worktree?.id == worktreeID }
    }

    func record(id: UUID) -> WorktreeRecord? {
        records.first { $0.id == id } ?? worktrees.worktrees.first { $0.id == id }
    }

    /// Re-read the primary checkout's git status off the main actor.
    ///
    /// `primaryCheckoutStatus()` shells out to git. Awaiting it on the main actor — which
    /// is what this used to do, `async` notwithstanding — froze the workbench for the
    /// length of the read every time a project root was selected. The pane is drawn from
    /// whatever status is already published; this replaces it when the answer lands.
    func refreshCheckout() async {
        guard !isRemote else { return }
        let traceStart = DispatchTime.now().uptimeNanoseconds
        checkoutStatus = await worktrees.primaryCheckoutStatus()
        if AppStore.traceSwitch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - traceStart) / 1_000_000
            NSLog("ORCHARD_TRACE refreshCheckout %.1f ms", ms)
        }
    }

    func applyTerminalConfig(_ config: DamsonConfig) {
        agents.configTemplate = config
        for agent in agents.agents {
            guard let session = (agent.terminal as? DamsonTerminalSession)?.session else { continue }
            var updated = session.config
            updated.theme = config.theme
            updated.fontSize = config.fontSize
            updated.fontFamily = config.fontFamily
            session.updateConfig(updated)
        }
    }

    func shutdown() {
        agents.shutdown()
        worktrees.shutdown(removeWorktrees: false)
    }

    /// Recompute `record.agentState` from live sessions so the card row stays
    /// truthful when several agents share one worktree.
    func mirrorAgentState(for worktreeID: UUID?) {
        guard let worktreeID, let record = record(id: worktreeID) else { return }
        let live = liveAgents(in: worktreeID)
        record.agentState = Self.priorityState(live.map(\.state))
    }

    private static func priorityState(_ states: [AgentRuntimeState]) -> AgentRuntimeState? {
        guard !states.isEmpty else { return nil }
        func rank(_ state: AgentRuntimeState) -> Int {
            switch state {
            case .awaitingApproval: return 60
            case .awaitingInput: return 50
            case .working: return 40
            case .starting: return 30
            case .idle: return 20
            case .errored: return 10
            case .finished: return 5
            }
        }
        return states.max(by: { rank($0) < rank($1) })
    }

    private func listen() {
        let worktreeEvents = worktrees.events
        let agentEvents = agents.events
        Task { [weak self] in
            for await event in worktreeEvents {
                self?.handle(event)
            }
        }
        Task { [weak self] in
            for await event in agentEvents {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: OrchardEvent) {
        switch event {
        case .worktreeCreated, .worktreeRemoved, .worktreesRestored:
            syncRecords()
        case .setupStateChanged:
            objectWillChange.send()
        case .agentSpawned(_, let worktreeID, _):
            mirrorAgentState(for: worktreeID)
            objectWillChange.send()
        case .agentStateChanged(_, let worktreeID, _):
            mirrorAgentState(for: worktreeID)
            objectWillChange.send()
        case .agentNeedsAttention:
            // Unread is folded in AppStore (single source). Cards and the
            // dashboard both read that state — do not set per-record flags here.
            objectWillChange.send()
        case .agentRetired(_, let worktreeID):
            mirrorAgentState(for: worktreeID)
            objectWillChange.send()
        case .serviceError(let message):
            NSLog("orchard: %@", message)
        }
        onEvent?(self, event)
    }
}
