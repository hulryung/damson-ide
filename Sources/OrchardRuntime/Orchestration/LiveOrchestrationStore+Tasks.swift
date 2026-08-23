import Foundation
import OrchardOrchestration
import OrchardProtocol

// Task / dispatch / gate / reset verbs.
extension LiveOrchestrationStore {
    // MARK: - Tasks

    public func taskCreate(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let spec = p.str("spec"), !spec.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "task-create requires --spec")
        }
        let caller = await identity(p)
        return try await idempotent(p, method: "task-create") {
            let runID = try self.resolveRunID(p, caller: caller)
            let task = try self.store.createTask(
                runID: runID,
                spec: spec,
                taskTitle: p.str("task-title"),
                displayName: p.str("display-name"),
                deps: Self.dependencyList(p),
                parentID: p.str("parent"),
                createdByTerminalHandle: caller.handle,
                createdByPaneKey: caller.paneKey)
            return .object(["task": Self.json(task), "taskId": .string(task.id)])
        }
    }

    /// `--deps` accepts a JSON array (the documented shape) or a CSV fallback.
    static func dependencyList(_ p: [String: JSONValue]) -> [String] {
        if case .array(let values)? = p["deps"] {
            return values.compactMap(\.stringValue)
        }
        if let raw = p.str("deps"), !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                return parsed
            }
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return []
    }

    public func taskList(_ p: [String: JSONValue]) async throws -> JSONValue {
        let caller = await identity(p)
        let status: TaskStatus? = try p.str("status").map { raw in
            guard let parsed = TaskStatus(rawValue: raw) else {
                throw RPCServiceError(code: "invalid_argument", message: "unknown task status '\(raw)'")
            }
            return parsed
        }
        return try await mapped {
            // Scope to a run when one is in scope; a bare `task-list` from an unbound
            // caller lists across runs rather than failing (recovery-friendly).
            let runID = try? self.resolveRunID(p, caller: caller)
            let tasks = try self.store.listTasks(runID: runID, status: status, ready: p.flag("ready"))
            if p.flag("brief") {
                let rows = tasks.map { task -> JSONValue in
                    .object([
                        "id": .string(task.id),
                        "status": .string(task.status.rawValue),
                        "title": .string(task.taskTitle ?? task.displayName ?? String(task.spec.prefix(80))),
                    ])
                }
                return .object(["tasks": .array(rows), "count": .number(Double(rows.count))])
            }
            return .object([
                "tasks": .array(tasks.map(Self.json)),
                "count": .number(Double(tasks.count)),
            ])
        }
    }

    public func taskUpdate(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let id = p.str("id"), !id.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "task-update requires --id")
        }
        guard let statusRaw = p.str("status"), let status = TaskStatus(rawValue: statusRaw) else {
            throw RPCServiceError(
                code: "invalid_argument",
                message: "task-update requires --status pending|ready|dispatched|completed|failed|blocked")
        }
        return try await idempotent(p, method: "task-update") {
            guard let task = try self.store.updateTaskStatus(id, status, result: p.jsonText("result")) else {
                throw RPCServiceError(code: "task_not_found", message: "Task \(id) was not found.")
            }
            return .object(["task": Self.json(task)])
        }
    }

    // MARK: - Dispatch

    public func dispatchTask(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let taskID = p.str("task"), !taskID.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "dispatch requires --task")
        }
        guard let to = p.str("to"), !to.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "dispatch requires --to <terminal handle>")
        }
        let assigneePane = await context.paneKey(to) ?? to
        let wantsPreamble = p.flag("inject") || p.flag("return-preamble") || p.flag("dry-run")

        return try await idempotent(p, method: "dispatch") {
            guard let task = try self.store.task(taskID) else {
                throw RPCServiceError(code: "task_not_found", message: "Task \(taskID) was not found.")
            }
            let run = try self.requireRun(task.runID)

            if p.flag("dry-run") {
                guard task.status == .ready else {
                    throw RPCServiceError(
                        code: "task_not_startable",
                        message: "Task \(taskID) is \(task.status.rawValue); only ready tasks can be dispatched.")
                }
                return .object([
                    "dryRun": .bool(true),
                    "taskId": .string(taskID),
                    "to": .string(to),
                    "preamble": .string(self.preamble(
                        task: task, run: run, dispatchID: "<dispatch-id>",
                        capability: nil, workerHandle: to)),
                ])
            }

            let dispatch = try self.store.createDispatchContext(
                taskID: taskID, assigneeHandle: to, assigneePaneKey: assigneePane)
            let capability = try self.store.mintDispatchCapability(dispatchID: dispatch.id)
            var result: [String: JSONValue] = [
                "dispatchId": .string(dispatch.id),
                "taskId": .string(taskID),
                "runId": .string(run.id),
                "to": .string(to),
                "status": .string(dispatch.status.rawValue),
                "dispatchCapability": .string(capability),
            ]
            if wantsPreamble {
                result["preamble"] = .string(self.preamble(
                    task: task, run: run, dispatchID: dispatch.id,
                    capability: capability, workerHandle: to))
            }
            return .object(result)
        }
    }

    /// The injected worker contract with real ids inlined, plus any resolved gate Q&A
    /// so a retry attempt starts from the human's answers.
    private func preamble(task: OrchestrationTask, run: OrchestrationRun,
                          dispatchID: String, capability: String?,
                          workerHandle: String) -> String {
        let resolved = ((try? store.listGates(taskID: task.id, status: .resolved)) ?? [])
            .compactMap { gate in gate.resolution.map { (question: gate.question, resolution: $0) } }
        return DispatchPreamble.build(DispatchPreamble.Params(
            taskID: task.id,
            dispatchID: dispatchID,
            dispatchCapability: capability,
            taskSpec: task.spec,
            coordinatorHandle: run.coordinatorHandle ?? "run:\(run.id)",
            workerHandle: workerHandle,
            cliCommand: context.cliCommand,
            resolvedGates: resolved))
    }

    public func dispatchShow(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let id = p.str("id"), !id.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "dispatch-show requires --id")
        }
        return try await mapped {
            guard let dispatch = try self.store.dispatchContext(id) else {
                throw RPCServiceError(code: "dispatch_not_found", message: "Dispatch \(id) was not found.")
            }
            var result: [String: JSONValue] = [
                "dispatch": Self.json(dispatch),
                "heartbeatStale": .bool(try self.store.isHeartbeatStale(dispatch)),
            ]
            if let worker = try self.store.workerDispatch(id) {
                result["workerDispatch"] = Self.json(worker)
            }
            return .object(result)
        }
    }

    // MARK: - Gates

    public func gateCreate(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let taskID = p.str("task"), !taskID.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "gate-create requires --task")
        }
        guard let question = p.str("question"), !question.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "gate-create requires --question")
        }
        let caller = await identity(p)
        let options = Self.optionList(p)
        return try await idempotent(p, method: "gate-create") {
            // A worker opening a gate on its own task must prove dispatch ownership;
            // everyone else (coordinator / local CLI) creates gates unauthenticated.
            var requester: (handle: String, paneKey: String?, dispatchID: String)?
            if let handle = caller.handle,
               let active = try self.store.activeDispatchForTask(taskID),
               active.assigneeHandle == handle || active.assigneePaneKey == caller.paneKey {
                requester = (handle: handle, paneKey: caller.paneKey, dispatchID: active.id)
            }
            let gate = try self.store.createGate(
                taskID: taskID, question: question, options: options, requester: requester)
            return .object(["gate": Self.json(gate), "gateId": .string(gate.id)])
        }
    }

    /// `--options` accepts a JSON array (documented) or CSV.
    static func optionList(_ p: [String: JSONValue]) -> [String] {
        if case .array(let values)? = p["options"] {
            return values.compactMap(\.stringValue)
        }
        if let raw = p.str("options"), !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                return parsed
            }
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return []
    }

    public func gateResolve(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let id = p.str("id"), !id.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "gate-resolve requires --id")
        }
        guard let resolution = p.str("resolution"), !resolution.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "gate-resolve requires --resolution")
        }
        return try await idempotent(p, method: "gate-resolve") {
            guard let gate = try self.store.resolveGate(id, resolution: resolution) else {
                throw RPCServiceError(code: "gate_not_found", message: "Gate \(id) was not found.")
            }
            return .object(["gate": Self.json(gate)])
        }
    }

    public func gateList(_ p: [String: JSONValue]) async throws -> JSONValue {
        let status: GateStatus? = try p.str("status").map { raw in
            guard let parsed = GateStatus(rawValue: raw) else {
                throw RPCServiceError(code: "invalid_argument", message: "unknown gate status '\(raw)'")
            }
            return parsed
        }
        return try await mapped {
            let gates = try self.store.listGates(taskID: p.str("task"), status: status)
            return .object([
                "gates": .array(gates.map(Self.json)),
                "count": .number(Double(gates.count)),
            ])
        }
    }

    // MARK: - Reset

    public func reset(_ p: [String: JSONValue]) async throws -> JSONValue {
        let all = p.flag("all")
        let tasks = p.flag("tasks")
        let messages = p.flag("messages")
        guard all || tasks || messages else {
            throw RPCServiceError(
                code: "invalid_argument", message: "reset requires --all, --tasks, or --messages")
        }
        return try await mapped {
            let counts = try self.store.reset(messages: messages, tasks: tasks, all: all)
            return .object([
                "ok": .bool(true),
                "cleared": .object([
                    "messages": .number(Double(counts.messages)),
                    "deliveries": .number(Double(counts.deliveries)),
                    "questions": .number(Double(counts.questions)),
                    "tasks": .number(Double(counts.tasks)),
                    "dispatchContexts": .number(Double(counts.dispatchContexts)),
                    "decisionGates": .number(Double(counts.decisionGates)),
                    "workerDispatches": .number(Double(counts.workerDispatches)),
                    "workerTerminalResources": .number(Double(counts.workerTerminalResources)),
                    "workerTerminalArchives": .number(Double(counts.workerTerminalArchives)),
                    "runs": .number(Double(counts.runs)),
                    "mutationReceipts": .number(Double(counts.mutationReceipts)),
                ]),
            ])
        }
    }
}
