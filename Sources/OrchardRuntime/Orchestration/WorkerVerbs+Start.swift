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
                        agentID ?? "shell", placed.id, placed.path, placed.displayName)
                    external = false
                    effects.append(Self.effect(kind: "terminal", action: "created", id: summary.handle))
                }
                _ = try self.store.updateWorkerDispatch(
                    dispatchID, stage: "terminal_created",
                    worktreeID: worktree?.id, agentTerminalHandle: summary.handle,
                    setupState: setup.field("state")?.stringValue,
                    effects: Self.encodeReceipt(.array(effects)))

                // Stage: agent_readiness — tui-idle only; permission must not satisfy.
                stage = "agent_readiness"
                let wait = try await runtime.waitForAgentIdle(summary.handle, timeout)
                guard wait.satisfied else {
                    let state = wait.agentState.map { " (agent state: \($0.rawValue))" } ?? ""
                    throw RPCServiceError(
                        code: "agent_not_ready",
                        message: "Agent did not become ready within \(Int(timeout))s\(state).")
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

                // Stage: dispatch_input — the verified injection of the preamble.
                stage = "dispatch_input"
                let preamble = self.workerPreamble(
                    task: task, run: run, dispatchID: dispatchID,
                    capability: capability, workerHandle: summary.handle,
                    cliCommand: runtime.cliCommand)
                let delivered = try await runtime.injectPrompt(summary.handle, preamble)
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
                throw self.settleFailedWorkerStart(
                    error: error, runID: run.id, taskID: taskID, dispatchID: dispatchID,
                    failedStage: stage, setup: setup, launch: launch, effects: effects)
            }
        }
    }

    /// Persist the failure/unknown outcome and build the error envelope whose `data`
    /// is the staged receipt. Resources already created stay listed as residuals.
    private func settleFailedWorkerStart(
        error: Error, runID: String, taskID: String, dispatchID: String,
        failedStage: String, setup: JSONValue, launch: JSONValue, effects: [JSONValue]
    ) -> RPCServiceError {
        let reason = Self.describe(error)
        let residuals = effects.compactMap { effect -> JSONValue? in
            guard effect.field("action")?.stringValue == "created" else { return nil }
            return .object([
                "kind": effect.field("kind") ?? .null,
                "id": effect.field("id") ?? .null,
            ])
        }
        let residualsText = Self.encodeReceipt(.array(residuals))
        let unknown = Self.isUnknownStartOutcome(error, stage: failedStage)
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
            "residualResources": .array(residuals),
        ]
        if worker?.state == .startUnknown {
            receipt["nextCommands"] = .array([
                .string("orchard worker-show --dispatch \(dispatchID) --json"),
                .string("orchard worker-abandon --dispatch \(dispatchID) --json"),
            ])
        }
        return RPCServiceError(
            code: worker?.state == .startUnknown ? "worker_start_unknown" : "worker_start_failed",
            message: "worker-start failed at \(failedStage): \(reason)",
            data: .object(receipt))
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
    func workerPreamble(task: OrchestrationTask, run: OrchestrationRun,
                        dispatchID: String, capability: String?,
                        workerHandle: String, cliCommand: String) -> String {
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
