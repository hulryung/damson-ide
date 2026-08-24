import Foundation
import DamsonTerminal
import OrchardCore

/// The terminal domain service behind the `terminal *` RPC verbs: creation, listing,
/// two-source reads, verified sends, tui-idle/exit waits, per-terminal agent-status
/// streams, close and rename. UI-free; the app and the runtime server both drive it.
///
/// Concurrency shape: the whole service lives on the main actor with the sessions and
/// detectors it composes. Long operations (`send`, `wait`) suspend, never block; sends
/// are additionally serialized per PTY through each record's `SerialGate`.
@MainActor
public final class TerminalService {
    private let registry: TerminalRegistry
    private let factory: TerminalSessionFactory
    private let pipeline: SendPipelineConfig
    private let detectorConfig: ReadinessDetector.Config

    /// Default `terminal wait` timeout (the "default timeout enforced" rule — a wait
    /// with no bound would hang a coordinator forever on a wedged agent).
    public static let defaultWaitTimeout: TimeInterval = 60

    /// T11 additive hook: fired at most once per pane incarnation when its PTY ends —
    /// `deliberate: true` for a close through this service (user close, coordinator
    /// worker-stop/release), `deliberate: false` when the child exited on its own.
    /// The runtime assembly points this at worker-process-exit auto-escalation.
    public var onTerminalExit: ((TerminalExitEvent) -> Void)?

    /// T39 additive seam: the local end of the Tier-1 hook channel. When installed,
    /// panes created with `statusDetection: .hooks` subscribe their token to it, which
    /// is how a *remote* agent's lifecycle POSTs — arriving through an SSH reverse
    /// tunnel — reach the pane that owns them. nil (the default) is exactly today's
    /// behaviour: service-created agent panes lean on fingerprints.
    public var hookChannel: AgentHookChannel?

    public init(registry: TerminalRegistry = TerminalRegistry(),
                factory: @escaping TerminalSessionFactory,
                pipeline: SendPipelineConfig = SendPipelineConfig(),
                detectorConfig: ReadinessDetector.Config = ReadinessDetector.Config()) {
        self.registry = registry
        self.factory = factory
        self.pipeline = pipeline
        self.detectorConfig = detectorConfig
    }

    // MARK: - Create / list / close / rename

    /// `initialCols`/`initialRows` let a caller that knows its pane geometry spawn the
    /// PTY at that size; nil defers to the factory's default. Test factories ignore them.
    @discardableResult
    public func create(worktreeId: String? = nil, cwd: String? = nil,
                       engineID: String = "shell", prompt: String = "",
                       title: String? = nil, executionHostId: String = "local",
                       initialCols: Int? = nil, initialRows: Int? = nil,
                       launchArgv: [String]? = nil, hookToken: String? = nil,
                       statusDetection: TerminalStatusDetection? = nil,
                       remoteCwd: String? = nil) throws -> TerminalSummary {
        guard let engine = AgentEngineRegistry.engine(id: engineID) else {
            throw TerminalServiceError.unknownEngine(engineID)
        }
        // Persist the canonical id, never the alias the caller typed: everything
        // downstream (restoration, dashboards, `worker-show`) keys on `engine.id`.
        let spec = TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(),
            paneKey: TerminalRegistry.mintPaneKey(),
            worktreeId: worktreeId,
            cwd: cwd,
            engineID: engine.id,
            prompt: prompt,
            title: title,
            executionHostId: executionHostId,
            initialCols: initialCols,
            initialRows: initialRows,
            launchArgv: launchArgv,
            hookToken: hookToken,
            statusDetection: statusDetection,
            remoteCwd: remoteCwd)
        let record = try spawn(spec: spec, engine: engine)
        registry.register(record)
        record.tracker.lastPrompt = prompt
        attachHookChannel(record)
        return record.summary()
    }

    /// Route this pane's lifecycle hooks into its session, when a channel is installed
    /// and the pane's config actually points at it.
    ///
    /// Only panes whose `statusDetection` says `hooks` subscribe: a pane that degraded
    /// to fingerprints has no config on the far side POSTing anything, and registering
    /// its token anyway would leave a listener that can only ever be fed by somebody
    /// else's guess at the token.
    private func attachHookChannel(_ record: TerminalRecord) {
        guard let channel = hookChannel,
              record.spec.statusDetection?.mode == .hooks else { return }
        let session = record.agentSession
        channel.register(token: session.hookToken) { [weak session] event, body in
            Task { @MainActor in
                guard let session else { return }
                // Chat fields first: a Stop body carries last_assistant_message and must
                // land on the tracker before the idle transition reads it.
                session.applyHookFields(HookStatusFields.parse(json: body))
                session.applyExternalSignal(
                    session.engine.hookSignal(event: event, body: body))
            }
        }
    }

    public func list(worktreeId: String? = nil) -> [TerminalSummary] {
        registry.list(worktreeId: worktreeId).map { $0.summary() }
    }

    /// The current summary for one handle (additive read for the worker verbs: they
    /// need `paneKey`/`incarnation`/`connected` in one lookup, with the registry's
    /// typed stale/not-found split preserved).
    public func summary(handle: String) throws -> TerminalSummary {
        try registry.resolve(handle).summary()
    }

    /// The current summary for a durable pane key, or nil when no pane has it.
    ///
    /// A handle is minted per app run, so after a restart the pane key is the only name
    /// a caller (or a restored tab) still holds — and it is the identity a reconnect
    /// has to address, since the whole point is that the pane outlived its handle.
    public func summary(paneKey: String) -> TerminalSummary? {
        registry.record(forPaneKey: paneKey)?.summary()
    }

    /// The live Damson surface behind a handle, when the record is a real PTY.
    /// App panes render this; scripted/test sessions return nil.
    public func damsonSession(handle: String) -> DamsonSession? {
        ((try? registry.resolve(handle))?.session as? DamsonTerminalSession)?.session
    }

    /// Keeper-restored (or service-created) local shell for this worktree that
    /// isn't a supervisor-bound agent. Home-shell tabs re-attach here after
    /// relaunch; agent panes bind through `agentID` instead.
    public func adoptedShellDamsonSession(worktreeId: String) -> DamsonSession? {
        for record in registry.list(worktreeId: worktreeId) where record.connected {
            guard record.engine.id == "shell",
                  !record.engine.usesLongRunningTUI,
                  record.agentSession.worktree == nil else { continue }
            return (record.session as? DamsonTerminalSession)?.session
        }
        return nil
    }

    /// Adopt an externally spawned agent session (an `AgentSupervisor` PTY) under the
    /// identity that was injected into its environment. The pane then behaves like any
    /// service-created terminal: the handle resolves, remints, and answers stale; reads,
    /// verified sends, waits, and status streams all apply.
    ///
    /// The supervisor keeps ownership of prompt delivery and its own event feed — the
    /// record's spec carries no prompt, and the existing `onStateChange` is chained,
    /// not replaced.
    @discardableResult
    public func adopt(agentSession: AgentSession, spec: TerminalCreateSpec) throws -> TerminalSummary {
        guard registry.record(forPaneKey: spec.paneKey) == nil else {
            throw TerminalServiceError.invalidArgument(
                "pane '\(spec.paneKey)' is already registered")
        }
        let record = TerminalRecord(handle: spec.handle, spec: spec,
                                    engine: agentSession.engine,
                                    session: agentSession.terminal,
                                    agentSession: agentSession)
        record.initialPromptStarted = true
        registry.register(record)
        let upstream = agentSession.onStateChange
        agentSession.onStateChange = { [weak self, weak record] state in
            upstream?(state)
            guard let self, let record else { return }
            self.stateChanged(record, state: state)
        }
        attachHookFields(record)
        // Seed the tracker so an already-idle agent fast-paths `wait --for tui-idle`
        // and the chat projector sees the task prompt without a grid scrape.
        if let prompt = agentSession.task?.prompt, !prompt.isEmpty {
            record.tracker.lastPrompt = prompt
        }
        record.tracker.note(agentSession.state)
        return record.summary()
    }

    public func close(handle: String) throws {
        let record = try registry.resolve(handle)
        if !record.exited {
            record.session.terminate()
        }
        record.exited = true
        // A deliberate close settles every outstanding wait: exit waiters resolve,
        // tui-idle waiters reject (the pane can never reach idle again).
        settleWaiters(record, exitCode: record.exitCode ?? record.session.exitCode)
        for continuation in record.statusContinuations.values { continuation.finish() }
        record.statusContinuations.removeAll()
        registry.unregister(record)
        notifyExit(record, deliberate: true)
    }

    @discardableResult
    public func rename(handle: String, title: String?) throws -> TerminalSummary {
        let record = try registry.resolve(handle)
        record.title = title
        return record.summary()
    }

    /// Re-issue a pane's handle (registry-level identity churn; the process is
    /// untouched). Returns the new summary; the old handle answers stale.
    @discardableResult
    public func remintHandle(paneKey: String) throws -> TerminalSummary {
        try registry.remintHandle(paneKey: paneKey).summary()
    }

    /// Spawn a fresh PTY into an existing pane (respawn): new handle, incremented
    /// incarnation, continuous stream buffer. The old handle answers stale.
    @discardableResult
    public func respawn(paneKey: String) throws -> TerminalSummary {
        guard let record = registry.record(forPaneKey: paneKey) else {
            throw TerminalServiceError.notFound(handle: paneKey)
        }
        // The pane kept its geometry — only the process is being replaced — so the new
        // PTY spawns at the outgoing session's current grid size, not the create-time one.
        let grid = record.session.gridSnapshot()
        // A remote pane keeps its launch command: for `ssh:<host>` panes the prompt IS
        // the `ssh` invocation, so dropping it would respawn the pane as a *local*
        // shell — silently relocating the work, the one failure the host rules forbid.
        let respawnPrompt = record.spec.isRemote ? record.spec.prompt : ""
        let spec = TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(), paneKey: record.paneKey,
            worktreeId: record.worktreeId,
            cwd: record.spec.cwd, engineID: record.engine.id, prompt: respawnPrompt,
            title: record.title, executionHostId: record.spec.executionHostId,
            initialCols: grid.cols, initialRows: grid.rows,
            // Same reason the prompt survives: a remote agent pane's argv IS the `ssh`
            // invocation (tunnel included), and its hook token is already written into
            // a config file on the far side. Reminting either would respawn the pane
            // as a different, statusless agent.
            launchArgv: record.spec.launchArgv, hookToken: record.spec.hookToken,
            statusDetection: record.spec.statusDetection,
            remoteCwd: record.spec.remoteCwd)
        return try relaunch(record: record, spec: spec)
    }

    /// Put a new PTY under an existing pane: spawn, retire the old handle, swap the
    /// session in, and re-establish everything that was bound to the old one.
    ///
    /// Shared by `respawn` (same spec, new process) and `reconnectRemote` (a spec whose
    /// tunnel has been re-pointed at this app instance's hook port), so the two cannot
    /// drift on the parts that are easy to get wrong: the spawn happens *first*, so a
    /// factory failure leaves the current incarnation intact with its handle still
    /// live, and the hook subscription is re-registered, because the token survives but
    /// the session it routed to does not.
    private func relaunch(record: TerminalRecord,
                          spec: TerminalCreateSpec) throws -> TerminalSummary {
        let session = try makeSession(spec: spec, engine: record.engine)
        if !record.exited && !record.session.processExited {
            record.session.terminate()
        }
        settleWaiters(record, exitCode: record.session.exitCode)
        registry.retireHandle(record.handle, paneKey: record.paneKey)
        let agentSession = makeAgentSession(spec: spec, engine: record.engine, session: session)
        record.adopt(handle: spec.handle, session: session, agentSession: agentSession,
                     spec: spec)
        registry.register(record)
        wireStateChanges(record)
        // Re-subscribe: the pane kept its hook token (the far side's config still names
        // it), but the session that token routed to has just been replaced. The stale
        // handler holds a dead session weakly and would silently swallow every event.
        attachHookChannel(record)
        return record.summary()
    }

    // MARK: - Restart survival (T23 keeper handoff / adoption)

    /// Quit side: release every live registered PTY for keeper handoff. For each pane
    /// that can survive (its session yields a real PTY handoff), the restoration
    /// record is captured — preamble and grid geometry BEFORE release, because both
    /// read live session state — and returned alongside the released master.
    ///
    /// Panes whose child already exited are skipped (nothing to keep alive), as are
    /// sessions that refuse release (test fakes, non-PTY backends). The caller owns
    /// the returned fds: hand them to the keeper or close them (the children then get
    /// SIGHUP, exactly a normal quit).
    public func releaseForKeeperHandoff() -> [KeeperReleasedPane] {
        var out: [KeeperReleasedPane] = []
        for record in registry.list() where record.connected {
            let preamble = record.session.keeperRestorationPreamble()
            let grid = record.session.gridSnapshot()
            guard let handoff = record.session.releaseForKeeperHandoff() else { continue }
            let pane = KeeperPaneRecord(
                keeperUUID: UUID().uuidString,
                paneKey: record.paneKey,
                incarnation: record.incarnation,
                worktreeId: record.worktreeId,
                engineID: record.engine.id,
                title: record.title,
                cwd: handoff.cwd ?? record.spec.cwd,
                argv: KeeperRestartArgv.stripped(record.session.config.argv),
                preambleBase64: preamble.base64EncodedString(),
                cols: grid.cols, rows: grid.rows,
                hookToken: record.agentSession.hookToken,
                repoPath: record.agentSession.worktree?.baseRepo.path,
                worktreePath: record.agentSession.worktree?.path.path,
                remote: remoteRecord(for: record))
            out.append(KeeperReleasedPane(paneRecord: pane, handoff: handoff))
        }
        return out
    }

    /// The remote half of a restoration record, or nil for a local pane (T43).
    ///
    /// Every field here is something the next app instance cannot recover from the fd
    /// it inherits: which machine the work is on, which directory on it, the exact
    /// invocation that would reopen the connection, and the two port numbers the hook
    /// channel runs between. A remote pane adopted without them comes back stamped
    /// `local` — a pane claiming to be here while its child talks to another machine.
    private func remoteRecord(for record: TerminalRecord) -> KeeperRemotePaneRecord? {
        guard record.spec.isRemote else { return nil }
        return KeeperRemotePaneRecord(
            executionHostId: record.spec.executionHostId,
            remoteCwd: record.spec.remoteCwd,
            // Only a pane that was CREATED from an argv records one (a T39 remote agent
            // pane's `ssh -tt -R …`). Substituting the PTY's spawned argv for a
            // prompt-launched pane would restore it through a different mechanism than
            // it was created with — and it is recorded verbatim, never through the
            // restart stripper, whose Claude-flag surgery is meant for a *local*
            // command line, not for a quoted argument bound for another machine.
            launchArgv: record.spec.launchArgv,
            // The `shell` engine launches from its prompt, so a remote shell pane's
            // command line is the only thing that reopens it as a remote shell.
            launchPrompt: record.spec.prompt.isEmpty ? nil : record.spec.prompt,
            tunnel: tunnelRecord(for: record),
            statusDetection: record.spec.statusDetection)
    }

    /// The reverse tunnel this pane's hooks travel through, when it has one.
    ///
    /// The remote port comes from the pane's recorded detection (it is the port named
    /// by the config already written on the far side); the local port is read from the
    /// live hook channel, because that is the number the surviving `ssh` will still be
    /// forwarding to after we are gone. Read only for a pane that actually has hooks —
    /// the channel binds lazily, and a quit is no time to start a listening socket for
    /// a pane that never used one.
    private func tunnelRecord(for record: TerminalRecord) -> KeeperTunnelRecord? {
        guard let detection = record.spec.statusDetection, detection.mode == .hooks,
              let remotePort = detection.tunnelPort, remotePort > 0,
              let localPort = hookChannel?.localHookPort, localPort != 0 else { return nil }
        return KeeperTunnelRecord(remotePort: UInt16(remotePort), localPort: localPort)
    }

    /// Boot side: adopt a pane that survived the previous app instance back into the
    /// registry under the SAME `paneKey` with a bumped incarnation and a fresh handle.
    ///
    /// `agentSession` lets the app pass a supervisor-built session (worktree binding,
    /// restored hook token) whose observers are chained rather than replaced — the
    /// same contract as `adopt(agentSession:spec:)`; nil builds a service-owned one.
    /// Either way the initial task prompt is marked delivered: it belongs to
    /// incarnation 1 of a previous app run, never to a restored pane.
    @discardableResult
    public func adoptKeeperRestored(pane: KeeperPaneRecord, session: TerminalSession,
                                    agentSession: AgentSession? = nil) throws -> TerminalSummary {
        guard registry.record(forPaneKey: pane.paneKey) == nil else {
            throw TerminalServiceError.invalidArgument(
                "pane '\(pane.paneKey)' is already registered")
        }
        guard let engine = AgentEngineRegistry.engine(id: pane.engineID) else {
            throw TerminalServiceError.unknownEngine(pane.engineID)
        }
        let spec = restoredSpec(pane: pane, handle: TerminalRegistry.mintHandle())
        let agent = agentSession ?? makeAgentSession(spec: spec, engine: engine,
                                                     session: session)
        agent.terminalHandle = spec.handle
        agent.paneKey = spec.paneKey
        let record = TerminalRecord(handle: spec.handle, spec: spec, engine: engine,
                                    session: session, agentSession: agent,
                                    incarnation: pane.incarnation + 1)
        record.initialPromptStarted = true
        registry.register(record)
        if agentSession != nil {
            let upstream = agent.onStateChange
            agent.onStateChange = { [weak self, weak record] state in
                upstream?(state)
                guard let self, let record else { return }
                self.stateChanged(record, state: state)
            }
            attachHookFields(record)
        } else {
            wireStateChanges(record)
        }
        // Re-subscribe the pane's hook token to this app instance's channel. Only a
        // pane whose restored detection says `hooks` subscribes, so this is a no-op
        // for local panes (whose hooks route through their project's own supervisor)
        // and for a remote pane that just degraded — but for one whose tunnel was
        // rebound it is the whole point: the far side's config still names this token,
        // and without the subscription the rebind would deliver into nothing.
        attachHookChannel(record)
        // Same seeds a fresh `adopt(agentSession:spec:)` / `create` get: the
        // restored task prompt (empty for a keeper-restored Claude pane — it
        // must not be re-typed), the fused state so `wait --for tui-idle`
        // fast-paths, and the activity clock. Replay bytes land asynchronously
        // *after* `TerminalRecord.attach`, so without this seed a restored pane
        // looks like it has never produced output until the next live chunk.
        if let prompt = agent.task?.prompt, !prompt.isEmpty {
            record.tracker.lastPrompt = prompt
        }
        record.tracker.note(agent.state)
        record.noteActivity()
        return record.summary()
    }

    /// The create spec an adopted pane is re-registered under.
    ///
    /// For a local pane this is what T23 always built. For a remote one it is the
    /// point where the pane gets its identity back (T43): the execution host stamp,
    /// the remote directory, the invocation that reopens the connection, the hook
    /// token the far side's config still names — and a `statusDetection` decided
    /// *now*, because whether this app instance could rebind the port the surviving
    /// `ssh` forwards to is not a fact the record could know.
    ///
    /// The prompt is empty for a local pane and for a remote *agent* pane (it belongs
    /// to an incarnation of a previous app run, and for a `.typeWhenIdle` engine it is
    /// text that would be typed into the agent). A remote *shell* pane is the
    /// exception: its prompt is the `ssh` command line, and dropping it would leave the
    /// pane one respawn away from reopening as a local shell.
    private func restoredSpec(pane: KeeperPaneRecord, handle: String,
                              connectionSurvived: Bool = true) -> TerminalCreateSpec {
        guard let remote = pane.remote else {
            return TerminalCreateSpec(
                handle: handle, paneKey: pane.paneKey, worktreeId: pane.worktreeId,
                cwd: pane.cwd, engineID: pane.engineID, prompt: "", title: pane.title,
                initialCols: pane.cols, initialRows: pane.rows)
        }
        // Only a pane whose connection survived has a channel to rebind: the rebind
        // question is "does the still-open `ssh` still reach us", and for a pane whose
        // `ssh` ended there is no forward to speak of. It keeps the detection it was
        // recorded with, and a reconnect decides afresh from the port bound then.
        let resolution = connectionSurvived
            ? KeeperRemoteRestoration.resolve(
                pane: pane, boundLocalPort: remote.tunnel == nil ? 0 : boundHookPort())
            : KeeperRemoteRestoration.Resolution(detection: remote.statusDetection,
                                                 channel: .noneRecorded)
        let usesArgv = remote.launchArgv?.isEmpty == false
        return TerminalCreateSpec(
            handle: handle, paneKey: pane.paneKey, worktreeId: pane.worktreeId,
            // Still the LOCAL cwd — where `ssh` runs from. The far side's directory
            // travels in `remoteCwd`, where no local `chdir` can reach it.
            cwd: pane.cwd, engineID: pane.engineID,
            prompt: usesArgv ? "" : (remote.launchPrompt ?? ""),
            title: pane.title,
            executionHostId: remote.executionHostId,
            initialCols: pane.cols, initialRows: pane.rows,
            launchArgv: remote.launchArgv,
            hookToken: pane.hookToken,
            statusDetection: resolution.detection,
            remoteCwd: remote.remoteCwd)
    }

    /// The hook port this app instance actually bound (0 when it never bound one).
    /// Reading it starts the server, which is exactly what an adoption wants: the
    /// preferred-port hint has already been handed to the channel by then, so this is
    /// the call that decides rebind or degradation.
    private func boundHookPort() -> UInt16 { hookChannel?.localHookPort ?? 0 }

    /// Boot side, remote panes only: adopt a pane whose held `ssh` ended while the app
    /// was gone.
    ///
    /// There is no fd to attach — the keeper saw EOF and closed it — so this registers
    /// the pane *disconnected*, with no exit status, which `HostLiveness` reads as
    /// `unverifiable`. That is the whole point: the thing that ended is a connection,
    /// and a connection ending is not evidence about the work on the far side. The
    /// pane comes back inspectable and carrying the spec `reconnectRemote` relaunches
    /// from, instead of vanishing along with the only local record that it existed.
    ///
    /// The readiness stack is deliberately NOT wired: driving it from a dead session
    /// would manufacture a `.finished(0)` from a nil exit code, and for an `ssh` pane
    /// the difference between "no status" and "status 0" is the difference between
    /// `unverifiable` and a death certificate nobody issued.
    @discardableResult
    public func adoptEndedRemote(pane: KeeperPaneRecord,
                                 config: DamsonConfig = DamsonConfig()) throws -> TerminalSummary {
        guard let remote = pane.remote else {
            throw TerminalServiceError.invalidArgument(
                "pane '\(pane.paneKey)' is not a remote pane; a local child that ended "
                    + "while held closes its pane")
        }
        guard registry.record(forPaneKey: pane.paneKey) == nil else {
            throw TerminalServiceError.invalidArgument(
                "pane '\(pane.paneKey)' is already registered")
        }
        guard let engine = AgentEngineRegistry.engine(id: pane.engineID) else {
            throw TerminalServiceError.unknownEngine(pane.engineID)
        }
        var config = config
        config.argv = remote.launchArgv ?? pane.argv
        config.cwd = pane.cwd
        let spec = restoredSpec(pane: pane, handle: TerminalRegistry.mintHandle(),
                                connectionSurvived: false)
        let session = KeeperEndedSession(config: config, cols: pane.cols, rows: pane.rows)
        let agent = makeAgentSession(spec: spec, engine: engine, session: session)
        agent.terminalHandle = spec.handle
        agent.paneKey = spec.paneKey
        let record = TerminalRecord(handle: spec.handle, spec: spec, engine: engine,
                                    session: session, agentSession: agent,
                                    incarnation: pane.incarnation + 1)
        record.initialPromptStarted = true
        record.exited = true
        // The ending happened while nobody was watching, and it was reported by the
        // keeper's EOF rather than by a waiter here. Announcing it now would be a
        // second exit event for one exit — and for the orchestration layer, an exit
        // arriving after the fact for a pane it already reconciled.
        record.exitNotified = true
        registry.register(record)
        return record.summary()
    }

    /// A remote pane of this worktree whose connection has ended and which can be
    /// reopened — what the app binds a "the connection ended / Reconnect" surface to
    /// instead of silently opening a second connection beside it.
    public func endedRemotePane(worktreeId: String? = nil) -> TerminalSummary? {
        registry.list(worktreeId: worktreeId)
            .first { !$0.connected && $0.spec.isRemote }?
            .summary()
    }

    /// Reopen a remote pane's connection: a FRESH `ssh` from the pane's own recorded
    /// spec, under the same `paneKey`, with the next incarnation.
    ///
    /// This is the one place a connection is allowed to come back, and it is always a
    /// decision somebody made — a button or an explicit verb — never something a boot
    /// does on its own. A pane that reconnected itself would look exactly like one that
    /// never dropped, and "the connection is the same one you left" is a claim only a
    /// connection that never ended can make. The incarnation bump is what makes the
    /// difference legible: same pane, provably different PTY channel.
    ///
    /// A live pane is refused rather than restarted, because reconnecting one would
    /// tear down a working connection to a machine we cannot see — the trade rule 2
    /// exists to prevent.
    @discardableResult
    public func reconnectRemote(paneKey: String) throws -> TerminalSummary {
        guard let record = registry.record(forPaneKey: paneKey) else {
            throw TerminalServiceError.notFound(handle: paneKey)
        }
        guard record.spec.isRemote else {
            throw TerminalServiceError.invalidArgument(
                "pane '\(paneKey)' runs on this machine — there is no connection to reopen")
        }
        guard !record.connected else {
            throw TerminalServiceError.invalidArgument(
                "pane '\(paneKey)' is still connected; reconnect reopens a connection "
                    + "that ended")
        }
        let plan = KeeperRemoteRestoration.reconnectPlan(spec: record.spec,
                                                         boundLocalPort: boundHookPort())
        let spec = TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(), paneKey: record.paneKey,
            worktreeId: record.worktreeId,
            cwd: record.spec.cwd, engineID: record.engine.id,
            prompt: plan.prompt, title: record.title,
            executionHostId: record.spec.executionHostId,
            initialCols: record.session.gridSnapshot().cols,
            initialRows: record.session.gridSnapshot().rows,
            launchArgv: plan.launchArgv,
            // Never reminted: the token is already written into a config file on the
            // far side, and a fresh one would reopen the pane as a different,
            // statusless agent.
            hookToken: record.spec.hookToken,
            statusDetection: plan.detection,
            remoteCwd: record.spec.remoteCwd)
        return try relaunch(record: record, spec: spec)
    }

    // MARK: - Read

    public func read(handle: String, cursor: Int? = nil, limit: Int = 200,
                     screen: Bool = false) throws -> TerminalReadResult {
        let record = try registry.resolve(handle)
        let status = record.connected ? "running" : "exited"
        if screen {
            let grid = record.session.gridSnapshot()
            var lines = grid.lines
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            if grid.rows > 0 {
                return TerminalReadResult(
                    handle: record.handle, status: status, lines: lines, source: .screen,
                    oldestCursor: nil, nextCursor: nil, latestCursor: nil,
                    truncated: false, returnedLineCount: lines.count)
            }
            // No renderable frame — fall through to the stream, and say so.
            let page = record.buffer.page(cursor: cursor, limit: limit)
            return streamResult(record, status: status, page: page, source: .screenUnavailable)
        }
        let page = record.buffer.page(cursor: cursor, limit: limit)
        return streamResult(record, status: status, page: page, source: .stream)
    }

    private func streamResult(_ record: TerminalRecord, status: String,
                              page: TerminalStreamBuffer.Page,
                              source: TerminalReadResult.Source) -> TerminalReadResult {
        TerminalReadResult(
            handle: record.handle, status: status, lines: page.lines, source: source,
            oldestCursor: record.buffer.oldestCursor, nextCursor: page.nextCursor,
            latestCursor: record.buffer.latestCursor, truncated: page.truncated,
            returnedLineCount: page.lines.count)
    }

    // MARK: - Send

    /// Deliver input to a terminal. Prompt submissions to an idle agent TUI go through
    /// the full verified injection pipeline; the agent-sendable guard produces the
    /// typed `no-agent` / `permission` refusals.
    ///
    /// `requireAgent` mirrors Orca's `requireAgentStatus: 'sendable'`: nil (default)
    /// guards exactly the sends that need it — text submissions into an agent-TUI
    /// terminal; `true` demands a sendable agent for any terminal (a shell then refuses
    /// `no-agent`); `false` skips the guard for a raw write the caller takes
    /// responsibility for.
    public func send(handle: String, text: String? = nil, enter: Bool = false,
                     interrupt: Bool = false,
                     requireAgent: Bool? = nil) async throws -> TerminalSendResult {
        let record = try registry.resolve(handle)
        return try await record.sendGate.run { [self] in
            try await performSend(record: record, text: text, enter: enter,
                                  interrupt: interrupt, requireAgent: requireAgent)
        }
    }

    private func performSend(record: TerminalRecord, text: String?, enter: Bool,
                             interrupt: Bool,
                             requireAgent: Bool?) async throws -> TerminalSendResult {
        if record.exited || record.session.processExited {
            throw TerminalServiceError.exited(handle: record.handle)
        }
        let hasText = !(text ?? "").isEmpty
        let agentTerminal = record.engine.usesLongRunningTUI
        let guarded = requireAgent ?? (hasText && enter && agentTerminal)
        if guarded {
            guard record.isRunningAgent else {
                return .refused(handle: record.handle, reason: .noAgent)
            }
            if record.tracker.currentState.runtimeProjection == .permission {
                return .refused(handle: record.handle, reason: .permission)
            }
        }

        var written = 0
        if interrupt {
            record.agentSession.interrupt()   // Ctrl-C + Tier-3 idle inference
            written += 1
        }
        guard let text, hasText else {
            if enter {
                record.session.write(Data([0x0D]))
                written += 1
            }
            return .delivered(handle: record.handle, bytesWritten: written)
        }

        let sanitized = PromptInjector.sanitize(text)
        let wasIdle = record.agentSession.state == .idle
        written += await PromptInjector.type(sanitized, into: record.session,
                                             chunkSize: pipeline.chunkSize)
        if enter {
            if agentTerminal {
                if wasIdle {
                    // The full verified path: delayed CR, then proof the agent left
                    // idle. Only an idle start makes "left idle" meaningful.
                    try await PromptInjector.submitAndVerify(
                        session: record.session, handle: record.handle,
                        config: pipeline) { record.agentSession.state }
                    record.tracker.lastPrompt = text
                    record.agentSession.notePromptDelivered()
                    publishStatus(record)
                } else {
                    // Queued into a busy agent: still give the TUI its settle beat,
                    // but there is no idle departure to verify.
                    try? await Task.sleep(nanoseconds: UInt64(pipeline.submitDelay * 1_000_000_000))
                    record.session.write(Data([0x0D]))
                }
            } else {
                record.session.write(Data([0x0D]))
            }
            written += 1
        }
        return .delivered(handle: record.handle, bytesWritten: written)
    }

    // MARK: - Wait

    /// Wait for `tui-idle` or `exit` (orca-inventory §3 rules): only `idle` satisfies
    /// tui-idle (`permission` does not); an already-idle last status fast-paths; any
    /// transition to idle resolves; the last-status record is never cleared by a
    /// consuming waiter; PTY exit rejects tui-idle waiters immediately; the default
    /// timeout is enforced and returns a checkpoint, not an error.
    public func wait(handle: String, for condition: TerminalWaitCondition,
                     timeout: TimeInterval? = nil) async throws -> TerminalWaitResult {
        let record = try registry.resolve(handle)
        let timeout = timeout ?? Self.defaultWaitTimeout

        // Fast paths off the (never-cleared) factual record.
        switch condition {
        case .exit:
            if record.exited || record.session.processExited {
                return waitResult(record, condition: .exit, satisfied: true, timedOut: false)
            }
        case .tuiIdle:
            if record.exited || record.session.processExited {
                throw TerminalServiceError.exited(handle: record.handle)
            }
            if record.tracker.currentState == .idle {
                return waitResult(record, condition: .tuiIdle, satisfied: true, timedOut: false)
            }
        }

        let waiterID = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            record.waiters[waiterID] = TerminalRecord.Waiter(condition: condition,
                                                            continuation: continuation)
            // A fired timeout that finds its waiter already resolved is a no-op —
            // whoever removes the waiter from the map owns the (single) resume.
            Task { @MainActor [weak self, weak record] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let record,
                      let waiter = record.waiters.removeValue(forKey: waiterID) else { return }
                waiter.continuation.resume(returning: self.waitResult(
                    record, condition: waiter.condition, satisfied: false, timedOut: true))
            }
        }
    }

    /// Number of parked `wait` continuations for this handle (test seam).
    public func waiterCount(handle: String) throws -> Int {
        try registry.resolve(handle).waiters.count
    }

    private func waitResult(_ record: TerminalRecord, condition: TerminalWaitCondition,
                            satisfied: Bool, timedOut: Bool) -> TerminalWaitResult {
        TerminalWaitResult(
            handle: record.handle,
            condition: condition,
            satisfied: satisfied,
            timedOut: timedOut,
            agentState: record.isRunningAgent ? record.tracker.currentState.runtimeProjection : nil,
            exitCode: record.exitCode ?? record.session.exitCode)
    }

    // MARK: - Agent status

    /// The current `AgentStatusEntry`-shaped snapshot for one terminal.
    public func agentStatus(handle: String) throws -> AgentStatusSnapshot {
        try registry.resolve(handle).statusSnapshot()
    }

    /// Spawn cwd for provider transcript resolution. Kept behind the terminal
    /// service so runtime callers do not reach into registry records.
    public func workingDirectory(handle: String) throws -> String? {
        try registry.resolve(handle).spec.cwd
    }

    /// A live stream of status snapshots for one terminal. Emits the current snapshot
    /// immediately (the never-cleared last status), then one per state update; finishes
    /// when the terminal is closed.
    public func agentStatusUpdates(handle: String) throws -> AsyncStream<AgentStatusSnapshot> {
        let record = try registry.resolve(handle)
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(record.statusSnapshot())
            record.statusContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    record.statusContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Live handle for a durable pane key (survives remints). Chat view-mode
    /// addresses the PTY by pane, not by a possibly-stale spawn handle.
    public func liveHandle(forPaneKey paneKey: String) -> String? {
        registry.record(forPaneKey: paneKey)?.handle
    }

    /// Fold hook/OSC chat fields into one terminal's status record and publish
    /// when they change. Additive: state-only callers keep using `agentStatus`.
    public func applyHookStatus(handle: String, fields: HookStatusFields) throws {
        let record = try registry.resolve(handle)
        hookFieldsChanged(record, fields: fields)
    }

    // MARK: - Spawn plumbing

    private func spawn(spec: TerminalCreateSpec, engine: AgentEngine) throws -> TerminalRecord {
        let session = try makeSession(spec: spec, engine: engine)
        let agentSession = makeAgentSession(spec: spec, engine: engine, session: session)
        let record = TerminalRecord(handle: spec.handle, spec: spec, engine: engine,
                                    session: session, agentSession: agentSession)
        wireStateChanges(record)
        return record
    }

    private func makeSession(spec: TerminalCreateSpec, engine: AgentEngine) throws -> TerminalSession {
        do {
            return try factory(spec, engine)
        } catch let error as TerminalServiceError {
            throw error
        } catch {
            throw TerminalServiceError.spawnFailed(String(describing: error))
        }
    }

    private func makeAgentSession(spec: TerminalCreateSpec, engine: AgentEngine,
                                  session: TerminalSession) -> AgentSession {
        let task = AgentTask(title: spec.title ?? engine.displayName,
                             prompt: spec.prompt,
                             engineID: engine.id,
                             baseRepoPath: "")
        return AgentSession(engine: engine, terminal: session, worktree: nil, task: task,
                            detectorConfig: detectorConfig, hookToken: spec.hookToken)
    }

    /// Route every fused-state transition into the tracker, the status streams, the
    /// waiters, and the once-only initial prompt delivery.
    private func wireStateChanges(_ record: TerminalRecord) {
        record.agentSession.onStateChange = { [weak self, weak record] state in
            guard let self, let record else { return }
            self.stateChanged(record, state: state)
        }
        attachHookFields(record)
    }

    private func attachHookFields(_ record: TerminalRecord) {
        let upstream = record.agentSession.onHookFields
        record.agentSession.onHookFields = { [weak self, weak record] fields in
            upstream?(fields)
            guard let self, let record else { return }
            self.hookFieldsChanged(record, fields: fields)
        }
    }

    private func hookFieldsChanged(_ record: TerminalRecord, fields: HookStatusFields) {
        if record.tracker.applyFields(fields) {
            publishStatus(record)
        }
    }

    private func publishStatus(_ record: TerminalRecord) {
        let snapshot = record.statusSnapshot()
        for continuation in record.statusContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func stateChanged(_ record: TerminalRecord, state: AgentRuntimeState) {
        record.tracker.note(state)
        publishStatus(record)

        switch state {
        case .idle:
            resolveWaiters(record, condition: .tuiIdle, satisfied: true)
            deliverInitialPromptIfNeeded(record)
        case .finished(let code):
            record.exited = true
            record.exitCode = code
            settleWaiters(record, exitCode: code)
            // The processExited guard keeps a straggler state change from a replaced
            // (respawned-away) session from reporting the live incarnation as dead.
            if record.session.processExited {
                notifyExit(record, deliberate: false)
            }
        case .errored:
            if record.session.processExited {
                record.exited = true
                record.exitCode = record.session.exitCode
                settleWaiters(record, exitCode: record.exitCode)
                notifyExit(record, deliberate: false)
            }
        default:
            break
        }
    }

    /// One exit event per pane incarnation. A spontaneous exit that is later followed
    /// by a user close reports only the spontaneous exit; a close of a live PTY
    /// reports only the deliberate close.
    private func notifyExit(_ record: TerminalRecord, deliberate: Bool) {
        guard !record.exitNotified else { return }
        record.exitNotified = true
        // Here rather than in `close`, so a pane whose child died on its own drops its
        // hook subscription too. Nothing will POST for it again, and a token left
        // routed is a listener only a guessed token could ever reach.
        hookChannel?.unregister(token: record.agentSession.hookToken)
        onTerminalExit?(TerminalExitEvent(
            handle: record.handle,
            paneKey: record.paneKey,
            exitCode: record.exitCode ?? record.session.exitCode,
            deliberate: deliberate,
            executionHostId: record.spec.executionHostId))
    }

    /// `.typeWhenIdle` engines get the task prompt exactly once, on the first idle,
    /// through the same verified pipeline `send` uses.
    private func deliverInitialPromptIfNeeded(_ record: TerminalRecord) {
        guard record.engine.promptDelivery == .typeWhenIdle,
              !record.spec.prompt.isEmpty,
              !record.initialPromptStarted,
              !record.agentSession.hasDeliveredInitialPrompt else { return }
        record.initialPromptStarted = true
        let prompt = record.spec.prompt
        Task { @MainActor [weak self, weak record] in
            guard let self, let record else { return }
            _ = try? await self.send(handle: record.handle, text: prompt, enter: true)
        }
    }

    /// PTY exit (or deliberate close) settles all waiters: exit waiters resolve
    /// satisfied; tui-idle waiters reject — the pane can never reach idle.
    private func settleWaiters(_ record: TerminalRecord, exitCode: Int32?) {
        record.exitCode = record.exitCode ?? exitCode
        let waiters = record.waiters
        record.waiters.removeAll()
        for waiter in waiters.values {
            switch waiter.condition {
            case .exit:
                waiter.continuation.resume(returning: waitResult(
                    record, condition: .exit, satisfied: true, timedOut: false))
            case .tuiIdle:
                waiter.continuation.resume(
                    throwing: TerminalServiceError.exited(handle: record.handle))
            }
        }
    }

    private func resolveWaiters(_ record: TerminalRecord, condition: TerminalWaitCondition,
                                satisfied: Bool) {
        let matching = record.waiters.filter { $0.value.condition == condition }
        for (id, waiter) in matching {
            record.waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: waitResult(
                record, condition: condition, satisfied: satisfied, timedOut: false))
        }
    }
}
