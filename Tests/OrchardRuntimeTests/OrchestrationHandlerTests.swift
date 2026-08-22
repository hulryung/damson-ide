import XCTest
import OrchardProtocol
@testable import OrchardRuntime

final class OrchestrationHandlerTests: XCTestCase {
    func testAllDocumentedVerbsAreRegisteredAndForwarded() async {
        let store = InMemoryOrchestrationStore(result: .string("ok"))
        let handler = OrchestrationCommandHandler(store: store)
        XCTAssertEqual(Set(handler.verbs), Set(OrchestrationCommandHandler.commandVerbs))
        for verb in handler.verbs {
            let response = await handler.handle(RPCRequest(method: verb, params: .object([:])))
            XCTAssertTrue(response.ok, verb); XCTAssertEqual(response.result, .string("ok"))
        }
        let calls = await store.calls
        XCTAssertEqual(calls, handler.verbs)
    }
}
