import Foundation
import OrchardProtocol

/// RPC surface for the supervised-worker lifecycle verbs (docs/REBUILD-PLAN.md T7):
/// `worker-start|show|read|stop|abandon|release|retain|list`, routed onto the
/// `LiveOrchestrationStore` actor (which owns T1's SQLite confinement) with the live
/// terminal/workspace capability injected as `WorkerRuntimeContext`.
public struct WorkerCommandHandler: CommandHandler {
    public static let commandVerbs = [
        "worker-start", "worker-show", "worker-read", "worker-stop",
        "worker-abandon", "worker-release", "worker-retain", "worker-list",
    ]
    public let verbs = commandVerbs

    private let store: LiveOrchestrationStore
    private let runtime: WorkerRuntimeContext

    public init(store: LiveOrchestrationStore, runtime: WorkerRuntimeContext) {
        self.store = store
        self.runtime = runtime
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        let p = request.params?.objectValue ?? [:]
        do {
            let value: JSONValue
            switch request.method {
            case "worker-start": value = try await store.workerStart(p, runtime: runtime)
            case "worker-show": value = try await store.workerShow(p, runtime: runtime)
            case "worker-read": value = try await store.workerRead(p, runtime: runtime)
            case "worker-stop": value = try await store.workerStop(p, runtime: runtime)
            case "worker-abandon": value = try await store.workerAbandon(p)
            case "worker-release": value = try await store.workerRelease(p, runtime: runtime)
            case "worker-retain": value = try await store.workerRetain(p)
            case "worker-list": value = try await store.workerList(p)
            default:
                throw RPCServiceError(code: "unknown_command", message: request.method)
            }
            return .success(id: request.id, result: value)
        } catch let error as RPCServiceError {
            // worker-start's non-ready receipts arrive here with the staged receipt in
            // `data` — the failure envelope is what makes "exit 0 only for ready" true.
            return .failure(id: request.id, error: error.rpcError)
        } catch {
            return .failure(id: request.id, error: RPCError(
                code: "orchestration_error", message: String(describing: error)))
        }
    }
}
