import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// The terminal RPC surface end to end through the T0 seam: registry routing, the
/// wire shapes of each verb's result, and the typed error envelopes — everything the
/// T2 socket server will carry, minus the socket.
final class TerminalHandlerTests: XCTestCase {
    private var sessions: [String: ScriptedTerminalSession] = [:]
    private var server: InMemoryRuntimeServer!
    private var service: TerminalService!

    @MainActor
    override func setUp() {
        super.setUp()
        sessions = [:]
        var detector = ReadinessDetector.Config()
        detector.idleDebounce = 1
        detector.spawnFloor = 0
        var pipeline = SendPipelineConfig()
        pipeline.submitDelay = 0.02
        pipeline.verifyTimeout = 0.3
        pipeline.verifyPollInterval = 0.01
        let service = TerminalService(
            factory: { [weak self] spec, _ in
                let session = ScriptedTerminalSession()
                self?.sessions[spec.handle] = session
                return session
            },
            pipeline: pipeline,
            detectorConfig: detector)
        self.service = service
        var registry = CommandRegistry()
        registry.register(TerminalCommandHandler(service: service))
        server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_terminals")
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
        throw CancellationError()
    }

    private func createTerminal(engine: String = "shell",
                                worktree: String? = nil) async throws -> (handle: String, paneKey: String) {
        var params: [String: JSONValue] = ["engine": .string(engine)]
        if let worktree { params["worktree"] = .string(worktree) }
        let response = await call("terminal-create", params)
        XCTAssertTrue(response.ok, "\(String(describing: response.error))")
        let object = try XCTUnwrap(response.result?.objectValue)
        return (try XCTUnwrap(object["handle"]?.stringValue),
                try XCTUnwrap(object["paneKey"]?.stringValue))
    }

    // MARK: - Verb coverage

    func testCreateAndListRoundTrip() async throws {
        let terminal = try await createTerminal(engine: "shell", worktree: "repo::wt")
        let response = await call("terminal-list", ["worktree": .string("repo::wt")])
        XCTAssertTrue(response.ok)
        let object = try XCTUnwrap(response.result?.objectValue)
        let terminals = try XCTUnwrap(object["terminals"])
        guard case let .array(rows) = terminals, case let .object(row)? = rows.first else {
            return XCTFail("expected terminals array, got \(terminals)")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row["handle"]?.stringValue, terminal.handle)
        XCTAssertEqual(row["worktreeId"]?.stringValue, "repo::wt")
        XCTAssertEqual(row["connected"], .bool(true))
        XCTAssertEqual(object["totalCount"], .number(1))

        let empty = await call("terminal-list", ["worktree": .string("other")])
        XCTAssertEqual(empty.result?.objectValue?["totalCount"], .number(0))
    }

    func testReadReportsSourceStreamAndScreen() async throws {
        let terminal = try await createTerminal()
        await MainActor.run {
            sessions[terminal.handle]?.emitOutput("hello wire\n")
            sessions[terminal.handle]?.showScreen(["$ hello wire"])
        }
        let stream = await call("terminal-read", ["terminal": .string(terminal.handle)])
        XCTAssertTrue(stream.ok)
        XCTAssertEqual(stream.result?.objectValue?["source"]?.stringValue, "stream")

        let screen = await call("terminal-read", ["terminal": .string(terminal.handle),
                                                 "screen": .bool(true)])
        XCTAssertEqual(screen.result?.objectValue?["source"]?.stringValue, "screen")
        XCTAssertEqual(screen.result?.objectValue?["lines"],
                       .array([.string("$ hello wire")]))
    }

    func testSendGuardRefusalIsTypedNotAnError() async throws {
        let terminal = try await createTerminal(engine: "shell")
        let response = await call("terminal-send", [
            "terminal": .string(terminal.handle),
            "text": .string("prompt"),
            "enter": .bool(true),
            "requireAgent": .bool(true),
        ])
        // The refusal is a successful envelope with a typed reason — callers branch on
        // it; only transport-level problems are RPC errors.
        XCTAssertTrue(response.ok)
        let object = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(object["accepted"], .bool(false))
        XCTAssertEqual(object["refusedReason"]?.stringValue, "no-agent")
    }

    func testPlainShellSendWritesThrough() async throws {
        let terminal = try await createTerminal(engine: "shell")
        let response = await call("terminal-send", [
            "terminal": .string(terminal.handle),
            "text": .string("echo hi"),
            "enter": .bool(true),
        ])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.objectValue?["accepted"], .bool(true))
        let written = await MainActor.run { sessions[terminal.handle]!.writtenText }
        XCTAssertTrue(written.contains("echo hi"))
        XCTAssertTrue(written.hasSuffix("\r"))
    }

    func testWaitForExitOverTheWire() async throws {
        let terminal = try await createTerminal(engine: "shell")
        async let pending = call("terminal-wait", [
            "terminal": .string(terminal.handle),
            "for": .string("exit"),
            "timeoutMs": .number(2000),
        ])
        try await waitUntil("exit waiter parked") { [service] in
            (try? service!.waiterCount(handle: terminal.handle)) == 1
        }
        await MainActor.run { sessions[terminal.handle]?.exit(code: 7) }
        let response = await pending
        XCTAssertTrue(response.ok)
        let object = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(object["satisfied"], .bool(true))
        XCTAssertEqual(object["exitCode"], .number(7))
    }

    func testWaitRequiresKnownCondition() async throws {
        let terminal = try await createTerminal()
        let response = await call("terminal-wait", ["terminal": .string(terminal.handle),
                                                    "for": .string("nirvana")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testRenameAndCloseVerbs() async throws {
        let terminal = try await createTerminal()
        let renamed = await call("terminal-rename", ["terminal": .string(terminal.handle),
                                                     "title": .string("worker-1")])
        XCTAssertEqual(renamed.result?.objectValue?["title"]?.stringValue, "worker-1")

        let closed = await call("terminal-close", ["terminal": .string(terminal.handle)])
        XCTAssertTrue(closed.ok)
        XCTAssertEqual(closed.result?.objectValue?["closed"], .bool(true))

        let after = await call("terminal-read", ["terminal": .string(terminal.handle)])
        XCTAssertFalse(after.ok)
        XCTAssertEqual(after.error?.code, "terminal_not_found")
    }

    func testSplitIsAnHonestStub() async throws {
        let response = await call("terminal-split", ["terminal": .string("term_x")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "not_implemented")
    }

    func testUnknownTerminalIsTypedError() async {
        let response = await call("terminal-read", ["terminal": .string("term_missing")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "terminal_not_found")
        XCTAssertEqual(response.meta?.runtimeId, "rt_terminals",
                       "even failures carry the runtime identity")
    }

    func testMissingHandleParamIsInvalidArgument() async {
        let response = await call("terminal-send", ["text": .string("hi")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    @MainActor
    func testCreateResolvesPathSelectorToProjectedPrimaryCheckout() async throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-term-primary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = tmp.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@t.io"])
        try git(["config", "user.name", "Test"])
        try "x\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "init"])

        let workspaces = WorkspaceService(
            dataURL: tmp.appendingPathComponent("orchard-data.json"),
            worktreesRoot: tmp.appendingPathComponent("wt"))
        let record = try workspaces.addRepo(path: repo)
        var detector = ReadinessDetector.Config()
        detector.idleDebounce = 1
        detector.spawnFloor = 0
        var pipeline = SendPipelineConfig()
        pipeline.submitDelay = 0.02
        pipeline.verifyTimeout = 0.3
        pipeline.verifyPollInterval = 0.01
        let service = TerminalService(
            factory: { spec, _ in ScriptedTerminalSession() },
            pipeline: pipeline,
            detectorConfig: detector)
        var registry = CommandRegistry()
        registry.register(TerminalCommandHandler(service: service, workspaces: workspaces))
        let local = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_term_primary")

        let created = await local.perform(RPCRequest(
            method: "terminal-create",
            params: .object([
                "engine": .string("shell"),
                "worktree": .string("path:\(repo.path)"),
            ])))
        XCTAssertTrue(created.ok, String(describing: created.error))
        let worktreeId = created.result?.objectValue?["worktreeId"]?.stringValue
        XCTAssertEqual(worktreeId, "\(record.id)::\(repo.standardizedFileURL.path)")

        let unknown = await local.perform(RPCRequest(
            method: "terminal-create",
            params: .object([
                "engine": .string("shell"),
                "worktree": .string("path:/does/not/exist"),
            ])))
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.error?.code, "unknown_worktree")
    }
}
