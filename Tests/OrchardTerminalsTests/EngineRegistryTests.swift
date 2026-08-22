import XCTest
import OrchardCore
@testable import OrchardTerminals

/// The extended engine registry: the four agent CLIs plus the generic shell, their
/// launch shapes, and the agent-type vocabulary the status layer reports.
final class EngineRegistryTests: XCTestCase {

    func testRegistryCarriesAllFiveEngines() {
        XCTAssertEqual(AgentEngineRegistry.all.map(\.id),
                       ["claude-code", "codex", "grok", "cursor-agent", "shell"])
        for id in ["claude-code", "codex", "grok", "cursor-agent", "shell"] {
            XCTAssertNotNil(AgentEngineRegistry.engine(id: id))
        }
        XCTAssertNil(AgentEngineRegistry.engine(id: "nope"))
    }

    func testAgentTypeVocabularyMatchesOrca() {
        XCTAssertEqual(ClaudeCodeEngine().agentType, "claude")
        XCTAssertEqual(CodexEngine().agentType, "codex")
        XCTAssertEqual(GrokEngine().agentType, "grok")
        XCTAssertEqual(CursorAgentEngine().agentType, "cursor")
    }

    func testNewTUIEnginesAreLongRunningTypeWhenIdle() {
        for engine in [CodexEngine(), GrokEngine(), CursorAgentEngine()] as [AgentEngine] {
            XCTAssertTrue(engine.usesLongRunningTUI, engine.id)
            XCTAssertEqual(engine.promptDelivery, .typeWhenIdle, engine.id)
            XCTAssertFalse(engine.launchesOwnShell, engine.id)
            let argv = engine.launchArgv(
                task: AgentTask(title: "t", prompt: "p", engineID: engine.id,
                                baseRepoPath: "/tmp"),
                worktree: URL(fileURLWithPath: "/tmp"))
            XCTAssertEqual(argv.count, 1, "\(engine.id) launches bare; prompt is typed later")
            XCTAssertTrue(argv[0].contains(engine.id.hasPrefix("cursor") ? "cursor-agent" : engine.id))
        }
    }

    /// The rebuild keeps Claude's inherited-session-marker stripping — a child agent
    /// must never believe it is a subprocess of the session that launched Orchard.
    func testClaudeEnvMarkerStrippingSurvives() {
        let engine = ClaudeCodeEngine()
        let env = engine.env(base: [
            "PATH": "/usr/bin",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_SSE_PORT": "123",
            "CLAUDE_CODE_SESSION_ID": "abc",
        ])
        XCTAssertEqual(env, ["PATH": "/usr/bin"])
    }

    func testOtherEnginesLeaveEnvAlone() {
        let base = ["PATH": "/usr/bin", "CLAUDECODE": "1"]
        XCTAssertEqual(CodexEngine().env(base: base), base)
        XCTAssertEqual(GrokEngine().env(base: base), base)
        XCTAssertEqual(CursorAgentEngine().env(base: base), base)
    }

    func testEngineLaunchWrapsInLoginShellUnlessEngineOwnsIt() {
        let task = AgentTask(title: "t", prompt: "", engineID: "claude-code",
                             baseRepoPath: "/tmp")
        let wrapped = EngineLaunch.argv(engine: ClaudeCodeEngine(), task: task,
                                        worktree: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(wrapped.count, 4, "\(wrapped)")   // [shell, -l, -c, "exec …"]
        XCTAssertEqual(wrapped[1], "-l")
        XCTAssertEqual(wrapped[2], "-c")
        XCTAssertTrue(wrapped[3].hasPrefix("exec "))

        // The shell engine already is a login shell — no double wrap.
        let shellTask = AgentTask(title: "t", prompt: "echo hi", engineID: "shell",
                                  baseRepoPath: "/tmp")
        let direct = EngineLaunch.argv(engine: GenericShellEngine(), task: shellTask,
                                       worktree: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(direct.contains("-c"))
        XCTAssertFalse(direct.contains { $0.hasPrefix("exec ") })
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(EngineLaunch.shellQuote("plain-arg_1.txt"), "plain-arg_1.txt")
        XCTAssertEqual(EngineLaunch.shellQuote("it's here"), "'it'\\''s here'")
    }
}
