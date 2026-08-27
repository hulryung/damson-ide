import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// RPC contract for `checks list|show` through the in-memory server seam.
///
/// The contract this file exists to pin: an unavailable path is an **answer**
/// (`ok: true`, `status: "unavailable"`, a typed reason), not an RPC error. Only
/// a bad request or an unresolvable workspace is `ok: false`.
@MainActor
final class ChecksHandlerTests: XCTestCase {
    private var tmp: URL!
    private var probe: FixtureGitHubCLI!

    static func git(_ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                      "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-checks-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        probe = FixtureGitHubCLI()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private let rollup = """
    [{"__typename":"CheckRun","name":"build","workflowName":"CI","status":"COMPLETED",
      "conclusion":"FAILURE",
      "detailsUrl":"https://github.com/o/r/actions/runs/12/job/34"},
     {"__typename":"CheckRun","name":"lint","workflowName":"CI","status":"COMPLETED",
      "conclusion":"SUCCESS",
      "detailsUrl":"https://github.com/o/r/actions/runs/12/job/35"}]
    """

    private func prJSON(checks: String) -> String {
        """
        {"number":7,"title":"Add checks","url":"https://github.com/o/r/pull/7",
         "state":"OPEN","isDraft":false,"headRefName":"feature/x","headRefOid":"abc123",
         "statusCheckRollup":\(checks)}
        """
    }

    /// A real registered git workspace plus a scripted `gh`, so the handler is
    /// exercised end to end without a network.
    private func makeServer(
        facts: ChecksGitFacts = ChecksGitFacts(branch: "feature/x", headSha: "abc123",
                                               isRepository: true)
    ) throws -> (InMemoryRuntimeServer, Workspace, WorkspaceService) {
        // A real git checkout: the checks verbs refuse a folder workspace by design,
        // so a folder-backed fixture would test the wrong refusal.
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Self.git(["init", "-q", "-b", "feature/x"], cwd: repo)
        try Self.git(["config", "user.email", "t@o.app"], cwd: repo)
        try Self.git(["config", "user.name", "T"], cwd: repo)
        try Self.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        let service = WorkspaceService(dataURL: tmp.appendingPathComponent("orchard-data.json"))
        let record = try service.addRepo(path: repo, kind: .git)
        let workspace = try XCTUnwrap(try service.listWorkspaces(repo: record.id).first)
        let checks = ChecksService(probe: probe, gitFacts: { _ in facts }, ttl: 45, timeout: 1)
        var registry = CommandRegistry()
        registry.register(ChecksCommandHandler(checks: checks, workspaces: service))
        registry.register(WorkspaceCommandHandler(service: service))
        return (InMemoryRuntimeServer(registry: registry, runtimeId: "rt_checks"),
                workspace, service)
    }

    private func call(_ server: InMemoryRuntimeServer, _ method: String,
                      _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    private func object(_ response: RPCResponse) throws -> [String: JSONValue] {
        XCTAssertTrue(response.ok, response.error.map { "\($0.code): \($0.message)" } ?? "not ok")
        return try XCTUnwrap(response.result?.objectValue)
    }

    // MARK: - checks list

    func testListReturnsThePullRequestItsChecksAndTheRollup() async throws {
        let (server, workspace, _) = try makeServer()
        probe.script(["pr", "view"], GitHubCLIOutcome(status: 0, stdout: prJSON(checks: rollup),
                                                      executablePath: "/fixture/gh"))

        let obj = try object(await call(server, "checks-list",
                                        ["worktree": .string(workspace.id)]))
        XCTAssertEqual(obj["status"]?.stringValue, "available")
        XCTAssertEqual(obj["branch"]?.stringValue, "feature/x")
        XCTAssertEqual(obj["headSha"]?.stringValue, "abc123")
        XCTAssertEqual(obj["checkCount"]?.intValue, 2)
        XCTAssertEqual(obj["rollup"]?.stringValue, "fail")
        XCTAssertEqual(obj["rollupLabel"]?.stringValue, "Checks failed")
        XCTAssertEqual(obj["pullRequest"]?.objectValue?["number"]?.intValue, 7)
        // Every result states its own age, so no consumer can present a cached
        // reading as current by accident.
        XCTAssertNotNil(obj["ageSeconds"]?.numberValue)
        XCTAssertNotNil(obj["observedAt"]?.numberValue)
    }

    func testUnavailableIsAnOkAnswerWithATypedReasonNotAnError() async throws {
        let (server, workspace, _) = try makeServer()
        probe.script(["pr", "view"], GitHubCLIOutcome(
            status: 1, stderr: "no pull requests found for branch \"feature/x\"",
            executablePath: "/fixture/gh"))

        let response = await call(server, "checks-list", ["worktree": .string(workspace.id)])
        XCTAssertTrue(response.ok, "a branch with no PR is an answer, not a failure")
        let obj = try object(response)
        XCTAssertEqual(obj["status"]?.stringValue, "unavailable")
        let reason = try XCTUnwrap(obj["unavailable"]?.objectValue)
        XCTAssertEqual(reason["code"]?.stringValue, "no_pull_request")
        XCTAssertEqual(reason["headline"]?.stringValue, "No pull request")
        XCTAssertFalse((reason["detail"]?.stringValue ?? "").isEmpty)
        XCTAssertFalse((reason["remedy"]?.stringValue ?? "").isEmpty)
        // And no invented state comes along with it.
        XCTAssertEqual(obj["checkCount"]?.intValue, 0)
        XCTAssertEqual(obj["rollup"]?.stringValue, "unknown")
        XCTAssertNil(obj["pullRequest"])
    }

    func testUnresolvableWorkspaceIsAnRPCError() async throws {
        let (server, _, _) = try makeServer()
        let response = await call(server, "checks-list", ["worktree": .string("id:nope")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unknown_worktree")

        let missing = await call(server, "checks-list")
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error?.code, "invalid_argument")
    }

    func testListCarriesTheWorkspacesTypedLinks() async throws {
        let (server, workspace, _) = try makeServer()
        probe.script(["pr", "view"], GitHubCLIOutcome(status: 0, stdout: prJSON(checks: "[]"),
                                                      executablePath: "/fixture/gh"))
        _ = await call(server, "worktree-set", [
            "worktree": .string(workspace.id),
            "issue": .string("ENG-412"),
            "link-kind": .string("linear-issue"),
        ])
        let obj = try object(await call(server, "checks-list",
                                        ["worktree": .string(workspace.id)]))
        let links = try XCTUnwrap(obj["links"]?.arrayValue)
        XCTAssertEqual(links.first?.objectValue?["kind"]?.stringValue, "linear-issue")
        XCTAssertEqual(links.first?.objectValue?["identifier"]?.stringValue, "ENG-412")
    }

    func testUnknownLinkKindIsRefusedRatherThanSilentlyDropped() async throws {
        let (server, workspace, _) = try makeServer()
        let response = await call(server, "worktree-set", [
            "worktree": .string(workspace.id),
            "issue": .string("ENG-412"),
            "link-kind": .string("notion"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
        XCTAssertTrue(response.error?.message.contains("linear-issue") ?? false)
    }

    // MARK: - checks show

    func testShowFetchesOneJobLog() async throws {
        let (server, workspace, _) = try makeServer()
        probe.script(["pr", "view"], GitHubCLIOutcome(status: 0, stdout: prJSON(checks: rollup),
                                                      executablePath: "/fixture/gh"))
        probe.script(["run", "view"], GitHubCLIOutcome(
            status: 0, stdout: "step one\nstep two\nboom\n", executablePath: "/fixture/gh"))

        let obj = try object(await call(server, "checks-show", [
            "worktree": .string(workspace.id), "check": .string("build"),
        ]))
        XCTAssertEqual(obj["status"]?.stringValue, "available")
        XCTAssertEqual(obj["log"]?.stringValue, "step one\nstep two\nboom")
        XCTAssertEqual(obj["totalLines"]?.intValue, 3)
        XCTAssertEqual(obj["truncated"]?.boolValue, false)
        XCTAssertEqual(obj["check"]?.objectValue?["name"]?.stringValue, "build")
        XCTAssertEqual(obj["pullRequest"]?.objectValue?["number"]?.intValue, 7)
    }

    func testShowStatesItsOwnTruncation() async throws {
        let (server, workspace, _) = try makeServer()
        probe.script(["pr", "view"], GitHubCLIOutcome(status: 0, stdout: prJSON(checks: rollup),
                                                      executablePath: "/fixture/gh"))
        probe.script(["run", "view"], GitHubCLIOutcome(
            status: 0, stdout: (1...50).map { "l\($0)" }.joined(separator: "\n"),
            executablePath: "/fixture/gh"))

        let obj = try object(await call(server, "checks-show", [
            "worktree": .string(workspace.id), "check": .string("build"),
            "limit": .number(5),
        ]))
        XCTAssertEqual(obj["truncated"]?.boolValue, true)
        XCTAssertEqual(obj["totalLines"]?.intValue, 50)
        XCTAssertEqual(obj["returnedLines"]?.intValue, 5)
        XCTAssertTrue(obj["log"]?.stringValue?.hasSuffix("l50") ?? false)
    }

    func testShowRefusesAnUnknownCheckAndListsWhatItHas() async throws {
        let (server, workspace, _) = try makeServer()
        probe.script(["pr", "view"], GitHubCLIOutcome(status: 0, stdout: prJSON(checks: rollup),
                                                      executablePath: "/fixture/gh"))
        let response = await call(server, "checks-show", [
            "worktree": .string(workspace.id), "check": .string("deploy"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "check_not_found")
        XCTAssertTrue(response.error?.message.contains("build") ?? false)
        XCTAssertTrue(response.error?.message.contains("lint") ?? false)
    }

    /// Asking to show a check when the snapshot could not be taken must repeat the
    /// snapshot's own reason — not a misleading "check not found".
    func testShowSurfacesTheSnapshotsReasonWhenThereAreNoChecksToLookAt() async throws {
        let (server, workspace, _) = try makeServer()
        probe.script(["pr", "view"], GitHubCLIOutcome(
            status: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login",
            executablePath: "/fixture/gh"))
        let response = await call(server, "checks-show", [
            "worktree": .string(workspace.id), "check": .string("build"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "gh_not_authenticated")
        XCTAssertTrue(response.error?.message.contains("gh auth login") ?? false)
    }

    func testShowRequiresACheckSelector() async throws {
        let (server, workspace, _) = try makeServer()
        let response = await call(server, "checks-show", ["worktree": .string(workspace.id)])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testSelectionMatchesExactlyThenUniquelyAndRefusesAmbiguity() {
        let checks = [
            CheckRunSummary(id: "u1", name: "build (macos)", kind: "CheckRun", bucket: .pass,
                            jobId: "34"),
            CheckRunSummary(id: "u2", name: "build (linux)", kind: "CheckRun", bucket: .pass),
            CheckRunSummary(id: "u3", name: "lint", kind: "CheckRun", bucket: .pass),
        ]
        XCTAssertEqual(ChecksSelection.match("u2", in: checks)?.id, "u2")
        XCTAssertEqual(ChecksSelection.match("build (linux)", in: checks)?.id, "u2")
        XCTAssertEqual(ChecksSelection.match("34", in: checks)?.id, "u1")
        XCTAssertEqual(ChecksSelection.match("lin", in: checks)?.id, "u3")
        // "build" prefixes two: picking one would be a guess.
        XCTAssertNil(ChecksSelection.match("build", in: checks))
        XCTAssertNil(ChecksSelection.match("  ", in: checks))
    }
}
