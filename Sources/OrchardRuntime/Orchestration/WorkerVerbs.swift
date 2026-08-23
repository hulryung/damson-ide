import Foundation
import OrchardOrchestration
import OrchardProtocol
import OrchardTerminals

// The post-start worker verbs: show / read / stop / abandon / release / retain / list.
// Semantics ported from ~/dev/orca/src/main/runtime/rpc/methods/orchestration-worker-*
// (docs/research/orca-inventory.md §1.8). Provider transcripts are pinned before
// release when a hook-attested session resolves; observation is in-process.
extension LiveOrchestrationStore {
    // MARK: - worker-show

    /// Dispatch + worker + live observation. `observation.agentWait` is deliberately
    /// three-state: an object is a proven human-only wait, `null` means "looked, found
    /// nothing waiting", and an ABSENT key means "never looked" (unattached / missing /
    /// identity-changed workers) — absence must never read as "not waiting".
    public func workerShow(_ p: [String: JSONValue],
                           runtime: WorkerRuntimeContext) async throws -> JSONValue {
        let dispatchID = try Self.requiredDispatch(p)
        return try await mapped {
            guard let dispatch = try self.store.dispatchContext(dispatchID) else {
                throw RPCServiceError(
                    code: "dispatch_not_found", message: "Worker Dispatch \(dispatchID) was not found.")
            }
            let worker = try self.store.workerDispatch(dispatchID)
            let observation = await self.observeWorkerTerminal(
                dispatch: dispatch, worker: worker, runtime: runtime)
            let resource = try self.store.workerTerminalResource(ownerDispatchID: dispatchID)
            var observationJSON: [String: JSONValue] = [
                "status": .string(observation.status),
                "exactWorker": .bool(observation.exact),
            ]
            if let reason = observation.reason {
                observationJSON["reason"] = .string(reason)
            }
            if let agentWait = observation.agentWait {
                // `.null` is a real value here (looked, nothing) — only "never looked"
                // omits the key entirely.
                observationJSON["agentWait"] = agentWait
            }
            return .object([
                "dispatch": Self.json(dispatch),
                "worker": worker.map(Self.exposedWorker) ?? Self.contextOnlyWorker(dispatch),
                "terminal": observation.exact ? (observation.terminal ?? .null) : .null,
                "observation": .object(observationJSON),
                "terminalResource": resource.map {
                    Self.exposedResource($0, archive: self.archiveSummary(dispatchID))
                } ?? .null,
            ])
        }
    }

    // MARK: - worker-read

    /// Archived content when the release pipeline has frozen it (or the live terminal
    /// is gone), else bounded live terminal output — always with a `source` field so
    /// the caller knows which question was answered.
    public func workerRead(_ p: [String: JSONValue],
                           runtime: WorkerRuntimeContext) async throws -> JSONValue {
        let dispatchID = try Self.requiredDispatch(p)
        let source = p.str("source") ?? "auto"
        guard ["auto", "transcript", "terminal"].contains(source) else {
            throw RPCServiceError(
                code: "invalid_argument", message: "--source must be auto|transcript|terminal.")
        }
        let cursor = p.int("cursor")
        let limit = max(1, p.int("limit") ?? 200)
        return try await mapped {
            guard let dispatch = try self.store.dispatchContext(dispatchID) else {
                throw RPCServiceError(
                    code: "dispatch_not_found", message: "Dispatch \(dispatchID) was not found.")
            }
            let worker = try self.store.workerDispatch(dispatchID)
            guard let handle = worker?.agentTerminalHandle ?? dispatch.assigneeHandle else {
                throw RPCServiceError(
                    code: "dispatch_not_found",
                    message: "Worker Dispatch \(dispatchID) has no agent terminal.")
            }
            let workerState = worker?.state.rawValue ?? "unsupervised"
            let resource = try self.store.workerTerminalResource(ownerDispatchID: dispatchID)
            let releaseCommitted = resource.map {
                [.releasing, .released, .unknown].contains($0.releaseState)
            } ?? false
            if releaseCommitted {
                return try self.readArchivedOutput(
                    dispatchID: dispatchID, workerState: workerState,
                    source: source, cursor: cursor, limit: limit)
            }
            guard case .found(let summary, _) = await runtime.lookupTerminal(handle) else {
                // The live pane is gone without a committed release; serve the pinned
                // archive if one exists rather than pretending there was no output.
                if try self.store.workerTerminalArchive(dispatchID: dispatchID) != nil {
                    return try self.readArchivedOutput(
                        dispatchID: dispatchID, workerState: workerState,
                        source: source, cursor: cursor, limit: limit)
                }
                throw RPCServiceError(
                    code: "terminal_not_found",
                    message: "Worker terminal for Dispatch \(dispatchID) no longer resolves and no archive was preserved.")
            }
            let page = try await runtime.readTerminal(summary.handle, cursor, limit)
            var result: [String: JSONValue] = [
                "dispatchId": .string(dispatchID),
                "source": .string("terminal"),
                "archived": .bool(false),
                "lines": .array(page.lines.map(JSONValue.string)),
                "returnedLineCount": .number(Double(page.returnedLineCount)),
                "truncated": .bool(page.truncated),
                "status": .object([
                    "worker": .string(workerState),
                    "terminal": .string(page.status),
                ]),
            ]
            if source != "terminal" {
                result["fallbackReason"] = .string("provider_transcript_not_pinned")
            }
            if let next = page.nextCursor { result["nextCursor"] = .number(Double(next)) }
            if let oldest = page.oldestCursor { result["oldestCursor"] = .number(Double(oldest)) }
            if let latest = page.latestCursor { result["latestCursor"] = .number(Double(latest)) }
            return .object(result)
        }
    }

    private func readArchivedOutput(
        dispatchID: String, workerState: String,
        source: String, cursor: Int?, limit: Int
    ) throws -> JSONValue {
        guard let archive = try store.workerTerminalArchive(dispatchID: dispatchID) else {
            throw RPCServiceError(
                code: "archive_unavailable",
                message: "Dispatch \(dispatchID) was released without a preserved output archive.")
        }
        switch archive.kind {
        case .transcriptPin:
            guard source != "terminal" else {
                throw RPCServiceError(
                    code: "archive_unavailable",
                    message: "Dispatch \(dispatchID) preserved structured transcript output only; terminal output was released.")
            }
            let content = Self.decodeReceipt(archive.content)
            return .object([
                "dispatchId": .string(dispatchID),
                "source": .string("transcript"),
                "archived": .bool(true),
                "content": content.field("content") ?? content,
                "transcriptPath": content.field("path") ?? .null,
                "truncated": content.field("truncated") ?? .bool(false),
                "status": .object([
                    "worker": .string(workerState),
                    "terminal": .string("archived"),
                ]),
            ])
        case .terminalTail:
            let content = Self.decodeReceipt(archive.content)
            let lines = content.field("lines")?.arrayValue?.compactMap(\.stringValue) ?? []
            let start = min(max(cursor ?? max(0, lines.count - limit), 0), lines.count)
            let end = min(start + limit, lines.count)
            var result: [String: JSONValue] = [
                "dispatchId": .string(dispatchID),
                "source": .string("terminal"),
                "archived": .bool(true),
                "lines": .array(lines[start..<end].map(JSONValue.string)),
                "returnedLineCount": .number(Double(end - start)),
                "startCursor": .number(Double(start)),
                "nextCursor": .number(Double(end)),
                "totalLines": .number(Double(lines.count)),
                "truncated": content.field("truncated") ?? .bool(false),
                "status": .object([
                    "worker": .string(workerState),
                    "terminal": .string("archived"),
                ]),
            ]
            if let warnings = content.field("warnings"), warnings != .array([]) {
                result["warnings"] = warnings
            }
            if let fallbackReason = content.field("fallbackReason") {
                result["fallbackReason"] = fallbackReason
            } else if source != "terminal" {
                result["fallbackReason"] = .string("provider_transcript_unavailable")
            }
            return .object(result)
        }
    }

    // MARK: - worker-stop

    public func workerStop(_ p: [String: JSONValue],
                           runtime: WorkerRuntimeContext) async throws -> JSONValue {
        let dispatchID = try Self.requiredDispatch(p)
        return try await idempotent(p, method: "worker-stop") {
            switch try self.store.beginWorkerStop(dispatchID) {
            case .alreadySettled(let worker):
                return Self.stopReceipt(dispatchID, state: worker.state.rawValue,
                                        alreadySettled: true, processAction: "none")
            case .contextOnly(let state, let alreadySettled, let releasedCurrentTask):
                if !alreadySettled {
                    self.waitCenter.notifyMessageArrived(recipient: "dispatch:\(dispatchID)", type: .status)
                }
                let warning = alreadySettled
                    ? "Dispatch was already \(state); no terminal process changed."
                    : (releasedCurrentTask
                        ? "The assignment was stopped without closing its unsupervised terminal process."
                        : "The superseded assignment was stopped without changing the current Task or terminal process.")
                return Self.stopReceipt(dispatchID, state: state, alreadySettled: alreadySettled,
                                        processAction: "none", warning: warning)
            case .stopping(let worker):
                guard let handle = worker.agentTerminalHandle else {
                    let unknown = try self.store.markWorkerStopUnknown(
                        dispatchID, reason: "The Dispatch has no recorded agent terminal.")
                    return Self.stopReceipt(dispatchID, state: unknown.state.rawValue,
                                            alreadySettled: false, processAction: "unknown",
                                            lastError: unknown.lastError)
                }
                let dispatch = try self.store.dispatchContext(dispatchID)
                let observation = await self.observeWorkerTerminal(
                    dispatch: dispatch, worker: worker, runtime: runtime)
                guard observation.exact, observation.status == "live" else {
                    let unknown = try self.store.markWorkerStopUnknown(
                        dispatchID,
                        reason: "The recorded worker process is \(observation.status); no terminal was closed.")
                    return Self.stopReceipt(dispatchID, state: unknown.state.rawValue,
                                            alreadySettled: false, processAction: "none",
                                            lastError: unknown.lastError)
                }
                let resource = try self.store.workerTerminalResource(ownerDispatchID: dispatchID)
                guard let resource, resource.ownershipState == .owned else {
                    let ownership = resource?.ownershipState.rawValue ?? "unproven"
                    let unknown = try self.store.markWorkerStopUnknown(
                        dispatchID, reason: "The worker terminal is \(ownership); no terminal was closed.")
                    return Self.stopReceipt(dispatchID, state: unknown.state.rawValue,
                                            alreadySettled: false, processAction: "none",
                                            lastError: unknown.lastError)
                }
                do {
                    try await runtime.closeTerminal(observation.liveHandle ?? handle)
                } catch {
                    let unknown = try self.store.markWorkerStopUnknown(
                        dispatchID, reason: Self.describe(error))
                    return Self.stopReceipt(dispatchID, state: unknown.state.rawValue,
                                            alreadySettled: false, processAction: "unknown",
                                            lastError: unknown.lastError)
                }
                let stopped = try self.store.settleWorkerStop(dispatchID)
                self.waitCenter.notifyMessageArrived(recipient: "dispatch:\(dispatchID)", type: .status)
                return Self.stopReceipt(dispatchID, state: stopped.state.rawValue,
                                        alreadySettled: false, processAction: "closed_agent_terminal")
            }
        }
    }

    private static func stopReceipt(
        _ dispatchID: String, state: String, alreadySettled: Bool,
        processAction: String, lastError: String? = nil, warning: String? = nil
    ) -> JSONValue {
        var receipt: [String: JSONValue] = [
            "dispatchId": .string(dispatchID),
            "state": .string(state),
            "alreadySettled": .bool(alreadySettled),
            "processAction": .string(processAction),
        ]
        if let lastError { receipt["lastError"] = .string(lastError) }
        if let warning { receipt["warning"] = .string(warning) }
        return .object(receipt)
    }

    // MARK: - worker-abandon

    /// Give up lifecycle authority without touching any process — possibly-live
    /// resources are retained and reported, never guessed dead.
    public func workerAbandon(_ p: [String: JSONValue]) async throws -> JSONValue {
        let dispatchID = try Self.requiredDispatch(p)
        return try await idempotent(p, method: "worker-abandon") {
            switch try self.store.abandonWorkerDispatch(dispatchID) {
            case .contextOnly(let state, let alreadySettled, let releasedCurrentTask):
                if !alreadySettled {
                    self.waitCenter.notifyMessageArrived(recipient: "dispatch:\(dispatchID)", type: .status)
                }
                let warning = alreadySettled
                    ? "Dispatch was already \(state); no state or process changed."
                    : (releasedCurrentTask
                        ? "The assignment was abandoned; its unsupervised terminal process was retained."
                        : "The superseded assignment was abandoned without changing the current Task or terminal process.")
                return .object([
                    "dispatchId": .string(dispatchID),
                    "state": .string(state),
                    "alreadySettled": .bool(alreadySettled),
                    "stale": .bool(!releasedCurrentTask && !alreadySettled),
                    "processAction": .string("none"),
                    "warning": .string(warning),
                    "residualResources": .array([]),
                ])
            case .abandoned(let worker):
                self.waitCenter.notifyMessageArrived(recipient: "dispatch:\(dispatchID)", type: .status)
                return Self.abandonReceipt(dispatchID, worker: worker, alreadySettled: false,
                                           stale: false,
                                           warning: "Possibly-live resources were retained; no process was stopped or deleted.")
            case .alreadyAbandoned(let worker):
                return Self.abandonReceipt(dispatchID, worker: worker, alreadySettled: true,
                                           stale: false,
                                           warning: "Possibly-live resources were retained; no process was stopped or deleted.")
            case .stale(let worker):
                return Self.abandonReceipt(dispatchID, worker: worker, alreadySettled: true,
                                           stale: true,
                                           warning: "The Dispatch is no longer current; no state or process changed.")
            }
        }
    }

    private static func abandonReceipt(
        _ dispatchID: String, worker: WorkerDispatch,
        alreadySettled: Bool, stale: Bool, warning: String
    ) -> JSONValue {
        .object([
            "dispatchId": .string(dispatchID),
            "state": .string(worker.state.rawValue),
            "alreadySettled": .bool(alreadySettled),
            "stale": .bool(stale),
            "processAction": .string("none"),
            "warning": .string(warning),
            "residualResources": decodeReceipt(worker.residualResources),
        ])
    }

    // MARK: - worker-release

    /// Archive-then-close: the output is pinned into `worker_terminal_archives` BEFORE
    /// the terminal closes, so worker-read still answers afterwards. Reused/pre-existing
    /// (external), user-taken-over, transferred, and identity-unproven terminals are
    /// refused (retained), and the whole verb is idempotent.
    public func workerRelease(_ p: [String: JSONValue],
                              runtime: WorkerRuntimeContext) async throws -> JSONValue {
        let dispatchID = try Self.requiredDispatch(p)
        return try await idempotent(p, method: "worker-release") {
            switch try self.store.requestWorkerTerminalRelease(dispatchID) {
            case .alreadyReleased:
                return self.releaseReceipt(dispatchID, state: "already_released", processAction: "none")
            case .retained(_, let reason):
                return self.releaseReceipt(dispatchID, state: "retained", reason: reason,
                                           processAction: "none")
            case .requested(let resource):
                return try await self.completeWorkerTerminalRelease(
                    dispatchID: dispatchID, resource: resource, runtime: runtime)
            }
        }
    }

    private func completeWorkerTerminalRelease(
        dispatchID: String, resource: WorkerTerminalResource,
        runtime: WorkerRuntimeContext
    ) async throws -> JSONValue {
        // Re-prove the exact identity before anything irreversible: the recorded
        // handle must still be the worker's, on the same pane and incarnation.
        guard let worker = try store.workerDispatch(dispatchID),
              worker.agentTerminalHandle == resource.terminalHandle else {
            _ = try store.revertWorkerTerminalReleaseToRetained(
                resourceID: resource.id, reason: "identity_unproven")
            return releaseReceipt(dispatchID, state: "retained", reason: "identity_unproven",
                                  processAction: "none")
        }
        guard case .found(let summary, _) = await runtime.lookupTerminal(resource.terminalHandle) else {
            // The handle resolves nowhere. The process could have died — or the
            // registry lost it; claiming released would hide a live process.
            let unknown = try store.markWorkerTerminalReleaseUnknown(
                resourceID: resource.id,
                reason: "The recorded terminal no longer resolves; whether its process is gone cannot be proven.")
            return releaseReceipt(dispatchID, state: "release_unknown", processAction: "none",
                                  lastError: unknown.releaseError,
                                  recovery: "Inspect with worker-show --dispatch \(dispatchID), then repeat worker-release with the same --retry-request. Never substitute a broad terminal close.")
        }
        if let pane = resource.paneKey, pane != summary.paneKey {
            _ = try store.revertWorkerTerminalReleaseToRetained(
                resourceID: resource.id, reason: "identity_unproven")
            return releaseReceipt(dispatchID, state: "retained", reason: "identity_unproven",
                                  processAction: "none")
        }
        if let incarnation = resource.processIncarnation, incarnation != String(summary.incarnation) {
            _ = try store.revertWorkerTerminalReleaseToRetained(
                resourceID: resource.id, reason: "identity_unproven")
            return releaseReceipt(dispatchID, state: "retained", reason: "identity_unproven",
                                  processAction: "none")
        }

        // Archive FIRST (§1.8): prefer the exact hook-attested provider transcript.
        // Any resolution failure is data, not an error: preserve the terminal tail
        // and its typed reason so release can still safely close the owned terminal.
        if try store.workerTerminalArchive(dispatchID: dispatchID) == nil {
            let transcript = await runtime.resolveProviderTranscript(
                summary.handle, WorkerRuntimeContext.transcriptPinByteLimit)
            switch transcript {
            case .resolved(let transcriptContent, let path, let truncated):
                let content: JSONValue = .object([
                    "content": .string(transcriptContent),
                    "path": .string(path),
                    "truncated": .bool(truncated),
                ])
                _ = try store.commitWorkerTerminalArchiveForRelease(
                    dispatchID: dispatchID, resourceID: resource.id,
                    kind: .transcriptPin, content: Self.encodeReceipt(content))
            case .unavailable(let fallbackReason):
                let content: JSONValue
                do {
                let page = try await runtime.readTerminal(summary.handle, nil, 2000)
                let empty = page.lines.allSatisfy {
                    $0.trimmingCharacters(in: .whitespaces).isEmpty
                }
                var warnings: [JSONValue] = []
                if empty {
                    warnings.append(.string(
                        "The live terminal buffer was empty at release; structured transcript output was unavailable."))
                }
                content = .object([
                    "lines": .array(page.lines.map(JSONValue.string)),
                    "truncated": .bool(page.truncated || (page.oldestCursor ?? 0) > 0),
                    "terminalStatus": .string(page.status),
                    "fallbackReason": .string(fallbackReason),
                    "warnings": .array(warnings),
                ])
                } catch {
                    throw RPCServiceError(
                        code: "archive_failed",
                        message: "Output could not be preserved for Dispatch \(dispatchID); the terminal was retained. \(Self.describe(error))")
                }
                _ = try store.commitWorkerTerminalArchiveForRelease(
                    dispatchID: dispatchID, resourceID: resource.id,
                    kind: .terminalTail, content: Self.encodeReceipt(content))
            }
        } else {
            let archive = try store.workerTerminalArchive(dispatchID: dispatchID)
            _ = try store.commitWorkerTerminalArchiveForRelease(
                dispatchID: dispatchID, resourceID: resource.id,
                kind: archive?.kind ?? .terminalTail,
                content: archive?.content ?? "{}")
        }
        guard let releasing = try store.workerTerminalResource(id: resource.id),
              releasing.ownershipState == .owned, releasing.releaseState == .releasing else {
            let current = try store.workerTerminalResource(id: resource.id)
            return releaseReceipt(dispatchID, state: "retained",
                                  reason: current?.retainedReason ?? "identity_unproven",
                                  processAction: "none")
        }

        let wasConnected = summary.connected
        do {
            try await runtime.closeTerminal(summary.handle)
        } catch {
            let unknown = try store.markWorkerTerminalReleaseUnknown(
                resourceID: resource.id, reason: Self.describe(error))
            return releaseReceipt(dispatchID, state: "release_unknown", processAction: "none",
                                  lastError: unknown.releaseError,
                                  recovery: "Inspect with worker-show --dispatch \(dispatchID), then repeat worker-release with the same --retry-request.")
        }
        _ = try store.settleWorkerTerminalRelease(resourceID: resource.id)
        waitCenter.notifyMessageArrived(recipient: "dispatch:\(dispatchID)", type: .status)
        return releaseReceipt(
            dispatchID, state: "released",
            processAction: wasConnected ? "closed_agent_terminal" : "closed_exited_terminal")
    }

    private func releaseReceipt(
        _ dispatchID: String, state: String, reason: String? = nil,
        processAction: String, lastError: String? = nil, recovery: String? = nil
    ) -> JSONValue {
        var receipt: [String: JSONValue] = [
            "dispatchId": .string(dispatchID),
            "state": .string(state),
            "processAction": .string(processAction),
            "archive": archiveSummary(dispatchID),
        ]
        if let reason { receipt["reason"] = .string(reason) }
        if let lastError { receipt["lastError"] = .string(lastError) }
        if let recovery { receipt["recovery"] = .string(recovery) }
        return .object(receipt)
    }

    // MARK: - worker-retain

    public func workerRetain(_ p: [String: JSONValue]) async throws -> JSONValue {
        let dispatchID = try Self.requiredDispatch(p)
        return try await idempotent(p, method: "worker-retain") {
            switch try self.store.retainWorkerTerminalResource(dispatchID) {
            case .alreadyReleased:
                return self.releaseReceipt(dispatchID, state: "already_released", processAction: "none")
            case .noOwnedResource:
                return self.releaseReceipt(dispatchID, state: "retained", reason: "no_owned_resource",
                                           processAction: "none")
            case .releaseCommitted(let resource):
                return self.releaseReceipt(
                    dispatchID,
                    state: resource.releaseState == .unknown ? "release_unknown" : "release_pending",
                    processAction: "none", lastError: resource.releaseError,
                    recovery: "Terminal release was already committed and could not be changed to retained; inspect worker-show before taking further action.")
            case .retained:
                return self.releaseReceipt(dispatchID, state: "retained", reason: "user_requested",
                                           processAction: "none")
            }
        }
    }

    // MARK: - worker-list

    public func workerList(_ p: [String: JSONValue]) async throws -> JSONValue {
        let stateFilter = p.str("terminal-state")
        if let stateFilter, WorkerTerminalListState(rawValue: stateFilter) == nil {
            throw RPCServiceError(
                code: "invalid_argument",
                message: "--terminal-state must be one of \(WorkerTerminalListState.allCases.map(\.rawValue).joined(separator: "|")).")
        }
        return try await mapped {
            let rows = try self.store.listWorkerRows(runID: p.str("run"))
            var counts: [String: Int] = [:]
            var workers: [JSONValue] = []
            for row in rows {
                let terminalState = WorkerTerminalListState.derive(
                    workerState: row.workerState,
                    agentTerminalHandle: row.agentTerminalHandle,
                    resource: row.resource)
                if let terminalState {
                    counts[terminalState.rawValue, default: 0] += 1
                }
                if let stateFilter, terminalState?.rawValue != stateFilter { continue }
                workers.append(.object([
                    "dispatchId": .string(row.dispatchID),
                    "taskId": .string(row.taskID),
                    "runId": .string(row.runID),
                    "workerState": .string(row.workerState),
                    "dispatchStatus": .string(row.dispatchStatus.rawValue),
                    "agentTerminalHandle": Self.optional(row.agentTerminalHandle),
                    "terminalState": Self.optional(terminalState?.rawValue),
                    "resource": row.resource.map {
                        Self.exposedResource($0, archive: self.archiveSummary(row.dispatchID))
                    } ?? .null,
                ]))
            }
            return .object([
                "workers": .array(workers),
                "counts": .object(counts.mapValues { .number(Double($0)) }),
            ])
        }
    }

    // MARK: - Observation

    struct WorkerObservation {
        let status: String
        let exact: Bool
        let reason: String?
        /// nil = never looked (omit the key); `.null` = looked, nothing waiting;
        /// object = proven human-only wait.
        let agentWait: JSONValue?
        let terminal: JSONValue?
        /// The current (possibly reminted) handle when the terminal was found.
        let liveHandle: String?
    }

    /// Inspect the worker's terminal. Exactness requires the dispatch's recorded pane
    /// key and process incarnation to match the live pane — a replaced process's
    /// prompt must not attribute another lane's blocker to this worker.
    func observeWorkerTerminal(
        dispatch: DispatchContext?, worker: WorkerDispatch?,
        runtime: WorkerRuntimeContext
    ) async -> WorkerObservation {
        guard let handle = worker?.agentTerminalHandle ?? dispatch?.assigneeHandle else {
            return WorkerObservation(status: "unattached", exact: false, reason: nil,
                                     agentWait: nil, terminal: nil, liveHandle: nil)
        }
        guard case .found(let summary, let status) = await runtime.lookupTerminal(handle) else {
            return WorkerObservation(status: "missing", exact: false, reason: nil,
                                     agentWait: nil, terminal: nil, liveHandle: nil)
        }
        let exact = dispatch?.assigneePaneKey == summary.paneKey
            && dispatch?.processIncarnation == String(summary.incarnation)
        if !exact {
            return WorkerObservation(status: "identity_changed", exact: false, reason: nil,
                                     agentWait: nil, terminal: nil, liveHandle: summary.handle)
        }
        let agentWait: JSONValue
        if status.projection == .permission {
            agentWait = .object([
                // v2's fused detector doesn't expose which tier proved the wait, so the
                // evidence names the status stack rather than claiming hook/prompt-text.
                "evidence": .string("agent-status"),
                "state": .string(status.state.rawValue),
                "since": .number(status.stateStartedAt),
            ])
        } else {
            agentWait = .null
        }
        return WorkerObservation(
            status: summary.connected ? "live" : "exited",
            exact: true,
            reason: nil,
            agentWait: agentWait,
            terminal: try? JSONBridge.value(summary),
            liveHandle: summary.handle)
    }

    // MARK: - Exposure helpers

    static func exposedWorker(_ worker: WorkerDispatch) -> JSONValue {
        .object([
            "dispatch_id": .string(worker.dispatchID),
            "state": .string(worker.state.rawValue),
            "stage": .string(worker.stage),
            "worktree_id": optional(worker.worktreeID),
            "agent_terminal_handle": optional(worker.agentTerminalHandle),
            "setup_state": .string(worker.setupState),
            "effects": decodeReceipt(worker.effects),
            "residualResources": decodeReceipt(worker.residualResources),
            "startOptions": decodeReceipt(worker.startOptions),
            "last_error": optional(worker.lastError),
            "created_at": .string(worker.createdAt),
            "updated_at": .string(worker.updatedAt),
        ])
    }

    /// A dispatch with no worker row (`dispatch --inject`): unsupervised — lifecycle
    /// verbs never touch its process.
    static func contextOnlyWorker(_ dispatch: DispatchContext) -> JSONValue {
        .object([
            "dispatch_id": .string(dispatch.id),
            "state": .string("unsupervised"),
            "stage": .string(dispatch.capabilityHash != nil ? "injected" : "context_only"),
            "worktree_id": .null,
            "agent_terminal_handle": optional(dispatch.assigneeHandle),
            "setup_state": .string("not_applicable"),
            "effects": .array([]),
            "residualResources": .array([]),
            "startOptions": .object([:]),
            "last_error": optional(dispatch.lastFailure),
            "created_at": .string(dispatch.createdAt),
            "updated_at": .string(dispatch.completedAt ?? dispatch.createdAt),
        ])
    }

    static func exposedResource(_ resource: WorkerTerminalResource, archive: JSONValue) -> JSONValue {
        .object([
            "id": .string(resource.id),
            "ownershipState": .string(resource.ownershipState.rawValue),
            "releaseState": .string(resource.releaseState.rawValue),
            "retainedReason": optional(resource.retainedReason),
            "terminalHandle": .string(resource.terminalHandle),
            "worktreeId": optional(resource.worktreeID),
            "originDispatchId": .string(resource.originDispatchID),
            "ownerDispatchId": .string(resource.ownerDispatchID),
            "releaseRequestedAt": optional(resource.releaseRequestedAt),
            "releaseCompletedAt": optional(resource.releaseCompletedAt),
            "releaseError": optional(resource.releaseError),
            "archive": archive,
        ])
    }

    /// `{source, status}` for the dispatch's pinned archive, `null` when none exists.
    func archiveSummary(_ dispatchID: String) -> JSONValue {
        guard let archive = try? store.workerTerminalArchive(dispatchID: dispatchID) else {
            return .null
        }
        switch archive.kind {
        case .transcriptPin:
            return .object(["source": .string("transcript"), "status": .string("captured")])
        case .terminalTail:
            let lines = Self.decodeReceipt(archive.content).field("lines")?.arrayValue ?? []
            let empty = lines.allSatisfy {
                ($0.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
            return .object([
                "source": .string("terminal"),
                "status": .string(empty ? "empty" : "captured"),
            ])
        }
    }

    static func requiredDispatch(_ p: [String: JSONValue]) throws -> String {
        guard let dispatchID = p.str("dispatch"), !dispatchID.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "missing --dispatch")
        }
        return dispatchID
    }
}
