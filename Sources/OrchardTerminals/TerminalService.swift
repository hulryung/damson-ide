import Foundation
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
                       title: String? = nil,
                       initialCols: Int? = nil, initialRows: Int? = nil) throws -> TerminalSummary {
        guard let engine = AgentEngineRegistry.engine(id: engineID) else {
            throw TerminalServiceError.unknownEngine(engineID)
        }
        let spec = TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(),
            paneKey: TerminalRegistry.mintPaneKey(),
            worktreeId: worktreeId,
            cwd: cwd,
            engineID: engineID,
            prompt: prompt,
            title: title,
            initialCols: initialCols,
            initialRows: initialRows)
        let record = try spawn(spec: spec, engine: engine)
        registry.register(record)
        record.tracker.lastPrompt = prompt
        return record.summary()
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
        let handle = TerminalRegistry.mintHandle()
        // The pane kept its geometry — only the process is being replaced — so the new
        // PTY spawns at the outgoing session's current grid size, not the create-time one.
        let grid = record.session.gridSnapshot()
        let spec = TerminalCreateSpec(
            handle: handle, paneKey: record.paneKey, worktreeId: record.worktreeId,
            cwd: record.spec.cwd, engineID: record.engine.id, prompt: "",
            title: record.title,
            initialCols: grid.cols, initialRows: grid.rows)
        // Spawn first: a factory failure must leave the current incarnation intact,
        // its handle still live.
        let session = try makeSession(spec: spec, engine: record.engine)
        if !record.exited && !record.session.processExited {
            record.session.terminate()
        }
        settleWaiters(record, exitCode: record.session.exitCode)
        registry.retireHandle(record.handle, paneKey: record.paneKey)
        let agentSession = makeAgentSession(spec: spec, engine: record.engine, session: session)
        record.adopt(handle: handle, session: session, agentSession: agentSession)
        registry.register(record)
        wireStateChanges(record)
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
                worktreePath: record.agentSession.worktree?.path.path)
            out.append(KeeperReleasedPane(paneRecord: pane, handoff: handoff))
        }
        return out
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
        let spec = TerminalCreateSpec(
            handle: TerminalRegistry.mintHandle(), paneKey: pane.paneKey,
            worktreeId: pane.worktreeId, cwd: pane.cwd, engineID: pane.engineID,
            prompt: "", title: pane.title,
            initialCols: pane.cols, initialRows: pane.rows)
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
        record.tracker.note(agent.state)
        return record.summary()
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
                            detectorConfig: detectorConfig)
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
        onTerminalExit?(TerminalExitEvent(
            handle: record.handle,
            paneKey: record.paneKey,
            exitCode: record.exitCode ?? record.session.exitCode,
            deliberate: deliberate))
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
