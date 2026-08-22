import XCTest
import OrchardCore
@testable import OrchardTerminals

/// Every agent Orchard starts is an independent top-level session. Launching Orchard from a
/// terminal that is itself inside an agent session must not leak that session's markers into
/// the children — the child changes behavior when it thinks it is a subprocess.
final class AgentEnvironmentTests: XCTestCase {
    func testClaudeEngineStripsInheritedSessionMarkers() {
        let engine = ClaudeCodeEngine()
        let polluted = [
            "PATH": "/usr/bin",
            "HOME": "/Users/someone",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_SSE_PORT": "51234",
            "CLAUDE_CODE_SESSION_ID": "abc123",
        ]
        let clean = engine.env(base: polluted)

        for marker in ClaudeCodeEngine.inheritedSessionMarkers {
            XCTAssertNil(clean[marker], "\(marker) must not reach a spawned agent")
        }
        // Everything unrelated survives — this is a scrub, not a reset.
        XCTAssertEqual(clean["PATH"], "/usr/bin")
        XCTAssertEqual(clean["HOME"], "/Users/someone")
    }

    /// The generic shell engine has no such notion and must pass the environment through.
    func testShellEngineLeavesEnvironmentAlone() {
        let env = ["PATH": "/usr/bin", "CLAUDECODE": "1"]
        XCTAssertEqual(GenericShellEngine().env(base: env), env)
    }
}
