import XCTest
@testable import OrchardRuntime
import OrchardProtocol

/// RPC contract for worktree list|show|current|create|set|rm against the
/// in-memory server seam (no unix socket).
@MainActor
final class WorkspaceHandlerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-ws-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func git(_ args: [String], cwd: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeRepo() throws -> URL {
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: repo)
        try git(["config", "user.email", "t@t.io"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        try "x\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        return repo
    }

    private func makeServer(launcher: (any AgentLaunching)? = nil) throws -> (InMemoryRuntimeServer, WorkspaceService, RepoRecord) {
        let repoPath = try makeRepo()
        let service = WorkspaceService(
            dataURL: tmp.appendingPathComponent("orchard-data.json"),
            agentLauncher: launcher,
            worktreesRoot: tmp.appendingPathComponent("wt"))
        let repo = try service.addRepo(path: repoPath)
        var registry = CommandRegistry()
        registry.register(WorkspaceCommandHandler(service: service))
        let server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_ws")
        return (server, service, repo)
    }

    func testListCreateShowSetCurrentRm() async throws {
        let (server, _, repo) = try makeServer()

        let created = await server.perform(RPCRequest(
            id: "1", method: "worktree-create",
            params: .object([
                "repo": .string(repo.id),
                "name": .string("rpc-one"),
                "comment": .string("from rpc"),
            ])))
        XCTAssertTrue(created.ok, created.error?.message ?? "")
        let createdObj = try XCTUnwrap(created.result?.objectValue)
        let worktree = try XCTUnwrap(createdObj["worktree"]?.objectValue)
        let id = try XCTUnwrap(worktree["id"]?.stringValue)
        XCTAssertTrue(id.hasPrefix("\(repo.id)::"))
        XCTAssertEqual(worktree["comment"]?.stringValue, "from rpc")
        XCTAssertNotNil(createdObj["lineage"])

        let listed = await server.perform(RPCRequest(
            id: "2", method: "worktree-list",
            params: .object(["repo": .string(repo.id)])))
        XCTAssertTrue(listed.ok, listed.error?.message ?? "")
        XCTAssertEqual(listed.result?.objectValue?["totalCount"]?.intValue, 1)

        let shown = await server.perform(RPCRequest(
            id: "3", method: "worktree-show",
            params: .object(["worktree": .string(id)])))
        XCTAssertTrue(shown.ok)
        XCTAssertEqual(shown.result?.objectValue?["worktree"]?.objectValue?["id"]?.stringValue, id)

        let path = try XCTUnwrap(worktree["path"]?.stringValue)
        let current = await server.perform(RPCRequest(
            id: "4", method: "worktree-current",
            params: .object(["cwd": .string(path)])))
        XCTAssertTrue(current.ok)
        XCTAssertEqual(current.result?.objectValue?["worktree"]?.objectValue?["id"]?.stringValue, id)

        let set = await server.perform(RPCRequest(
            id: "5", method: "worktree-set",
            params: .object([
                "worktree": .string(id),
                "display-name": .string("Renamed"),
                "workspace-status": .string("in-review"),
                "issue": .string("99"),
            ])))
        XCTAssertTrue(set.ok, set.error?.message ?? "")
        let setWT = set.result?.objectValue?["worktree"]?.objectValue
        XCTAssertEqual(setWT?["displayName"]?.stringValue, "Renamed")
        XCTAssertEqual(setWT?["workspaceStatus"]?.stringValue, "in-review")
        XCTAssertEqual(setWT?["linkedIssue"]?.stringValue, "99")

        let rm = await server.perform(RPCRequest(
            id: "6", method: "worktree-rm",
            params: .object(["worktree": .string(id), "force": .bool(true)])))
        XCTAssertTrue(rm.ok, rm.error?.message ?? "")
        XCTAssertEqual(rm.result?.objectValue?["removed"]?.boolValue, true)

        let empty = await server.perform(RPCRequest(id: "7", method: "worktree-list",
                                                    params: .object(["repo": .string(repo.id)])))
        XCTAssertEqual(empty.result?.objectValue?["totalCount"]?.intValue, 0)
    }

    func testCreateAgentFirstReturnsHandle() async throws {
        let launcher = InstantLauncher()
        let (server, _, repo) = try makeServer(launcher: launcher)
        let created = await server.perform(RPCRequest(
            id: "a", method: "worktree-create",
            params: .object([
                "repo": .string(repo.id),
                "name": .string("agent-first"),
                "agent": .string("claude-code"),
                "prompt": .string("hello"),
            ])))
        XCTAssertTrue(created.ok, created.error?.message ?? "")
        XCTAssertEqual(
            created.result?.objectValue?["agentTerminalHandle"]?.stringValue,
            "term_instant")
    }

    func testUnknownWorktreeIsTypedError() async throws {
        let (server, _, _) = try makeServer()
        let response = await server.perform(RPCRequest(
            id: "x", method: "worktree-show",
            params: .object(["worktree": .string("nope")])))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unknown_worktree")
        XCTAssertEqual(response.meta?.runtimeId, "rt_ws")
    }

    func testNoParentCreateOmitsParentEvenWithCwd() async throws {
        let (server, _, repo) = try makeServer()
        let parent = await server.perform(RPCRequest(
            id: "p", method: "worktree-create",
            params: .object(["repo": .string(repo.id), "name": .string("p")])))
        let parentPath = try XCTUnwrap(
            parent.result?.objectValue?["worktree"]?.objectValue?["path"]?.stringValue)

        let child = await server.perform(RPCRequest(
            id: "c", method: "worktree-create",
            params: .object([
                "repo": .string(repo.id),
                "name": .string("c"),
                "no-parent": .bool(true),
                "base-branch": .string("main"),
                "cwd": .string(parentPath),
            ])))
        XCTAssertTrue(child.ok, child.error?.message ?? "")
        let lineage = child.result?.objectValue?["lineage"]?.objectValue
        XCTAssertEqual(lineage?["parentWorktreeId"] ?? .null, .null)
        let branch = child.result?.objectValue?["worktree"]?.objectValue?["baseRef"]?.stringValue
        XCTAssertNotNil(branch)
        XCTAssertFalse(branch?.isEmpty ?? true)
    }
}

private final class InstantLauncher: AgentLaunching, @unchecked Sendable {
    func launch(engineID: String, prompt: String, worktree: Worktree,
                title: String?) async throws -> LaunchedAgent {
        LaunchedAgent(terminalHandle: "term_instant") { _ in }
    }
}
