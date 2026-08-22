import Foundation
import DamsonTerminal
import OrchardCore

/// Headless agent lifecycle: spawn an engine inside a worktree, install its lifecycle
/// hooks, watch its readiness, and retire it.
///
/// This is the agent half of v1's `OrchestratorController`, with the scheduling and app
/// glue deleted: **no task queue, no concurrency cap** (v2 has no scheduler — a
/// coordinator agent drives the loop), no theme plumbing, no UI callbacks. Consumers
/// observe `events` (an `AsyncStream<OrchardEvent>`) instead of installing closures.
///
/// The supervisor deliberately does not own worktrees — `WorktreeService` does. Spawning
/// takes a `Worktree` (or nil for a plain directory session), and the "create worktree,
/// then start an agent in it" composition belongs one level up (T4's worker-start shape).
@MainActor
public final class AgentSupervisor {
    /// Live agent sessions.
    public private(set) var agents: [AgentSession] = []

    /// Template config new agents are built from; per-agent argv/cwd/env are overlaid
    /// on a copy.
    public var configTemplate: DamsonConfig

    /// Domain-event feed (single-subscriber; see `OrchardEvent`).
    public let events: AsyncStream<OrchardEvent>
    private let eventSink: AsyncStream<OrchardEvent>.Continuation

    /// Loopback server that receives agent lifecycle hooks (Tier-1 turn detection).
    /// One per supervisor; each agent's events route back by its `hookToken`.
    private let hookServer = HookServer()

    /// Used only for `ensureExcluded` so the per-worktree hook config never shows up in
    /// the agent's own `git status`.
    private let manager: WorktreeManager

    public init(configTemplate: DamsonConfig = DamsonConfig(), worktreeManager: WorktreeManager) {
        self.configTemplate = configTemplate
        self.manager = worktreeManager
        var sink: AsyncStream<OrchardEvent>.Continuation!
        self.events = AsyncStream { sink = $0 }
        self.eventSink = sink
    }

    /// Bring up the hook server (best-effort — agents just fall back to fingerprints if
    /// it can't bind) and route each event to its agent by token, on the main actor.
    public func start() {
        _ = hookServer.start()
        hookServer.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self,
                      let agent = self.agents.first(where: { $0.hookToken == event.token })
                else { return }
                agent.applyExternalSignal(
                    agent.engine.hookSignal(event: event.event, body: event.body))
            }
        }
    }

    // MARK: - Spawn

    /// Start an engine process inside `worktree` (or a bare directory when nil) and
    /// register the session. A non-empty `prompt` is delivered exactly once, on the
    /// engine's first idle (for `.typeWhenIdle` engines) or via argv (`.launchArgument`).
    @discardableResult
    public func spawnAgent(engineID: String, prompt: String = "",
                           in worktree: Worktree?, title: String? = nil) throws -> AgentSession {
        guard let engine = AgentEngineRegistry.engine(id: engineID) else {
            throw GitError("unknown engine: \(engineID)")
        }
        let task = AgentTask(
            title: title ?? worktree?.title ?? engine.displayName,
            prompt: prompt,
            engineID: engineID,
            baseRepoPath: worktree?.baseRepo.path ?? "")

        var config = configTemplate
        config.cwd = worktree?.path.path ?? config.cwd
        config.argv = EngineLaunch.argv(engine: engine, task: task,
                                        worktree: worktree?.path ?? URL(fileURLWithPath: config.cwd ?? "/"))
        // Let the engine shape the child environment. Without this an agent inherits
        // whatever launched Orchard — including, when Orchard is started from inside
        // another agent's session, that session's markers, which silently change how the
        // child behaves (Claude Code disables transcript saving when it thinks it's a
        // subprocess).
        config.env = engine.env(base: config.env)

        let terminal = DamsonTerminalSession(config: config)
        let agent = AgentSession(engine: engine, terminal: terminal, worktree: worktree, task: task)
        agent.onStateChange = { [weak self, weak agent] state in
            guard let self, let agent else { return }
            self.agentStateChanged(agent, state: state)
        }

        // Tier-1 hooks: give this agent a per-worktree hook config so its CLI POSTs
        // lifecycle events to our loopback server. Best-effort — a write failure or a
        // CLI without hook support just means we lean on fingerprints for this agent.
        if let worktree, let events = engine.hookEvents, hookServer.port != 0 {
            manager.ensureExcluded(".claude/settings.local.json", in: worktree.path)
            HookInstaller.install(worktree: worktree.path, port: hookServer.port,
                                  token: agent.hookToken, events: events)
        }

        agents.append(agent)
        eventSink.yield(.agentSpawned(agentID: agent.id, worktreeID: worktree?.id,
                                      engineID: engineID))
        return agent
    }

    // MARK: - Agent state reactions

    private func agentStateChanged(_ agent: AgentSession, state: AgentRuntimeState) {
        eventSink.yield(.agentStateChanged(agentID: agent.id, worktreeID: agent.worktree?.id,
                                           state: state))
        switch state {
        case .idle:
            // Deliver the task prompt exactly once, on the first idle after spawn. Skip
            // interactive agents (empty prompt). Claude Code returns to idle after every
            // turn, so the once-guard stops the prompt being re-typed on each completion.
            if let task = agent.task,
               !task.prompt.isEmpty,
               agent.engine.promptDelivery == .typeWhenIdle,
               !agent.hasDeliveredInitialPrompt {
                agent.deliverPrompt(task.prompt)
            } else if agent.hasDeliveredInitialPrompt {
                // A turn just completed — the diff changed, and the user may be elsewhere.
                eventSink.yield(.agentNeedsAttention(agentID: agent.id,
                                                     worktreeID: agent.worktree?.id,
                                                     state: state))
            }
        case .awaitingApproval, .awaitingInput, .finished, .errored:
            eventSink.yield(.agentNeedsAttention(agentID: agent.id,
                                                 worktreeID: agent.worktree?.id,
                                                 state: state))
        default:
            break
        }
    }

    // MARK: - Teardown

    /// Stop an agent and drop it from the live list. The worktree it ran in is untouched:
    /// dismissing an agent is about clearing the session, not discarding the work.
    public func retire(_ agent: AgentSession) {
        agent.terminate()
        agents.removeAll { $0.id == agent.id }
        eventSink.yield(.agentRetired(agentID: agent.id, worktreeID: agent.worktree?.id))
    }

    /// Stop every agent whose session lives in `worktreeID` — the precondition for
    /// deleting that worktree (git can't remove a directory a live process sits in).
    public func retireAgents(inWorktree worktreeID: UUID) {
        for agent in agents.filter({ $0.worktree?.id == worktreeID }) {
            retire(agent)
        }
    }

    /// Tear down everything (window closed / app quit). Agents are stopped; their
    /// worktrees are somebody else's to keep or delete.
    public func shutdown() {
        for agent in agents {
            agent.terminate()
            eventSink.yield(.agentRetired(agentID: agent.id, worktreeID: agent.worktree?.id))
        }
        agents.removeAll()
        hookServer.stop()
        eventSink.finish()
    }
}
