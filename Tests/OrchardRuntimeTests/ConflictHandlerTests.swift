import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// RPC contract for `conflicts list|show|take|resolve|stage` through the in-memory
/// server seam, against real merge conflicts the tests create.
@MainActor
final class ConflictHandlerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-conflict-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func git(_ args: [String], cwd: URL) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        proc.environment = env
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func write(_ text: String, to name: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in repo: URL) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    /// `main` and `feature` disagree on one middle line of `file.txt`.
    private func makeConflictedRepo(name: String = "repo",
                                    file: String = "file.txt") throws -> URL {
        let repo = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(try git(["init", "-q", "-b", "main"], cwd: repo), 0)
        try git(["config", "user.email", "test@orchard.app"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        try write("top\nmiddle\nbottom\n", to: file, in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)

        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try write("top\nfeature line\nbottom\n", to: file, in: repo)
        try git(["commit", "-qam", "feature edit"], cwd: repo)

        try git(["checkout", "-q", "main"], cwd: repo)
        try write("top\nmain line\nbottom\n", to: file, in: repo)
        try git(["commit", "-qam", "main edit"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)
        return repo
    }

    private func makeTwoHunkRepo() throws -> URL {
        let repo = tmp.appendingPathComponent("multi")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: repo)
        try git(["config", "user.email", "t@o.app"], cwd: repo)
        try git(["config", "user.name", "T"], cwd: repo)
        try write("a\nx\nb\nc\nd\ne\nf\ng\ny\nz\n", to: "f.txt", in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try write("a\nX-them\nb\nc\nd\ne\nf\ng\nY-them\nz\n", to: "f.txt", in: repo)
        try git(["commit", "-qam", "them"], cwd: repo)
        try git(["checkout", "-q", "main"], cwd: repo)
        try write("a\nX-us\nb\nc\nd\ne\nf\ng\nY-us\nz\n", to: "f.txt", in: repo)
        try git(["commit", "-qam", "us"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)
        return repo
    }

    private func makeDeleteModifyRepo() throws -> URL {
        let repo = tmp.appendingPathComponent("del")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: repo)
        try git(["config", "user.email", "t@o.app"], cwd: repo)
        try git(["config", "user.name", "T"], cwd: repo)
        try write("content\n", to: "doomed.txt", in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try git(["rm", "-q", "doomed.txt"], cwd: repo)
        try git(["commit", "-qm", "drop it"], cwd: repo)
        try git(["checkout", "-q", "main"], cwd: repo)
        try write("content changed\n", to: "doomed.txt", in: repo)
        try git(["commit", "-qam", "keep and edit"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)
        return repo
    }

    private func makeServer(repo: URL) throws -> (InMemoryRuntimeServer, Workspace) {
        let service = WorkspaceService(dataURL: tmp.appendingPathComponent("orchard-data.json"))
        let record = try service.addRepo(path: repo, kind: .folder)
        let workspace = try XCTUnwrap(try service.listWorkspaces(repo: record.id).first)
        var registry = CommandRegistry()
        registry.register(ConflictsCommandHandler(workspaces: service))
        let server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_conflicts")
        return (server, workspace)
    }

    private func call(_ server: InMemoryRuntimeServer, _ method: String,
                      _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    private func object(_ response: RPCResponse) throws -> [String: JSONValue] {
        XCTAssertTrue(response.ok, response.error.map { "\($0.code): \($0.message)" } ?? "not ok")
        return try XCTUnwrap(response.result?.objectValue)
    }

    // MARK: - list / show

    func testListReportsMergeAndConflictedFile() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)

        let listed = await call(server, "conflicts-list", ["worktree": .string(workspace.id)])
        let obj = try object(listed)
        XCTAssertEqual(obj["operation"]?.stringValue, "merge")
        XCTAssertEqual(obj["fileCount"]?.intValue, 1)
        XCTAssertEqual(obj["isActive"]?.boolValue, true)
        XCTAssertEqual(obj["headline"]?.stringValue, "Merge in progress — 1 conflicted file")
        XCTAssertEqual(obj["oursLabel"]?.stringValue, "Ours (current)")
        let files = try XCTUnwrap(obj["files"]?.arrayValue)
        XCTAssertEqual(files.first?.objectValue?["path"]?.stringValue, "file.txt")
        XCTAssertEqual(files.first?.objectValue?["kind"]?.stringValue, "bothModified")
        XCTAssertEqual(files.first?.objectValue?["kindCode"]?.stringValue, "UU")
        XCTAssertEqual(files.first?.objectValue?["hasInlineMarkers"]?.boolValue, true)
    }

    func testShowReturnsTheConflictedHunk() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)

        let shown = await call(server, "conflicts-show", [
            "worktree": .string(workspace.id),
            "path": .string("file.txt"),
        ])
        let obj = try object(shown)
        XCTAssertEqual(obj["path"]?.stringValue, "file.txt")
        XCTAssertEqual(obj["readable"]?.boolValue, true)
        XCTAssertEqual(obj["hunkCount"]?.intValue, 1)
        XCTAssertEqual(obj["hasConflictMarkers"]?.boolValue, true)
        let hunk = try XCTUnwrap(obj["hunks"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(hunk["index"]?.intValue, 0)
        XCTAssertEqual(hunk["ours"]?.arrayValue?.compactMap(\.stringValue), ["main line"])
        XCTAssertEqual(hunk["theirs"]?.arrayValue?.compactMap(\.stringValue), ["feature line"])
        XCTAssertEqual(obj["stages"]?.objectValue?["ours"]?.stringValue, "top\nmain line\nbottom\n")
        XCTAssertEqual(obj["stages"]?.objectValue?["theirs"]?.stringValue, "top\nfeature line\nbottom\n")
    }

    func testShowAcceptsPathAsPositionalShapeViaPathFlag() async throws {
        let repo = try makeConflictedRepo(file: "a folder/with space.txt")
        let (server, workspace) = try makeServer(repo: repo)
        let shown = await call(server, "conflicts-show", [
            "worktree": .string(workspace.id),
            "path": .string("a folder/with space.txt"),
        ])
        XCTAssertTrue(shown.ok, shown.error?.message ?? "")
        XCTAssertEqual(shown.result?.objectValue?["path"]?.stringValue, "a folder/with space.txt")
    }

    // MARK: - take / resolve / stage

    func testTakeOursStagesThatSide() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let taken = await call(server, "conflicts-take", [
            "worktree": .string(workspace.id),
            "path": .string("file.txt"),
            "side": .string("ours"),
        ])
        let obj = try object(taken)
        XCTAssertEqual(obj["side"]?.stringValue, "ours")
        XCTAssertEqual(obj["staged"]?.boolValue, true)
        XCTAssertEqual(obj["deleted"]?.boolValue, false)
        XCTAssertEqual(read("file.txt", in: repo), "top\nmain line\nbottom\n")

        let listed = await call(server, "conflicts-list", ["worktree": .string(workspace.id)])
        XCTAssertEqual(try object(listed)["fileCount"]?.intValue, 0)
        XCTAssertEqual(try object(listed)["nextStepHint"]?.stringValue,
                       "Run `git commit` in a terminal to finish the merge.")
    }

    func testTakeDeletingSideRemovesTheFile() async throws {
        let repo = try makeDeleteModifyRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let shown = await call(server, "conflicts-show", [
            "worktree": .string(workspace.id),
            "path": .string("doomed.txt"),
        ])
        let showObj = try object(shown)
        XCTAssertEqual(showObj["kind"]?.stringValue, "deletedByThem")
        XCTAssertEqual(showObj["hunkCount"]?.intValue, 0)
        XCTAssertEqual(showObj["actionTheirs"]?.stringValue, "Keep theirs (delete file)")

        let taken = await call(server, "conflicts-take", [
            "worktree": .string(workspace.id),
            "path": .string("doomed.txt"),
            "side": .string("theirs"),
        ])
        XCTAssertEqual(try object(taken)["deleted"]?.boolValue, true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("doomed.txt").path))
    }

    func testResolveOneHunkDoesNotStageWhileMarkersRemain() async throws {
        let repo = try makeTwoHunkRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let shown = await call(server, "conflicts-show", [
            "worktree": .string(workspace.id),
            "path": .string("f.txt"),
        ])
        XCTAssertEqual(try object(shown)["hunkCount"]?.intValue, 2)

        let partial = await call(server, "conflicts-resolve", [
            "worktree": .string(workspace.id),
            "path": .string("f.txt"),
            "hunk": .number(0),
            "choice": .string("ours"),
        ])
        let obj = try object(partial)
        XCTAssertEqual(obj["remainingHunks"]?.intValue, 1)
        XCTAssertEqual(obj["staged"]?.boolValue, false)
        XCTAssertTrue(read("f.txt", in: repo)?.contains("<<<<<<<") ?? false)

        let listed = await call(server, "conflicts-list", ["worktree": .string(workspace.id)])
        XCTAssertEqual(try object(listed)["fileCount"]?.intValue, 1)

        let done = await call(server, "conflicts-resolve", [
            "worktree": .string(workspace.id),
            "path": .string("f.txt"),
            "hunk": .number(0),
            "choice": .string("theirs"),
        ])
        let finished = try object(done)
        XCTAssertEqual(finished["remainingHunks"]?.intValue, 0)
        XCTAssertEqual(finished["staged"]?.boolValue, true)
        XCTAssertEqual(read("f.txt", in: repo), "a\nX-us\nb\nc\nd\ne\nf\ng\nY-them\nz\n")
    }

    func testStageRefusesWhileMarkersRemain() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let refused = await call(server, "conflicts-stage", [
            "worktree": .string(workspace.id),
            "path": .string("file.txt"),
        ])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, "conflict_markers_remain")
        XCTAssertTrue(refused.error?.message.contains("conflict markers") ?? false,
                      refused.error?.message ?? "")

        try write("top\nby hand\nbottom\n", to: "file.txt", in: repo)
        let staged = await call(server, "conflicts-stage", [
            "worktree": .string(workspace.id),
            "path": .string("file.txt"),
        ])
        XCTAssertEqual(try object(staged)["staged"]?.boolValue, true)
        let listed = await call(server, "conflicts-list", ["worktree": .string(workspace.id)])
        XCTAssertEqual(try object(listed)["fileCount"]?.intValue, 0)
    }

    func testResolveFullyDecidedFileStages() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let resolved = await call(server, "conflicts-resolve", [
            "worktree": .string(workspace.id),
            "path": .string("file.txt"),
            "hunk": .number(0),
            "choice": .string("both"),
        ])
        let obj = try object(resolved)
        XCTAssertEqual(obj["staged"]?.boolValue, true)
        XCTAssertEqual(obj["remainingHunks"]?.intValue, 0)
        XCTAssertEqual(read("file.txt", in: repo), "top\nmain line\nfeature line\nbottom\n")
    }

    // MARK: - typed errors

    func testMissingPathIsInvalidArgument() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let response = await call(server, "conflicts-show", ["worktree": .string(workspace.id)])
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testUnknownSideIsInvalidArgument() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let response = await call(server, "conflicts-take", [
            "worktree": .string(workspace.id),
            "path": .string("file.txt"),
            "side": .string("mine"),
        ])
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testUnresolvedChoiceIsInvalidArgument() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let response = await call(server, "conflicts-resolve", [
            "worktree": .string(workspace.id),
            "path": .string("file.txt"),
            "hunk": .number(0),
            "choice": .string("unresolved"),
        ])
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testNotConflictedIsTyped() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let response = await call(server, "conflicts-show", [
            "worktree": .string(workspace.id),
            "path": .string("nope.txt"),
        ])
        XCTAssertEqual(response.error?.code, "not_conflicted")
    }

    func testHunkOutOfRangeIsTyped() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let response = await call(server, "conflicts-resolve", [
            "worktree": .string(workspace.id),
            "path": .string("file.txt"),
            "hunk": .number(9),
            "choice": .string("ours"),
        ])
        XCTAssertEqual(response.error?.code, "hunk_not_found")
    }

    func testPathEscapeIsTyped() async throws {
        let repo = try makeConflictedRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let response = await call(server, "conflicts-show", [
            "worktree": .string(workspace.id),
            "path": .string("../secret"),
        ])
        XCTAssertEqual(response.error?.code, "path_escape")
    }

    func testMissingWorktreeIsInvalidArgument() async throws {
        let repo = try makeConflictedRepo()
        let (server, _) = try makeServer(repo: repo)
        let response = await call(server, "conflicts-list")
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testGitErrorMappingForMarkers() {
        XCTAssertEqual(ConflictsCommandHandler.code(for: GitError("file.txt still contains conflict markers")),
                       "conflict_markers_remain")
        XCTAssertEqual(ConflictsCommandHandler.code(for: GitError("cannot read conflicted file bin.dat")),
                       "cannot_read")
        XCTAssertEqual(ConflictsCommandHandler.code(for: GitError("git add failed (1)")),
                       "git_error")
    }

    func testListOnACleanRepoIsEmptyNotAnError() async throws {
        let repo = try makeConflictedRepo(name: "clean")
        try git(["merge", "--abort"], cwd: repo)
        let (server, workspace) = try makeServer(repo: repo)
        let listed = await call(server, "conflicts-list", ["worktree": .string(workspace.id)])
        let obj = try object(listed)
        XCTAssertEqual(obj["isActive"]?.boolValue, false)
        XCTAssertEqual(obj["fileCount"]?.intValue, 0)
        XCTAssertEqual(obj["headline"]?.stringValue, "No conflicts")
        XCTAssertEqual(obj["operation"]?.stringValue, "none")
    }

    func testResolveHunkOnDeleteConflictIsInvalidArgument() async throws {
        let repo = try makeDeleteModifyRepo()
        let (server, workspace) = try makeServer(repo: repo)
        let response = await call(server, "conflicts-resolve", [
            "worktree": .string(workspace.id),
            "path": .string("doomed.txt"),
            "hunk": .number(0),
            "choice": .string("ours"),
        ])
        XCTAssertEqual(response.error?.code, "invalid_argument")
        XCTAssertTrue(response.error?.message.contains("no conflict hunks") ?? false,
                      response.error?.message ?? "")
    }
}
