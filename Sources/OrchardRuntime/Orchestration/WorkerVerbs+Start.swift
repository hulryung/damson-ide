import Foundation
import OrchardOrchestration
import OrchardProtocol
import OrchardTerminals

// worker-start: the staged pipeline (docs/research/orca-inventory.md §1.7)
//   worktree_create → terminal_create → setup_start → agent_readiness →
//   capability_minting → dispatch_input → ready
// composed from T4's WorkerStart helper (worktree), T3's terminal service (spawn,
// tui-idle wait, verified injection), and T1's worker tables (staged receipt rows).
// The RPC succeeds only for `ready`; every other outcome is a failure envelope whose
// `data` carries the full receipt {state, stage, failedStage, effects,
// residualResources} — which is what makes "exit 0 only for ready" true at the CLI.
extension LiveOrchestrationStore {
    public func workerStart(_ p: [String: JSONValue],
                            runtime: WorkerRuntimeContext) async throws -> JSONValue {
        guard let taskID = p.str("task"), !taskID.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "worker-start requires --task")
        }
        if let environment = p.str("on"), !environment.isEmpty {
            throw RPCServiceError(
                code: "not_implemented",
                message: "worker-start --on (connected environments) is not supported in v2 yet.")
        }
        let agentID = p.str("agent")
        let explicitTerminal = p.str("terminal")
        guard (agentID != nil) != (explicitTerminal != nil) else {
            throw RPCServiceError(
                code: "invalid_argument",
                message: "worker-start requires exactly one of --agent or --terminal.")
        }
        let placement = try Self.placement(p)
        // T60: `dispatch-input shell-command` (automation fires with a shell provider)
        // replaces the agent preamble with one executable command line; only a bare
        // shell can run it, so any other engine is refused before anything is created.
        let shellCommandInput = try AutomationShellDispatch.wantsShellCommand(p, agentID: agentID)
        // Refused before a dispatch row exists, exactly like `--on`: a supervised
        // dispatch that could never discharge its duties should leave nothing
        // half-created behind for a coordinator to clean up (T39). Since T80 the
        // question is put to the host rather than assumed — `preflight` carries which
        // host it already cleared, so the second gate below does not pay for a second
        // round trip on the same answer.
        let preflight = await Self.remoteDispatchPreflight(
            placement: placement, terminal: explicitTerminal, agent: agentID,
            cwd: p.str("cwd"), runtime: runtime)
        if let refusal = preflight.refusal { throw refusal }
        let setupPolicy = try Self.setupPolicy(p, createsWorktree: placement.createsWorktree)
        let timeout = p.int("timeout-ms").map { TimeInterval($0) / 1000 } ?? workerStartReadinessTimeout

        return try await idempotent(p, method: "worker-start") {
            guard let task = try self.store.task(taskID) else {
                throw RPCServiceError(code: "task_not_found", message: "Task \(taskID) was not found.")
            }
            let run = try self.requireRun(task.runID)

            let launch: JSONValue = .object([
                "agent": Self.optional(agentID),
                // Echoed, not applied: v2 engines take no model/effort argv yet.
                "model": Self.optional(p.str("model")),
                "effort": Self.optional(p.str("effort")),
            ])
            let startOptions: JSONValue = .object([
                "worktree": .string(placement.requested),
                "name": Self.optional(p.str("name")),
                "repo": Self.optional(p.str("repo")),
                "baseBranch": Self.optional(p.str("base-branch")),
                "terminal": Self.optional(explicitTerminal),
                "agent": Self.optional(agentID),
                "launch": launch,
                "timeoutMs": .number(timeout * 1000),
                "setup": .string(setupPolicy.requested),
                "setupSource": .string(setupPolicy.source),
            ])
            let started = try self.store.createStartingWorkerDispatch(
                taskID: taskID,
                startOptions: Self.encodeReceipt(startOptions),
                retryOf: p.str("retry-of"))
            let dispatchID = started.dispatch.id

            var effects: [JSONValue] = []
            var setup = setupPolicy.receipt(state: "not_applicable")
            var stage = "worktree_create"
            var warning: String?
            do {
                // Stage: worktree_create (setup scripts run inside T4's create, so a
                // setup failure surfaces here — stage setup_start is recorded for the
                // created case right after).
                var worktree: WorkerWorktreeReceipt?
                switch placement.kind {
                case .create(let child):
                    _ = try self.store.updateWorkerDispatch(dispatchID, stage: "worktree_creating")
                    let created = try await runtime.createWorktree(WorkerWorktreeSpec(
                        repo: p.str("repo"),
                        name: p.str("name"),
                        displayName: p.str("name"),
                        baseBranch: p.str("base-branch"),
                        runSetup: setupPolicy.runSetup,
                        newChild: child,
                        cwd: p.str("cwd")))
                    worktree = created
                    warning = created.warning
                    stage = "setup_start"
                    setup = setupPolicy.receipt(state: setupPolicy.completedState)
                    effects.append(Self.effect(kind: "worktree", action: "created", id: created.id))
                    effects.append(.object([
                        "kind": .string("setup"),
                        "action": .string(setupPolicy.effective),
                        "state": .string(setupPolicy.completedState),
                    ]))
                case .existing(let selector):
                    let resolved = try await runtime.resolveWorktree(selector, p.str("cwd"))
                    worktree = resolved
                    effects.append(Self.effect(kind: "worktree", action: "reused", id: resolved.id))
                case .fromTerminal:
                    worktree = nil
                }

                // The second gate on the host boundary (T39, docs/design/remote-hosts.md
                // stage 3). `remoteDispatchPreflight` already put the question to every
                // host it could resolve before a dispatch row existed, but it resolves
                // with `try?` — a placement that only resolves *here* (a freshly created
                // remote worktree, most of all) would otherwise slip past it, and what
                // slips past is a worker on a machine that cannot report: no
                // `worker_done`, no heartbeat, no answer to a blocking question. A
                // coordinator waiting on a settlement that can never arrive is worse
                // than a typed refusal at the door.
                if let placed = worktree, Self.isRemoteWorkspace(placed),
                   placed.hostId != preflight.clearedHost {
                    let readiness = await runtime.probeRemoteDispatch(placed.hostId ?? "")
                    if let refusal = Self.remoteDispatchGate(
                        hostId: placed.hostId, worktreeID: placed.id, agent: agentID,
                        readiness: readiness) {
                        throw refusal
                    }
                }

                // Stage: terminal_create.
                stage = "terminal_create"
                let summary: TerminalSummary
                let external: Bool
                if let explicitTerminal {
                    guard case .found(let found, _) = await runtime.lookupTerminal(explicitTerminal) else {
                        throw RPCServiceError(
                            code: "terminal_not_found",
                            message: "Terminal \(explicitTerminal) was not found.")
                    }
                    guard found.agentState != nil else {
                        throw RPCServiceError(
                            code: "agent_unconfigured",
                            message: "Terminal \(explicitTerminal) is not running a recognized agent.")
                    }
                    if worktree == nil, let worktreeID = found.worktreeId {
                        worktree = try? await runtime.resolveWorktree(worktreeID, nil)
                    }
                    // Same rule by the other door, and the same second gate: adopting a
                    // remote agent pane as a supervised worker binds lifecycle authority
                    // to a process on another machine, so that machine has to have
                    // answered for itself first.
                    if found.executionHostId != ExecutionHostId.local.rawValue,
                       found.executionHostId != preflight.clearedHost {
                        let readiness = await runtime.probeRemoteDispatch(found.executionHostId)
                        if let refusal = Self.remoteDispatchGate(
                            hostId: found.executionHostId,
                            worktreeID: found.worktreeId ?? explicitTerminal,
                            agent: found.engine, readiness: readiness) {
                            throw refusal
                        }
                    }
                    if let worktree, let terminalWorktree = found.worktreeId,
                       terminalWorktree != worktree.id {
                        throw RPCServiceError(
                            code: "terminal_worktree_mismatch",
                            message: "Terminal \(explicitTerminal) does not belong to worktree \(worktree.id).")
                    }
                    summary = found
                    external = true
                    effects.append(Self.effect(kind: "terminal", action: "reused", id: found.handle))
                } else {
                    guard let placed = worktree else {
                        throw RPCServiceError(
                            code: "invalid_argument",
                            message: "worker-start needs a workspace: pass --worktree <selector|new-top-level> (with --repo) or --terminal.")
                    }
                    _ = try self.store.updateWorkerDispatch(
                        dispatchID, stage: "terminal_creating", worktreeID: placed.id)
                    summary = try await runtime.createAgentTerminal(
                        agentID ?? "shell",
                        WorkerTerminalPlacement(worktreeID: placed.id, path: placed.path,
                                                title: placed.displayName,
                                                hostId: placed.hostId))
                    external = false
                    effects.append(Self.effect(kind: "terminal", action: "created", id: summary.handle))
                }
                _ = try self.store.updateWorkerDispatch(
                    dispatchID, stage: "terminal_created",
                    worktreeID: worktree?.id, agentTerminalHandle: summary.handle,
                    setupState: setup.field("state")?.stringValue,
                    effects: Self.encodeReceipt(.array(effects)))

                // Stage: agent_readiness. An agent TUI answers with tui-idle (permission
                // must not satisfy). A bare shell cannot: "stopped painting" is also what
                // a shell looks like while its startup files run, and input typed then is
                // read by the tty in canonical mode, which truncates it — which is how a
                // 6 KB contract loses its closing quote and strands the pane. So a shell
                // is asked to *run something* instead (T82).
                stage = "agent_readiness"
                let bareShell = ShellWorkerContract.needsShellContract(engineID: summary.engine)
                if bareShell {
                    guard await Self.shellHandshake(handle: summary.handle, runtime: runtime,
                                                    deadline: Date().addingTimeInterval(timeout)) else {
                        throw RPCServiceError(
                            code: "agent_not_ready",
                            message: "The shell did not run a readiness probe within \(Int(timeout))s.")
                    }
                    // The probe's output can arrive while the shell is still finishing
                    // whatever it was doing; give the line editor its beat to take the
                    // tty back before the contract arrives.
                    try? await Task.sleep(nanoseconds: UInt64(Self.shellSettleDelay * 1_000_000_000))
                } else {
                    let wait = try await runtime.waitForAgentIdle(summary.handle, timeout)
                    guard wait.satisfied else {
                        let state = wait.agentState.map { " (agent state: \($0.rawValue))" } ?? ""
                        throw RPCServiceError(
                            code: "agent_not_ready",
                            message: "Agent did not become ready within \(Int(timeout))s\(state).")
                    }
                }

                // Stage: capability minting + authority binding (pane + incarnation are
                // the proof material worker_done settlement checks against).
                stage = "capability_minting"
                let capability = try self.store.bindStartingWorkerAuthority(
                    dispatchID: dispatchID,
                    handle: summary.handle,
                    paneKey: summary.paneKey,
                    processIncarnation: String(summary.incarnation),
                    worktreeID: worktree?.id,
                    externalTerminal: external)

                // Stage: dispatch_input — the verified injection of the contract in the
                // form this pane can act on. The engine decides, not the caller: an
                // agent TUI reads prose as a prompt, while behind every other engine is
                // a shell that reads it as *input* — which is how the preamble used to
                // strand a shell worker at a `quote>` continuation prompt with the live
                // capability in pending input (T82; the T80 verification found it on a
                // local and a remote pane alike).
                stage = "dispatch_input"
                let dispatchInput: String
                let inputMode: String
                var deliveryNonce: String?
                if shellCommandInput {
                    // T60's automation fire: the spec *is* a command line, so the pane
                    // runs it and reports the exit status as this dispatch's outcome.
                    dispatchInput = AutomationShellDispatch.commandLine(
                        prompt: task.spec, cliCommand: runtime.cliCommand,
                        workerHandle: summary.handle, capability: capability,
                        taskID: taskID, dispatchID: dispatchID)
                    inputMode = AutomationShellDispatch.shellCommandMode
                } else if bareShell {
                    // A supervised shell worker: the spec is prose for whoever drives
                    // the pane, so the same contract arrives as a document the shell
                    // saves and prints, and the prompt comes back usable.
                    let nonce = ShellWorkerContract.nonce()
                    deliveryNonce = nonce
                    dispatchInput = ShellWorkerContract.commandLine(
                        preamble: self.workerPreamble(
                            task: task, run: run, dispatchID: dispatchID,
                            capability: capability, workerHandle: summary.handle,
                            cliCommand: runtime.cliCommand, workerKind: .bareShell),
                        cliCommand: runtime.cliCommand, workerHandle: summary.handle,
                        capability: capability, taskID: taskID, dispatchID: dispatchID,
                        deliveryNonce: nonce)
                    inputMode = ShellWorkerContract.mode
                } else {
                    dispatchInput = self.workerPreamble(
                        task: task, run: run, dispatchID: dispatchID,
                        capability: capability, workerHandle: summary.handle,
                        cliCommand: runtime.cliCommand)
                    inputMode = "preamble"
                }
                // A shell's acceptance is a write, not a delivery, so its contract goes
                // through the offer-verify-recover loop rather than a single injection.
                let delivered: TerminalSendResult
                if let deliveryNonce {
                    delivered = try await Self.deliverShellContract(
                        handle: summary.handle, line: dispatchInput, nonce: deliveryNonce,
                        runtime: runtime, deadline: Date().addingTimeInterval(timeout))
                } else {
                    delivered = try await runtime.injectPrompt(summary.handle, dispatchInput)
                }
                guard delivered.accepted else {
                    let reason = delivered.refusedReason?.rawValue ?? "refused"
                    throw RPCServiceError(
                        code: "agent_prompt_refused",
                        message: "The agent terminal refused the dispatch preamble (\(reason)).")
                }
                effects.append(.object([
                    "kind": .string("dispatch_input"),
                    "role": .string("agent"),
                    "id": .string(summary.handle),
                    "state": .string("accepted"),
                    "mode": .string(inputMode),
                ]))
                let worker = try self.store.markWorkerDispatchReady(
                    dispatchID, effects: Self.encodeReceipt(.array(effects)))

                var receipt: [String: JSONValue] = [
                    "runId": .string(run.id),
                    "taskId": .string(taskID),
                    "dispatchId": .string(dispatchID),
                    "state": .string(worker.state.rawValue),
                    "stage": .string(worker.stage),
                    "setup": setup,
                    "launch": launch,
                    "timeoutMs": .number(timeout * 1000),
                    "effects": .array(effects),
                    "residualResources": .array([]),
                ]
                if let warning { receipt["warning"] = .string(warning) }
                return .object(receipt)
            } catch {
                throw await self.settleFailedWorkerStart(
                    error: error, runID: run.id, taskID: taskID, dispatchID: dispatchID,
                    failedStage: stage, setup: setup, launch: launch, effects: effects,
                    runtime: runtime)
            }
        }
    }

    /// How long one readiness probe is given to come back before another is sent. A
    /// shell that had not taken the tty yet never saw the first one, so re-sending is
    /// the recovery — not waiting longer.
    static let shellProbeInterval: TimeInterval = 1.5
    /// How much of the pane's tail a marker search reads. Comfortably more than the
    /// handful of lines a probe or a printed contract adds.
    static let shellProbeReadLimit = 400
    /// How long one contract offer is given to come back with its marker.
    static let shellContractVerifyWindow: TimeInterval = 4
    /// How many offers the contract gets. Two is usually enough — the first can lose a
    /// race with a still-starting shell, and by the second that shell is settled — so
    /// three is the budget with a spare.
    static let shellContractAttempts = 3
    /// A beat after clearing a pane, so its line editor is back in charge before the
    /// next multi-kilobyte offer arrives.
    static let shellSettleDelay: TimeInterval = 0.5

    /// Wait for `marker` to appear in the pane's own output.
    ///
    /// Only an *executed* probe can produce it: every marker this file builds puts `%s`
    /// in a `printf` format and the nonce in the argument, so the echo of the command
    /// and the output of the command are different strings.
    static func awaitShellMarker(handle: String, marker: String,
                                 runtime: WorkerRuntimeContext, deadline: Date) async -> Bool {
        while true {
            if let read = try? await runtime.readTerminal(handle, nil, shellProbeReadLimit),
               read.lines.contains(where: { $0.contains(marker) }) {
                return true
            }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Ask the shell to run one short line, and wait for its output. Repeats with a
    /// fresh nonce until the deadline, because the interesting failure is a probe that
    /// was never read rather than one that was read and ignored.
    static func shellHandshake(handle: String, runtime: WorkerRuntimeContext,
                               deadline: Date) async -> Bool {
        repeat {
            let nonce = ShellWorkerContract.nonce()
            guard let sent = try? await runtime.injectPrompt(
                handle, ShellWorkerContract.readinessProbe(nonce: nonce)), sent.accepted else {
                return false
            }
            let window = min(deadline, Date().addingTimeInterval(shellProbeInterval))
            if await awaitShellMarker(handle: handle, marker: ShellWorkerContract.marker(nonce: nonce),
                                      runtime: runtime, deadline: window) {
                return true
            }
        } while Date() < deadline
        return false
    }

    /// Put the contract in front of the shell until the shell proves it ran the whole
    /// line — and never leave partial input in the pane when it did not.
    ///
    /// One offer is not enough on a pane whose shell has only just started. A login
    /// shell that has already answered a probe may still be running the rest of its
    /// startup files, and while it is, the line editor has not taken the tty back: input
    /// is read in **canonical mode**, where anything past `MAX_CANON` (1024 bytes on
    /// Darwin) is silently cut. What lands then is a contract without its closing quote
    /// — the stranded pane, capability and all, that this task exists to prevent.
    ///
    /// So every attempt is verified by the marker the line's last command prints (an
    /// echo of the line cannot produce it), and a failed attempt is cleared with an
    /// interrupt — the recovery T80's verification had to perform by hand — before the
    /// next one, which finds a settled shell. The interrupt runs on the last attempt
    /// too: if this stage is going to fail, it fails with an empty prompt behind it.
    static func deliverShellContract(handle: String, line: String, nonce: String,
                                     runtime: WorkerRuntimeContext,
                                     deadline: Date) async throws -> TerminalSendResult {
        let marker = ShellWorkerContract.marker(nonce: nonce)
        var attempts = 0
        repeat {
            attempts += 1
            let sent = try await runtime.injectPrompt(handle, line)
            guard sent.accepted else { return sent }
            let window = min(deadline, Date().addingTimeInterval(shellContractVerifyWindow))
            if await awaitShellMarker(handle: handle, marker: marker,
                                      runtime: runtime, deadline: window) {
                return sent
            }
            await runtime.interruptTerminal(handle)
            try? await Task.sleep(nanoseconds: UInt64(shellSettleDelay * 1_000_000_000))
        } while attempts < shellContractAttempts && Date() < deadline
        throw RPCServiceError(
            code: "agent_prompt_refused",
            message: "The shell did not run the dispatch contract to completion after "
                + "\(attempts) attempt(s); its input has been cleared.")
    }

    /// What the door check decided, and which host it already asked.
    struct RemoteDispatchPreflight {
        /// The typed refusal to throw, or nil when nothing stands in the way.
        var refusal: RPCServiceError?
        /// A host that answered `ready` here, so the second gate can skip re-asking it.
        /// Never set for a host that refused — that path throws instead.
        var clearedHost: String?
    }

    /// The refusal for a `worker-start` aimed at another machine, or nothing when the
    /// placement is local (or cannot be resolved yet — an unresolvable selector keeps
    /// its existing typed failure rather than being pre-empted by this check).
    ///
    /// Both doors are checked. `--terminal <remote pane>` names a real, watchable pane;
    /// adopting it as a worker binds lifecycle authority to a process on that machine.
    /// `--worktree <remote id>` would spawn that pane first and hit the same wall one
    /// stage later, with a worktree already reused and a dispatch row already open.
    static func remoteDispatchPreflight(
        placement: WorkerPlacement, terminal: String?, agent: String?, cwd: String?,
        runtime: WorkerRuntimeContext
    ) async -> RemoteDispatchPreflight {
        if let terminal,
           case .found(let found, _) = await runtime.lookupTerminal(terminal),
           found.executionHostId != ExecutionHostId.local.rawValue {
            let readiness = await runtime.probeRemoteDispatch(found.executionHostId)
            let refusal = remoteDispatchGate(
                hostId: found.executionHostId, worktreeID: found.worktreeId ?? terminal,
                agent: found.engine, readiness: readiness)
            return RemoteDispatchPreflight(
                refusal: refusal,
                clearedHost: refusal == nil ? found.executionHostId : nil)
        }
        if case .existing(let selector) = placement.kind,
           let receipt = try? await runtime.resolveWorktree(selector, cwd),
           isRemoteWorkspace(receipt) {
            let readiness = await runtime.probeRemoteDispatch(receipt.hostId ?? "")
            let refusal = remoteDispatchGate(
                hostId: receipt.hostId, worktreeID: receipt.id, agent: agent,
                readiness: readiness)
            return RemoteDispatchPreflight(
                refusal: refusal, clearedHost: refusal == nil ? receipt.hostId : nil)
        }
        return RemoteDispatchPreflight()
    }

    /// Whether this placement's files live on another machine.
    ///
    /// An unparseable stamp counts as remote (`RemoteWorkspacePolicy.isRemote`): reading
    /// it as local is the one downgrade that runs work on the wrong machine.
    static func isRemoteWorkspace(_ receipt: WorkerWorktreeReceipt) -> Bool {
        RemoteWorkspacePolicy.isRemote(hostId: receipt.hostId)
    }

    /// Persist the failure/unknown outcome and build the error envelope whose `data`
    /// is the staged receipt.
    ///
    /// T35 (dogfood-1 finding 1): a launch that dies after the worktree exists used to
    /// hand the caller an orphan and a cleanup chore. Now the definitively-failed case
    /// rolls back what it can prove is safe to roll back, and `residualResources` lists
    /// only what actually survived — each entry carrying the exact command that removes
    /// it. The dispatch row itself is always settled (`failed`, with the reason).
    private func settleFailedWorkerStart(
        error: Error, runID: String, taskID: String, dispatchID: String,
        failedStage: String, setup: JSONValue, launch: JSONValue, effects: [JSONValue],
        runtime: WorkerRuntimeContext
    ) async -> RPCServiceError {
        let reason = Self.describe(error)
        let unknown = Self.isUnknownStartOutcome(error, stage: failedStage)
        let created = effects.filter { $0.field("action")?.stringValue == "created" }
        let rollback = unknown
            ? []
            : await rollBackFailedStart(created: created, runtime: runtime)
        let rolledBackIDs = Set(rollback.compactMap { entry -> String? in
            entry.field("action")?.stringValue == "removed"
                ? entry.field("id")?.stringValue : nil
        })
        let residuals = created.compactMap { effect -> JSONValue? in
            let id = effect.field("id")?.stringValue
            guard let id, !rolledBackIDs.contains(id) else { return nil }
            var residual: [String: JSONValue] = [
                "kind": effect.field("kind") ?? .null,
                "id": .string(id),
            ]
            if let cleanup = Self.cleanupCommand(kind: effect.field("kind")?.stringValue,
                                                 id: id, cli: runtime.cliCommand) {
                residual["cleanupCommand"] = .string(cleanup)
            }
            if let retained = rollback.first(where: {
                $0.field("id")?.stringValue == id
                    && $0.field("action")?.stringValue == "retained"
            }), let why = retained.field("reason") {
                residual["retainedReason"] = why
            }
            return .object(residual)
        }
        let residualsText = Self.encodeReceipt(.array(residuals))
        let worker: WorkerDispatch?
        if unknown {
            worker = try? store.markWorkerStartUnknown(
                dispatchID, stage: failedStage, reason: reason, residualResources: residualsText)
        } else {
            worker = try? store.failWorkerStart(
                dispatchID, stage: failedStage, reason: reason, residualResources: residualsText)
        }
        var receipt: [String: JSONValue] = [
            "runId": .string(runID),
            "taskId": .string(taskID),
            "dispatchId": .string(dispatchID),
            "state": .string(worker?.state == .startUnknown ? "outcome_unknown"
                             : (worker?.state.rawValue ?? "failed")),
            "stage": .string(worker?.stage ?? failedStage),
            "failedStage": .string(failedStage),
            "lastError": .string(reason),
            "setup": setup,
            "launch": launch,
            "effects": .array(effects),
            "rollback": .array(rollback),
            "residualResources": .array(residuals),
        ]
        if worker?.state == .startUnknown {
            receipt["nextCommands"] = .array([
                .string("\(runtime.cliCommand) worker-show --dispatch \(dispatchID) --json"),
                .string("\(runtime.cliCommand) worker-abandon --dispatch \(dispatchID) --json"),
            ])
        }
        return RPCServiceError(
            code: worker?.state == .startUnknown ? "worker_start_unknown" : "worker_start_failed",
            message: "worker-start failed at \(failedStage): \(reason)",
            data: .object(receipt))
    }

    /// Best-effort cleanup of a proven-failed launch's own effects.
    ///
    /// Only the worktree is rolled back, and only when this attempt created it AND no
    /// terminal was created in it: a spawned agent pane is a live process whose cwd is
    /// that directory, so deleting it under the process would be the unsafe kind of
    /// automatic cleanup. The deletion itself is unforced — the workspace preflight
    /// refuses anything with work in it, and that refusal becomes the residual's
    /// `retainedReason`.
    private func rollBackFailedStart(
        created: [JSONValue], runtime: WorkerRuntimeContext
    ) async -> [JSONValue] {
        let createdTerminal = created.contains { $0.field("kind")?.stringValue == "terminal" }
        var entries: [JSONValue] = []
        for effect in created where effect.field("kind")?.stringValue == "worktree" {
            guard let id = effect.field("id")?.stringValue else { continue }
            guard !createdTerminal else {
                entries.append(.object([
                    "kind": .string("worktree"), "id": .string(id),
                    "action": .string("retained"),
                    "reason": .string("agent_terminal_created_in_worktree"),
                ]))
                continue
            }
            switch await runtime.rollbackWorktree(id) {
            case .removed:
                entries.append(.object([
                    "kind": .string("worktree"), "id": .string(id),
                    "action": .string("removed"),
                ]))
            case .retained(let reason):
                entries.append(.object([
                    "kind": .string("worktree"), "id": .string(id),
                    "action": .string("retained"), "reason": .string(reason),
                ]))
            }
        }
        return entries
    }

    /// The exact command that removes one surviving residual. dogfood-1 had to
    /// reconstruct this by hand from `worktree show`; the receipt now carries it.
    static func cleanupCommand(kind: String?, id: String, cli: String) -> String? {
        switch kind {
        case "worktree": return "\(cli) worktree rm --worktree '\(id)' --json"
        case "terminal": return "\(cli) terminal close --terminal \(id) --json"
        default: return nil
        }
    }

    /// Orca's outcome classifier: only an ambiguous acceptance or a lost-contact-style
    /// worktree_create failure is `start_unknown`; everything else the in-process
    /// runtime can prove failed.
    static func isUnknownStartOutcome(_ error: Error, stage: String) -> Bool {
        if let rpc = error as? RPCServiceError, rpc.rpcError.code == "operation_unknown" {
            return true
        }
        guard stage == "worktree_create" else { return false }
        let message = describe(error).lowercased()
        return message.contains("connection") || message.contains("disconnect")
            || message.contains("timed out") || message.contains("timeout")
            || message.contains("outcome unknown")
    }

    // MARK: - Flag parsing

    struct WorkerPlacement {
        enum Kind {
            case create(child: Bool)
            case existing(String)
            /// `--terminal` given with no worktree flag: the terminal's own worktree.
            case fromTerminal
        }
        let kind: Kind
        let requested: String
        var createsWorktree: Bool {
            if case .create = kind { return true }
            return false
        }
    }

    static func placement(_ p: [String: JSONValue]) throws -> WorkerPlacement {
        let raw = p.str("worktree")
        switch raw {
        case "new-top-level":
            return WorkerPlacement(kind: .create(child: false), requested: "new-top-level")
        case "new-child":
            return WorkerPlacement(kind: .create(child: true), requested: "new-child")
        case "current", "active":
            guard p.str("cwd")?.isEmpty == false else {
                throw RPCServiceError(
                    code: "invalid_argument",
                    message: "--worktree current needs a cwd; pass an explicit selector instead.")
            }
            return WorkerPlacement(kind: .existing("current"), requested: "current")
        case .some(let selector) where !selector.isEmpty:
            return WorkerPlacement(kind: .existing(selector), requested: selector)
        default:
            if p.str("terminal") != nil {
                return WorkerPlacement(kind: .fromTerminal, requested: "terminal")
            }
            if p.str("repo") != nil {
                // No placement named but a repo is: the common coordinator shape
                // "spawn a fresh worktree in that repo".
                return WorkerPlacement(kind: .create(child: false), requested: "new-top-level")
            }
            throw RPCServiceError(
                code: "invalid_argument",
                message: "worker-start needs a placement: --worktree <selector|new-top-level|new-child> or --terminal.")
        }
    }

    struct WorkerSetupPolicy {
        let requested: String
        let effective: String
        let source: String
        let runSetup: Bool?
        let completedState: String

        func receipt(state: String) -> JSONValue {
            .object([
                "requested": .string(requested),
                "effective": .string(effective),
                "source": .string(source),
                "state": .string(state),
            ])
        }
    }

    static func setupPolicy(_ p: [String: JSONValue], createsWorktree: Bool) throws -> WorkerSetupPolicy {
        guard createsWorktree else {
            return WorkerSetupPolicy(requested: "not_applicable", effective: "not_applicable",
                                     source: "existing_worktree", runSetup: nil,
                                     completedState: "not_applicable")
        }
        let raw = p.str("setup")
        let requested = raw ?? "run"
        let source = raw != nil ? "explicit_request" : "orchestration_default"
        switch requested {
        case "run":
            return WorkerSetupPolicy(requested: requested, effective: "run", source: source,
                                     runSetup: true, completedState: "completed")
        case "skip":
            return WorkerSetupPolicy(requested: requested, effective: "skip", source: source,
                                     runSetup: false, completedState: "skipped")
        case "inherit":
            // The repo's own setup default decides; v2 cannot see which way it went
            // from here, so the receipt says "inherited", not a guessed outcome.
            return WorkerSetupPolicy(requested: requested, effective: "inherit", source: source,
                                     runSetup: nil, completedState: "inherited")
        default:
            throw RPCServiceError(
                code: "invalid_argument", message: "--setup must be run|skip|inherit (got '\(requested)').")
        }
    }

    // MARK: - Shared helpers

    /// The injected worker contract with resolved gate Q&A appended — same construction
    /// as the `dispatch` verb, built here because worker-start owns its own injection.
    ///
    /// `workerKind` decides the after-`worker_done` half: an agent TUI returns to an
    /// idle prompt the coordinator can re-engage with a fresh dispatch, while a shell
    /// pane cannot be adopted as a worker at all (`worker-start --terminal` refuses a
    /// terminal with no agent), so telling a shell worker to sit and wait would leave
    /// it waiting for input that can never arrive.
    func workerPreamble(task: OrchestrationTask, run: OrchestrationRun,
                        dispatchID: String, capability: String?,
                        workerHandle: String, cliCommand: String,
                        workerKind: DispatchPreamble.WorkerKind = .promptReturningAgent) -> String {
        let resolved = ((try? store.listGates(taskID: task.id, status: .resolved)) ?? [])
            .compactMap { gate in gate.resolution.map { (question: gate.question, resolution: $0) } }
        return DispatchPreamble.build(DispatchPreamble.Params(
            taskID: task.id,
            dispatchID: dispatchID,
            dispatchCapability: capability,
            taskSpec: task.spec,
            coordinatorHandle: run.coordinatorHandle ?? "run:\(run.id)",
            workerHandle: workerHandle,
            cliCommand: cliCommand,
            workerKind: workerKind,
            resolvedGates: resolved))
    }

    static func effect(kind: String, action: String, id: String) -> JSONValue {
        var effect: [String: JSONValue] = [
            "kind": .string(kind),
            "action": .string(action),
            "id": .string(id),
        ]
        if kind == "terminal" { effect["role"] = .string("agent") }
        return .object(effect)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let rpc as RPCServiceError: return rpc.rpcError.message
        case let terminal as TerminalServiceError: return terminal.message
        case let orchestration as OrchestrationError: return orchestration.message
        case let workspace as WorkspaceError: return workspace.message
        default: return String(describing: error)
        }
    }
}
