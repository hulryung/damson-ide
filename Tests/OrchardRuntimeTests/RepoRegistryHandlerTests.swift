import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// T61: `repo remove` refuses while extra worktrees or automations still name
/// the repo, then drops the registry row + orchard-data when they don't.
@MainActor
final class RepoRegistryHandlerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-repo-rm-\(UUID().uuidString)")
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

    private func makeHandler() throws -> (RepoRegistryHandler, WorkspaceService) {
        let service = WorkspaceService(
            dataURL: tmp.appendingPathComponent("orchard-data.json"),
            worktreesRoot: tmp.appendingPathComponent("wt"))
        return (RepoRegistryHandler(service: service), service)
    }

    private func call(_ handler: RepoRegistryHandler, _ method: String,
                      _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await handler.handle(RPCRequest(method: method, params: .object(params)))
    }

    func testRemovePrimaryOnlyCleansRegistryAndOrchardData() async throws {
        let (handler, service) = try makeHandler()
        let path = try makeRepo()
        let added = await call(handler, "repo-add", [
            "path": .string(path.path), "display-name": .string("Scratch"),
        ])
        XCTAssertTrue(added.ok, added.error?.message ?? "")
        let id = try XCTUnwrap(added.result?.objectValue?["id"]?.stringValue)
        XCTAssertEqual(try service.listWorkspaces(repo: id).count, 1)

        let removed = await call(handler, "repo-remove", ["repo": .string(id)])
        XCTAssertTrue(removed.ok, removed.error?.message ?? "")
        XCTAssertEqual(removed.result?.objectValue?["removed"]?.boolValue, true)
        XCTAssertEqual(removed.result?.objectValue?["displayName"]?.stringValue, "Scratch")
        XCTAssertEqual(removed.result?.objectValue?["id"]?.stringValue, id)

        XCTAssertTrue(service.listRepos().isEmpty)
        let data = service.store.load()
        XCTAssertTrue(data.repos.isEmpty)
        XCTAssertTrue(data.folderWorkspaces.isEmpty)
        XCTAssertTrue(data.worktreeMeta.isEmpty)
        XCTAssertTrue(data.worktreeLineageById.isEmpty)
        XCTAssertTrue(data.retiredWorktreeNamesByRepo.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testRemoveRefusesWhileExtraWorktreeReferencesRepo() async throws {
        let (handler, service) = try makeHandler()
        let path = try makeRepo()
        let record = try service.addRepo(path: path, displayName: "HasTree")
        let created = try await service.create(
            WorkspaceCreateRequest(repo: record.id, name: "keep-me"))

        let refused = await call(handler, "repo-remove", ["repo": .string(record.id)])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, "repo_in_use")
        let message = try XCTUnwrap(refused.error?.message)
        XCTAssertTrue(message.contains("keep-me"), message)
        XCTAssertTrue(message.contains("HasTree"), message)
        XCTAssertTrue(message.contains("worktrees"), message)
        let named = refused.error?.data?.objectValue?["worktrees"]?.arrayValue ?? []
        XCTAssertEqual(named.count, 1)
        XCTAssertEqual(named.first?.objectValue?["displayName"]?.stringValue, created.workspace.displayName)
        XCTAssertEqual(service.listRepos().map(\.id), [record.id])

        _ = try service.remove(selector: created.workspace.id, force: true)
        let removed = await call(handler, "repo-remove", ["id": .string(record.id)])
        XCTAssertTrue(removed.ok, removed.error?.message ?? "")
        XCTAssertTrue(service.listRepos().isEmpty)
    }

    func testRemoveRefusesWhileAutomationTargetsRepo() async throws {
        let (handler, service) = try makeHandler()
        let path = try makeRepo()
        let record = try service.addRepo(path: path, displayName: "AutoRepo")
        try service.store.modify { data in
            data.automations.append(Automation(
                name: "nightly-scan",
                trigger: .hourly,
                time: "00:00",
                provider: "shell",
                prompt: "echo hi",
                target: .repo(record.id)))
        }

        let refused = await call(handler, "repo-remove", ["repo": .string(record.displayName)])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, "repo_in_use")
        let message = try XCTUnwrap(refused.error?.message)
        XCTAssertTrue(message.contains("nightly-scan"), message)
        XCTAssertTrue(message.contains("automations"), message)
        XCTAssertEqual(
            refused.error?.data?.objectValue?["automations"]?.arrayValue?.first?
                .objectValue?["name"]?.stringValue,
            "nightly-scan")
        XCTAssertEqual(service.listRepos().map(\.id), [record.id])
    }

    func testRemoveRefusesWhileAutomationTargetsWorkspaceOfRepo() async throws {
        let (handler, service) = try makeHandler()
        let path = try makeRepo()
        let record = try service.addRepo(path: path, displayName: "WSRepo")
        let primary = try XCTUnwrap(try service.listWorkspaces(repo: record.id).first)
        try service.store.modify { data in
            data.automations.append(Automation(
                name: "reuse-pane",
                trigger: .daily,
                time: "09:00",
                provider: "shell",
                prompt: "echo hi",
                target: .workspace(primary.id)))
        }

        let refused = await call(handler, "repo-remove", ["repo": .string(record.id)])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, "repo_in_use")
        let message = try XCTUnwrap(refused.error?.message)
        XCTAssertTrue(message.contains("reuse-pane"), message)
        XCTAssertFalse(message.contains("worktrees:"), message)
        XCTAssertEqual(service.listRepos().count, 1)
    }

    func testRemoveRequiresSelectorAndUnknownRepoIsTyped() async throws {
        let (handler, _) = try makeHandler()
        let missing = await call(handler, "repo-remove")
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error?.code, "invalid_argument")

        let unknown = await call(handler, "repo-remove", ["repo": .string("no-such-repo")])
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.error?.code, "unknown_repo")
    }

    func testRemoveByPathSelector() async throws {
        let (handler, service) = try makeHandler()
        let path = try makeRepo(name: "by-path")
        let record = try service.addRepo(path: path, displayName: "PathRepo")
        let removed = await call(handler, "repo-remove", ["path": .string(path.path)])
        XCTAssertTrue(removed.ok, removed.error?.message ?? "")
        XCTAssertEqual(removed.result?.objectValue?["id"]?.stringValue, record.id)
        XCTAssertTrue(service.listRepos().isEmpty)
    }

    // MARK: - T79 repo remove --forget

    /// Seed a remote repo + primary + one extra projected worktree. No ssh: the
    /// listing path for remotes is the last-known set in orchard-data.
    private func seedRemoteRepo(
        _ service: WorkspaceService,
        displayName: String = "RemoteOrchard"
    ) throws -> (repo: RepoRecord, extraId: String) {
        let repo = RepoRecord(path: "/srv/work/orchard", displayName: displayName,
                              kind: .git, hostId: "ssh:build")
        let extraPath = "/home/ci/Orchard/worktrees/orchard/apricot"
        let extraId = RemoteWorktreeRecord.id(repoId: repo.id, path: extraPath)
        try service.store.modify { data in
            data.repos.append(repo)
            data.remoteWorktrees.append(contentsOf: [
                RemoteWorktreeRecord(
                    id: RemoteWorktreeRecord.id(repoId: repo.id, path: repo.path),
                    repoId: repo.id, hostId: "ssh:build", path: repo.path,
                    branch: "main", isPrimary: true),
                RemoteWorktreeRecord(
                    id: extraId, repoId: repo.id, hostId: "ssh:build",
                    path: extraPath, branch: "ci/apricot"),
            ])
        }
        return (repo, extraId)
    }

    func testForgetDropsRemoteProjectionRowsAndLeavesHostUntouched() async throws {
        let (handler, service) = try makeHandler()
        let seeded = try seedRemoteRepo(service)
        XCTAssertEqual(try service.listWorkspaces(repo: seeded.repo.id).count, 2)

        let refused = await call(handler, "repo-remove", ["repo": .string(seeded.repo.id)])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, "repo_in_use")
        XCTAssertTrue(refused.error?.message.contains("apricot") ?? false,
                      refused.error?.message ?? "")
        XCTAssertEqual(service.listRepos().map(\.id), [seeded.repo.id])
        XCTAssertEqual(service.store.load().remoteWorktrees.count, 2)

        let forgotten = await call(handler, "repo-remove", [
            "repo": .string(seeded.repo.id), "forget": .bool(true),
        ])
        XCTAssertTrue(forgotten.ok, forgotten.error?.message ?? "")
        let object = try XCTUnwrap(forgotten.result?.objectValue)
        XCTAssertEqual(object["removed"]?.boolValue, true)
        XCTAssertEqual(object["forgotten"]?.boolValue, true)
        XCTAssertEqual(object["hostUntouched"]?.boolValue, true)
        XCTAssertEqual(object["displayName"]?.stringValue, "RemoteOrchard")
        let dropped = object["droppedWorktrees"]?.arrayValue ?? []
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first?.objectValue?["id"]?.stringValue, seeded.extraId)
        XCTAssertEqual(dropped.first?.objectValue?["displayName"]?.stringValue, "apricot")
        XCTAssertEqual(dropped.first?.objectValue?["path"]?.stringValue,
                       "/home/ci/Orchard/worktrees/orchard/apricot")

        XCTAssertTrue(service.listRepos().isEmpty)
        XCTAssertTrue(service.store.load().remoteWorktrees.isEmpty)
        XCTAssertTrue(service.store.load().worktreeMeta.isEmpty)
        XCTAssertTrue(try service.listWorkspaces().isEmpty)
    }

    func testForgetRefusesALocalRepoEvenWithOnlyThePrimary() async throws {
        let (handler, service) = try makeHandler()
        let path = try makeRepo()
        let record = try service.addRepo(path: path, displayName: "LocalOnly")
        XCTAssertEqual(try service.listWorkspaces(repo: record.id).count, 1)

        let refused = await call(handler, "repo-remove", [
            "repo": .string(record.id), "forget": .bool(true),
        ])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, "forget_local_refused")
        XCTAssertTrue(refused.error?.message.contains("local") ?? false,
                      refused.error?.message ?? "")
        XCTAssertEqual(refused.error?.data?.objectValue?["hostId"]?.stringValue, "local")
        XCTAssertEqual(service.listRepos().map(\.id), [record.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testForgetRefusesALocalRepoWithExtraWorktreesRatherThanDroppingThem() async throws {
        let (handler, service) = try makeHandler()
        let path = try makeRepo()
        let record = try service.addRepo(path: path, displayName: "HasTree")
        let created = try await service.create(
            WorkspaceCreateRequest(repo: record.id, name: "keep-me"))

        let refused = await call(handler, "repo-remove", [
            "repo": .string(record.id), "forget": .bool(true),
        ])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, "forget_local_refused")
        XCTAssertEqual(service.listRepos().map(\.id), [record.id])
        XCTAssertEqual(try service.listWorkspaces(repo: record.id).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.workspace.path))
    }

    func testForgetStillRefusesARemoteRepoReferencedByAutomations() async throws {
        let (handler, service) = try makeHandler()
        let seeded = try seedRemoteRepo(service, displayName: "AutoRemote")
        try service.store.modify { data in
            data.automations.append(Automation(
                name: "nightly-scan",
                trigger: .hourly,
                time: "00:00",
                provider: "shell",
                prompt: "echo hi",
                target: .repo(seeded.repo.id)))
        }

        let refused = await call(handler, "repo-remove", [
            "repo": .string(seeded.repo.id), "forget": .bool(true),
        ])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.code, "repo_in_use")
        let message = try XCTUnwrap(refused.error?.message)
        XCTAssertTrue(message.contains("nightly-scan"), message)
        XCTAssertTrue(message.contains("automations"), message)
        XCTAssertFalse(message.contains("worktrees:"), message)
        XCTAssertEqual(service.listRepos().map(\.id), [seeded.repo.id])
        XCTAssertEqual(service.store.load().remoteWorktrees.count, 2)
    }
}
