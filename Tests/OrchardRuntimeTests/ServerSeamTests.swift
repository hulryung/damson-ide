import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// Exercises the T0 control-plane seam end to end: envelope Codables round-trip the
/// documented wire shape, and the registry + in-memory server route/stamp exactly the
/// way the T2 socket server will.
final class ServerSeamTests: XCTestCase {

    // MARK: - Envelope wire shape

    func testResponseEncodesMetaUnderUnderscoreMeta() throws {
        let response = RPCResponse.success(
            id: "req-1",
            result: .object(["hello": .string("world")]),
            meta: RPCMeta(runtimeId: "rt_test"))
        let data = try JSONEncoder().encode(response)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The wire key is `_meta` (matching the documented envelope), not `meta`.
        let meta = try XCTUnwrap(obj["_meta"] as? [String: Any])
        XCTAssertEqual(meta["runtimeId"] as? String, "rt_test")
        XCTAssertEqual(obj["ok"] as? Bool, true)
    }

    func testEnvelopeRoundTripsThroughJSON() throws {
        let request = RPCRequest(id: "42", method: "worktree-list",
                                 params: .object(["repo": .string("id:abc")]))
        let decoded = try JSONDecoder().decode(RPCRequest.self,
                                               from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)

        let failure = RPCResponse.failure(
            id: "42",
            error: RPCError(code: "unknown_command", message: "no handler",
                            data: .array([.number(1), .bool(true), .null])),
            meta: RPCMeta(runtimeId: "rt_x"))
        let decodedFailure = try JSONDecoder().decode(RPCResponse.self,
                                                      from: JSONEncoder().encode(failure))
        XCTAssertEqual(decodedFailure, failure)
    }

    // MARK: - Registry routing + stub server

    private struct EchoHandler: CommandHandler {
        var verbs: [String] { ["echo", "status"] }
        func handle(_ request: RPCRequest) async -> RPCResponse {
            .success(id: request.id, result: request.params ?? .null)
        }
    }

    func testRegistryRoutesToOwningHandlerAndStampsMeta() async {
        var registry = CommandRegistry()
        registry.register(EchoHandler())
        let server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_seam")

        let response = await server.perform(
            RPCRequest(id: "1", method: "echo", params: .string("ping")))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result, .string("ping"))
        XCTAssertEqual(response.meta?.runtimeId, "rt_seam")
        XCTAssertEqual(registry.registeredVerbs, ["echo", "status"])
    }

    func testUnknownVerbGetsTypedErrorEnvelope() async {
        var registry = CommandRegistry()
        registry.register(EchoHandler())
        let server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_seam")

        let response = await server.perform(RPCRequest(id: "2", method: "does-not-exist"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unknown_command")
        // Even failures carry the runtime identity, so clients can always fence.
        XCTAssertEqual(response.meta?.runtimeId, "rt_seam")
    }
}
