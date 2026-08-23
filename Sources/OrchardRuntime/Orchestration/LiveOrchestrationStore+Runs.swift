import Foundation
import OrchardOrchestration
import OrchardProtocol

// Run verbs: run-create / run-use / run-current / run-list / run-show.
// Param names are the CLI flag names from `OrchardCommands` verbatim.
extension LiveOrchestrationStore {
    public func runCreate(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let objective = p.str("objective"), !objective.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "run-create requires --objective")
        }
        let caller = await identity(p)
        return try await idempotent(p, method: "run-create") {
            let run = try self.store.createRun(
                objective: objective,
                coordinatorHandle: caller.handle ?? "cli",
                coordinatorPaneKey: caller.paneKey ?? caller.handle ?? "cli")
            return .object([
                "run": Self.json(run),
                "runId": .string(run.id),
            ])
        }
    }

    public func runUse(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let id = p.str("id"), !id.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "run-use requires --id")
        }
        let caller = await identity(p)
        return try await idempotent(p, method: "run-use") {
            let run = try self.store.bindRun(
                runID: id,
                coordinatorHandle: caller.handle ?? "cli",
                coordinatorPaneKey: caller.paneKey ?? caller.handle ?? "cli")
            return .object(["run": Self.json(run), "runId": .string(run.id)])
        }
    }

    public func runCurrent(_ p: [String: JSONValue]) async throws -> JSONValue {
        let caller = await identity(p)
        return try await mapped {
            if let pane = caller.paneKey, let run = try self.store.runForCoordinatorPane(pane) {
                return .object(["run": Self.json(run), "runId": .string(run.id)])
            }
            // Anonymous local caller: a sole run is unambiguous enough to be "current".
            let runs = try self.store.listRuns()
            if caller.handle == nil, runs.count == 1 {
                return .object(["run": Self.json(runs[0]), "runId": .string(runs[0].id)])
            }
            return .object(["run": .null])
        }
    }

    public func runList(_ p: [String: JSONValue]) async throws -> JSONValue {
        try await mapped {
            let runs = try self.store.listRuns()
            return .object([
                "runs": .array(runs.map(Self.json)),
                "count": .number(Double(runs.count)),
            ])
        }
    }

    public func runShow(_ p: [String: JSONValue]) async throws -> JSONValue {
        guard let id = p.str("id"), !id.isEmpty else {
            throw RPCServiceError(code: "invalid_argument", message: "run-show requires --id")
        }
        return try await mapped {
            let run = try self.requireRun(id)
            let tasks = try self.store.listTasks(runID: id)
            let gates = try self.store.listGates().filter { $0.runID == id }
            return .object([
                "run": Self.json(run),
                "tasks": .array(tasks.map(Self.json)),
                "gates": .array(gates.map(Self.json)),
            ])
        }
    }
}
