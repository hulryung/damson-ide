import Foundation
import OrchardProtocol

/// A runtime "server" with no socket: requests go straight into the registry and come
/// back stamped with `_meta.runtimeId`, exactly as the wire server will stamp them.
///
/// This is the seam wave-1 tasks test against — handlers exercise their full
/// request/response contract without binding a unix socket or spawning a client. T2's
/// NDJSON socket server wraps the same registry, so a handler proven here is proven for
/// the wire.
public final class InMemoryRuntimeServer: Sendable {
    public let runtimeId: String
    private let registry: CommandRegistry

    public init(registry: CommandRegistry, runtimeId: String = "rt_" + UUID().uuidString) {
        self.registry = registry
        self.runtimeId = runtimeId
    }

    public func perform(_ request: RPCRequest) async -> RPCResponse {
        let routed = await registry.route(request)
        // Stamp _meta uniformly so handlers never have to know the runtime identity.
        return RPCResponse(id: routed.id, ok: routed.ok, result: routed.result,
                           error: routed.error, meta: RPCMeta(runtimeId: runtimeId))
    }
}
