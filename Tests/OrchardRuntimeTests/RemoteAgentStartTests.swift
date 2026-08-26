import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// T84: the app starts a remote agent through `terminal-create` and shows the
/// handler's typed error inline. These cases pin the verb shape and the
/// wording so a card or sheet cannot swallow a code.
final class RemoteAgentStartTests: XCTestCase {
    func testTerminalCreateParamsMatchTheCLIVerb() {
        let params = RemoteAgentStart.terminalCreateParams(
            worktreeId: "repo::/srv/wt/apricot", engineID: "claude-code",
            title: "apricot")
        XCTAssertEqual(params["worktree"]?.stringValue, "repo::/srv/wt/apricot")
        XCTAssertEqual(params["engine"]?.stringValue, "claude-code")
        XCTAssertEqual(params["title"]?.stringValue, "apricot")
        XCTAssertNil(params["host"],
                     "the worktree stamp chooses the host; do not send a second one")
    }

    func testBlankTitleIsOmitted() {
        let params = RemoteAgentStart.terminalCreateParams(
            worktreeId: "repo::/srv/wt", engineID: "claude")
        XCTAssertNil(params["title"])
    }

    func testPaneRefReadsASuccessfulEnvelope() throws {
        let response = RPCResponse.success(id: "1", result: .object([
            "handle": .string("term_abc"),
            "paneKey": .string("pane_1"),
            "engine": .string("claude-code"),
            "executionHostId": .string("ssh:orchard-loopback"),
        ]))
        let pane = try RemoteAgentStart.paneRef(from: response)
        XCTAssertEqual(pane.handle, "term_abc")
        XCTAssertEqual(pane.paneKey, "pane_1")
        XCTAssertEqual(pane.engineID, "claude-code")
        XCTAssertEqual(pane.executionHostId, "ssh:orchard-loopback")
    }

    func testPaneRefSurfacesTheHandlerCode() {
        let response = RPCResponse.failure(
            id: "1",
            error: RPCError(code: "unknown_engine",
                            message: "engine 'nonesuch' isn't registered"))
        XCTAssertThrowsError(try RemoteAgentStart.paneRef(from: response)) { error in
            let typed = error as? RemoteAgentStartError
            XCTAssertEqual(typed?.code, "unknown_engine")
            XCTAssertEqual(
                RemoteAgentStart.describe(error),
                "unknown_engine: engine 'nonesuch' isn't registered")
        }
    }

    func testPaneRefRefusesASuccessWithNoHandle() {
        let response = RPCResponse.success(id: "1", result: .object([:]))
        XCTAssertThrowsError(try RemoteAgentStart.paneRef(from: response)) { error in
            let typed = error as? RemoteAgentStartError
            XCTAssertEqual(typed?.code, "invalid_argument")
            XCTAssertTrue(RemoteAgentStart.describe(error).contains("no handle"))
        }
    }

    func testInlineFailureAlwaysHasABody() {
        XCTAssertEqual(
            RemoteAgentStart.inlineFailure(code: "host_unverifiable", message: "loss of contact"),
            "host_unverifiable: loss of contact")
        XCTAssertEqual(
            RemoteAgentStart.inlineFailure(code: "unknown_engine",
                                           message: "unknown_engine: already coded"),
            "unknown_engine: already coded")
        XCTAssertEqual(RemoteAgentStart.inlineFailure(code: "invalid_argument", message: ""),
                       "invalid_argument")
        XCTAssertFalse(RemoteAgentStart.inlineFailure(code: "", message: "").isEmpty)
    }

    func testDescribeKeepsTypedCodes() {
        XCTAssertEqual(
            RemoteAgentStart.describe(WorkspaceError("remote_unsupported", "files live elsewhere")),
            "remote_unsupported: files live elsewhere")
        XCTAssertEqual(
            RemoteAgentStart.describe(RemoteHostError.unverifiable(
                host: "build", doing: "starting an agent", reason: "connection refused")),
            RemoteAgentStart.inlineFailure(
                code: "host_unverifiable",
                message: RemoteHostError.unverifiable(
                    host: "build", doing: "starting an agent", reason: "connection refused")
                    .message))
        XCTAssertFalse(RemoteAgentStart.describe(RemoteHostError.unverifiable(
            host: "build", doing: "starting", reason: "refused"))
            .localizedCaseInsensitiveContains("deleted"))
    }
}
