import AppKit
import Combine
import DamsonTerminal
import Foundation
import OrchardCore
import OrchardTerminals

/// One opened repo: the in-process worktree + agent services, plus a merged
/// `OrchardEvent` feed. Views observe this object; they do not hold engine state.
@MainActor
final class ProjectSession: ObservableObject, Identifiable {
    let id = UUID()
    let repo: URL
    let name: String
    let worktrees: WorktreeService
    let agents: AgentSupervisor

    /// Snapshot of `worktrees.worktrees` so SwiftUI sees list mutations. Individual
    /// records still publish their own git/agent fields.
    @Published private(set) var records: [WorktreeRecord] = []
    @Published var checkoutStatus: GitWorktreeStatus = .unknown

    /// Domain events from both services land here so the store can bind tabs,
    /// unread dots, and notifications without views subscribing themselves.
    var onEvent: ((ProjectSession, OrchardEvent) -> Void)?

    init(repo: URL, settings: OrchardSettings) throws {
        self.repo = repo
        self.name = repo.lastPathComponent
        let service = WorktreeService(baseRepo: repo, worktreesRoot: settings.worktreeRoot(for: repo))
        self.worktrees = service
        self.agents = AgentSupervisor(
            configTemplate: settings.terminalConfig(),
            worktreeManager: service.manager)
        try worktrees.start()
        agents.start()
        apply(settings)
        syncRecords()
        checkoutStatus = worktrees.primaryCheckoutStatus()
        listen()
    }

    func apply(_ settings: OrchardSettings) {
        worktrees.runsSetupScripts = settings.runSetupScripts
        let prefix = settings.branchPrefixOverride.trimmingCharacters(in: .whitespaces)
        if !prefix.isEmpty { worktrees.overrideBranchPrefix(prefix) }
        let base = settings.defaultBaseRefOverride.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty { worktrees.overrideBaseRef(base) }
        agents.configTemplate = settings.terminalConfig()
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

    func refreshCheckout() async {
        checkoutStatus = worktrees.primaryCheckoutStatus()
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
        case .agentNeedsAttention(_, let worktreeID, _):
            if let worktreeID, let record = record(id: worktreeID) {
                record.hasUnseenActivity = true
            }
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
