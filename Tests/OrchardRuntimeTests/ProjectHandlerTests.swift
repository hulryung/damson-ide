import XCTest
@testable import OrchardRuntime
import OrchardProtocol

/// RPC contract for `project list|show|current` against the in-memory server seam.
@MainActor
final class ProjectHandlerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-project-rpc-\(UUID().uuidString)")
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

    private func makeRepo(name: String = "repo") throws -> URL {
        let repo = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: repo)
        try git(["config", "user.email", "t@t.io"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        try "x\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        return repo
    }

    private func makeServer() throws -> (InMemoryRuntimeServer, WorkspaceService, RepoRecord) {
        let repoPath = try makeRepo()
        let service = WorkspaceService(
            dataURL: tmp.appendingPathComponent("orchard-data.json"),
            worktreesRoot: tmp.appendingPathComponent("wt"))
        let repo = try service.addRepo(path: repoPath, displayName: "Apricot")
        var registry = CommandRegistry()
        registry.register(WorkspaceCommandHandler(service: service))
        registry.register(ProjectCommandHandler(service: service))
        let server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_proj")
        return (server, service, repo)
    }

    func testListShowCurrent() async throws {
        let (server, _, repo) = try makeServer()

        let listed = await server.perform(RPCRequest(id: "1", method: "project-list"))
        XCTAssertTrue(listed.ok, listed.error?.message ?? "")
        XCTAssertEqual(listed.result?.objectValue?["count"]?.intValue, 1)
        let project = try XCTUnwrap(
            listed.result?.objectValue?["projects"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(project["id"]?.stringValue, repo.id)
        XCTAssertEqual(project["displayName"]?.stringValue, "Apricot")
        XCTAssertEqual(project["kind"]?.stringValue, "git")
        XCTAssertEqual(project["hostId"]?.stringValue, "local")
        XCTAssertEqual(project["worktreeCount"]?.intValue, 1)

        let created = await server.perform(RPCRequest(
            id: "2", method: "worktree-create",
            params: .object(["repo": .string(repo.id), "name": .string("child")])))
        XCTAssertTrue(created.ok, created.error?.message ?? "")
        let childPath = try XCTUnwrap(
            created.result?.objectValue?["worktree"]?.objectValue?["path"]?.stringValue)

        let shown = await server.perform(RPCRequest(
            id: "3", method: "project-show",
            params: .object(["project": .string("Apricot")])))
        XCTAssertTrue(shown.ok, shown.error?.message ?? "")
        let shownProject = shown.result?.objectValue?["project"]?.objectValue
        XCTAssertEqual(shownProject?["id"]?.stringValue, repo.id)
        XCTAssertEqual(shownProject?["worktreeCount"]?.intValue, 2)
        XCTAssertEqual(shown.result?.objectValue?["worktrees"]?.arrayValue?.count, 2)

        let current = await server.perform(RPCRequest(
            id: "4", method: "project-current",
            params: .object(["cwd": .string(childPath)])))
        XCTAssertTrue(current.ok, current.error?.message ?? "")
        XCTAssertEqual(
            current.result?.objectValue?["project"]?.objectValue?["id"]?.stringValue, repo.id)
        XCTAssertEqual(current.result?.objectValue?["worktrees"]?.arrayValue?.count, 2)
    }

    func testShowUnknownIsTypedError() async throws {
        let (server, _, _) = try makeServer()
        let response = await server.perform(RPCRequest(
            id: "x", method: "project-show",
            params: .object(["project": .string("nope")])))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unknown_repo")
    }

    func testShowWithoutSelectorIsTypedError() async throws {
        let (server, _, _) = try makeServer()
        let response = await server.perform(RPCRequest(id: "x", method: "project-show"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testCurrentOutsideWorkspaceIsTypedError() async throws {
        let (server, _, _) = try makeServer()
        let response = await server.perform(RPCRequest(
            id: "x", method: "project-current",
            params: .object(["cwd": .string(tmp.path)])))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "not_in_worktree")
    }
}
