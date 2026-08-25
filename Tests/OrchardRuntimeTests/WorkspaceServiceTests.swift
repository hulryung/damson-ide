import XCTest
@testable import OrchardRuntime
import OrchardProtocol

@MainActor
final class WorkspaceServiceTests: XCTestCase {
    private var tmp: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        storeURL = tmp.appendingPathComponent("orchard-data.json")
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

    private func makeService(launcher: (any AgentLaunching)? = nil) -> WorkspaceService {
        WorkspaceService(dataURL: storeURL, agentLauncher: launcher,
                         worktreesRoot: tmp.appendingPathComponent("wt"))
    }

    // MARK: - Identity + store

    func testWorktreeIdIsRepoIdAndPath() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let created = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "apricot"))
        XCTAssertTrue(created.workspace.id.hasPrefix("\(record.id)::"))
        XCTAssertTrue(created.workspace.id.hasSuffix(created.workspace.path))
        XCTAssertEqual(created.workspace.kind, .worktree)
        XCTAssertFalse(created.workspace.branch.isEmpty)
        XCTAssertFalse(created.workspace.head.isEmpty)
        XCTAssertEqual(created.workspace.hostId, "local")
    }

    func testAtomicStoreRoundTripAndCrashSafeWrite() throws {
        let store = OrchardDataStore(url: storeURL)
        var repo = RepoRecord(path: "/tmp/demo", displayName: "Demo")
        repo.baseRef = "main"
        try store.modify { $0.repos.append(repo) }

        let reloaded = OrchardDataStore(url: storeURL).load()
        XCTAssertEqual(reloaded.repos.count, 1)
        XCTAssertEqual(reloaded.repos[0].displayName, "Demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        // Sibling temp from a crash mid-write is not the destination.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".orchard-data.json.tmp") })
    }

    func testAddRepoIsIdempotentOnTheSamePath() throws {
        let repo = try makeRepo()
        let service = makeService()
        let a = try service.addRepo(path: repo, displayName: "One")
        let b = try service.addRepo(path: repo, displayName: "Two")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(service.listRepos().count, 1)
    }

    // MARK: - Folder workspaces

    func testFolderWorkspaceProjectsWithEmptyBranchAndHead() throws {
        let folder = tmp.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = makeService()
        let repo = try service.addRepo(path: folder, kind: .folder)
        let listed = try service.listWorkspaces(repo: repo.id)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].kind, .folder)
        XCTAssertEqual(listed[0].branch, "")
        XCTAssertEqual(listed[0].head, "")
        XCTAssertEqual(listed[0].id, "\(repo.id)::\(folder.standardizedFileURL.path)")
    }

    func testSecondFolderSessionUsesWorkspaceUUIDIdentity() async throws {
        let folder = tmp.appendingPathComponent("plain2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = makeService()
        let repo = try service.addRepo(path: folder, kind: .folder)
        let extra = try await service.create(WorkspaceCreateRequest(repo: repo.id, name: "session-2"))
        XCTAssertTrue(extra.workspace.id.contains("::workspace:"))
        XCTAssertEqual(extra.workspace.kind, .folder)
        XCTAssertEqual(try service.listWorkspaces(repo: repo.id).count, 2)
    }

    // MARK: - Lineage orthogonality

    func testNoParentDoesNotUseCwdParentAndLeavesBaseBranchIndependent() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let parent = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "parent"))

        let child = try await service.create(WorkspaceCreateRequest(
            repo: record.id,
            name: "child",
            baseBranch: "main",
            noParent: true,
            cwd: parent.workspace.path))
        XCTAssertNil(child.lineage?.parentWorktreeId)
        XCTAssertEqual(child.workspace.baseRef.isEmpty, false)

        let inferred = try await service.create(WorkspaceCreateRequest(
            repo: record.id,
            name: "inferred",
            cwd: parent.workspace.path))
        XCTAssertEqual(inferred.lineage?.parentWorktreeId, parent.workspace.id)
        XCTAssertEqual(inferred.lineage?.capture.confidence, .inferred)
        XCTAssertEqual(inferred.lineage?.capture.source, .cwdContext)
    }

    func testExplicitParentAndNoParentConflictOnSet() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let a = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "a"))
        let b = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "b"))
        XCTAssertThrowsError(try service.update(
            selector: b.workspace.id,
            WorkspaceUpdateRequest(parentWorktree: a.workspace.id, noParent: true)))
    }

    func testStaleLineageDroppedAfterInstanceMismatch() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let created = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "stale"))
        try service.store.modify { data in
            guard var lineage = data.worktreeLineageById[created.workspace.id] else { return }
            lineage.worktreeInstanceId = "NOT-THE-INSTANCE"
            data.worktreeLineageById[created.workspace.id] = lineage
        }
        let shown = try service.show(selector: created.workspace.id)
        XCTAssertNil(shown.lineage)
    }

    // MARK: - Meta / status / set

    func testSetUpdatesMetaAndCustomStatus() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        try service.addStatusDefinition(
            WorkspaceStatusDefinition(id: "blocked", label: "Blocked", color: "rose"))
        let created = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "meta"))
        let updated = try service.update(
            selector: created.workspace.id,
            WorkspaceUpdateRequest(displayName: "Nice name",
                                   comment: "hello",
                                   workspaceStatus: "blocked",
                                   linkedIssue: "12",
                                   linkedPR: "34",
                                   isPinned: true))
        XCTAssertEqual(updated.displayName, "Nice name")
        XCTAssertEqual(updated.comment, "hello")
        XCTAssertEqual(updated.workspaceStatus, "blocked")
        XCTAssertEqual(updated.linkedIssue, "12")
        XCTAssertEqual(updated.linkedPR, "34")
        XCTAssertTrue(updated.isPinned)

        XCTAssertThrowsError(try service.update(
            selector: created.workspace.id,
            WorkspaceUpdateRequest(workspaceStatus: "does-not-exist")))

        let persisted = OrchardDataStore(url: storeURL).load()
        XCTAssertEqual(persisted.worktreeMeta[created.workspace.id]?.workspaceStatus, "blocked")
        XCTAssertTrue(persisted.workspaceStatusVocabulary.contains {
            $0.id == "blocked" && $0.label == "Blocked" && $0.color == "rose"
        })
    }

    // MARK: - Naming retirement

    func testGeneratedNameIsRetiredAcrossDelete() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let first = try await service.create(WorkspaceCreateRequest(repo: record.id))
        let firstLeaf = URL(fileURLWithPath: first.workspace.path).lastPathComponent
        _ = try service.remove(selector: first.workspace.id, force: true)
        let second = try await service.create(WorkspaceCreateRequest(repo: record.id))
        let secondLeaf = URL(fileURLWithPath: second.workspace.path).lastPathComponent
        XCTAssertNotEqual(firstLeaf, secondLeaf)
        let retired = service.store.load().retiredWorktreeNamesByRepo[record.id]
        XCTAssertEqual(RetiredNames.isRetired(firstLeaf, registry: retired ?? .empty,
                                              pool: WorktreeNaming.suggestedNameSet), true)
    }

    // MARK: - current / selectors

    func testCurrentPicksLongestEnclosingWorktree() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let created = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "nested"))
        let nested = created.workspace.path + "/src/pkg"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let current = try service.current(cwd: nested)
        XCTAssertEqual(current.id, created.workspace.id)
        XCTAssertThrowsError(try service.current(cwd: "/tmp"))
    }

    // MARK: - worker-start

    func testWorkerStartReturnsWorktreeIdAndHandle() async throws {
        let repo = try makeRepo()
        let launcher = StubLauncher(handle: "term_test")
        let service = makeService(launcher: launcher)
        let record = try service.addRepo(path: repo)
        let result = try await service.startWorker(
            WorkspaceCreateRequest(repo: record.id, name: "worker", agent: "claude-code",
                                   prompt: "hi"))
        XCTAssertTrue(result.worktreeId.contains("::"))
        XCTAssertEqual(result.agentTerminalHandle, "term_test")
        XCTAssertEqual(result.workspace.lineage?.origin, .orchestration)
        XCTAssertEqual(launcher.lastEngine, "claude-code")
        XCTAssertEqual(launcher.lastPrompt, "hi")
    }

    func testCreateWithoutLauncherRefusesAgentFirst() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        do {
            _ = try await service.create(WorkspaceCreateRequest(
                repo: record.id, name: "no-agent", agent: "claude-code"))
            XCTFail("expected agent_unavailable")
        } catch let err as WorkspaceError {
            XCTAssertEqual(err.code, "agent_unavailable")
        }
    }

    // MARK: - rm preflight

    func testRemoveRefusesDirtyWorktreeWithoutForce() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let created = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "dirty"))
        try "wip\n".write(to: URL(fileURLWithPath: created.workspace.path)
            .appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        let refused = try service.remove(selector: created.workspace.id, force: false)
        XCTAssertFalse(refused.removed)
        XCTAssertFalse(refused.preflightWarnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.workspace.path))
        let forced = try service.remove(selector: created.workspace.id, force: true)
        XCTAssertTrue(forced.removed)
    }

    func testRemovePreflightNamesTheBranch() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let created = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "named-br"))
        try "wip\n".write(to: URL(fileURLWithPath: created.workspace.path)
            .appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        let refused = try service.remove(selector: created.workspace.id, force: false)
        XCTAssertFalse(refused.removed)
        XCTAssertEqual(refused.branch, created.workspace.branch)
        XCTAssertEqual(refused.branchMerged, true)
        XCTAssertTrue(refused.preflightWarnings.contains {
            $0.contains("branch '\(created.workspace.branch)' is merged")
        })
    }

    // MARK: - Repo registry (T8)

    func testRepoPathLookupAndRemoveBySelector() throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo, displayName: "Named")
        XCTAssertEqual(service.repo(path: repo)?.id, record.id)
        XCTAssertEqual(service.repo(path: repo.appendingPathComponent("."))?.id, record.id)

        let removed = try service.removeRepo("path:\(repo.path)")
        XCTAssertEqual(removed.id, record.id)
        XCTAssertTrue(service.listRepos().isEmpty)
        XCTAssertNil(service.repo(path: repo))
        XCTAssertThrowsError(try service.removeRepo(record.id)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.code, "unknown_repo")
        }
    }

    func testRemoveRepoDropsFolderRowsAndLeavesGitWorktreesOnDisk() async throws {
        let folder = tmp.appendingPathComponent("plain-rm")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = makeService()
        let folderRepo = try service.addRepo(path: folder, kind: .folder)
        XCTAssertEqual(try service.listWorkspaces(repo: folderRepo.id).count, 1)
        _ = try service.removeRepo(folderRepo.id)
        XCTAssertTrue(service.store.load().folderWorkspaces.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        let repo = try makeRepo(name: "git-rm")
        let gitRepo = try service.addRepo(path: repo)
        let created = try await service.create(WorkspaceCreateRequest(repo: gitRepo.id, name: "keep-me"))
        XCTAssertNotNil(service.store.load().worktreeMeta[created.workspace.id])
        XCTAssertNotNil(service.store.load().worktreeLineageById[created.workspace.id])
        _ = try service.removeRepo(gitRepo.id)
        XCTAssertTrue(service.listRepos().isEmpty)
        XCTAssertNil(service.store.load().worktreeMeta[created.workspace.id])
        XCTAssertNil(service.store.load().worktreeLineageById[created.workspace.id])
        XCTAssertNil(service.store.load().retiredWorktreeNamesByRepo[gitRepo.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.workspace.path))
    }

    func testRepoChangesEmitsSnapshotOnSubscribeThenAddAndRemove() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let stream = service.repoChanges()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)

        let record = try service.addRepo(path: repo)
        let afterAdd = await iterator.next()
        XCTAssertEqual(afterAdd?.map(\.id), [record.id])

        _ = try service.addRepo(path: repo, displayName: "ignored")
        _ = try service.removeRepo(record.id)
        let afterRemove = await iterator.next()
        XCTAssertEqual(afterRemove?.count, 0)
    }

    func testRepoChangesSupportsMultipleSubscribers() async throws {
        let repo = try makeRepo()
        let service = makeService()
        var first = service.repoChanges().makeAsyncIterator()
        var second = service.repoChanges().makeAsyncIterator()
        let firstInitial = await first.next()
        let secondInitial = await second.next()
        XCTAssertEqual(firstInitial?.count, 0)
        XCTAssertEqual(secondInitial?.count, 0)

        _ = try service.addRepo(path: repo)
        let firstAfter = await first.next()
        let secondAfter = await second.next()
        XCTAssertEqual(firstAfter?.count, 1)
        XCTAssertEqual(secondAfter?.count, 1)
    }

    // MARK: - Primary checkout projection (T15)

    func testGitPrimaryCheckoutProjectsAsWorkspace() throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo, displayName: "Primary")
        let listed = try service.listWorkspaces(repo: record.id)
        XCTAssertEqual(listed.count, 1)
        let ws = listed[0]
        XCTAssertEqual(ws.id, "\(record.id)::\(repo.standardizedFileURL.path)")
        XCTAssertEqual(ws.kind, .worktree)
        XCTAssertEqual(ws.path, repo.standardizedFileURL.path)
        XCTAssertEqual(ws.branch, "main")
        XCTAssertFalse(ws.head.isEmpty)
        XCTAssertEqual(ws.displayName, "Primary")

        let byPath = try service.show(selector: "path:\(repo.path)")
        XCTAssertEqual(byPath.id, ws.id)
        let byName = try service.show(selector: "name:Primary")
        XCTAssertEqual(byName.id, ws.id)
        let active = try service.show(selector: "active", cwd: repo.appendingPathComponent("f.txt").path)
        XCTAssertEqual(active.id, ws.id)
        let current = try service.current(cwd: repo.path)
        XCTAssertEqual(current.id, ws.id)
    }

    func testRepoChangesKeepsProjectedWorkspacesInSync() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let stream = service.repoChanges()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        XCTAssertTrue(try service.listWorkspaces().isEmpty)

        let record = try service.addRepo(path: repo)
        _ = await iterator.next()
        let listed = try service.listWorkspaces()
        XCTAssertEqual(listed.map(\.id), ["\(record.id)::\(repo.standardizedFileURL.path)"])

        _ = try service.removeRepo(record.id)
        _ = await iterator.next()
        XCTAssertTrue(try service.listWorkspaces().isEmpty)
        XCTAssertThrowsError(try service.show(selector: "path:\(repo.path)")) { error in
            XCTAssertEqual((error as? WorkspaceError)?.code, "unknown_worktree")
        }
    }

    func testCannotRemovePrimaryCheckout() throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let primary = try XCTUnwrap(try service.listWorkspaces(repo: record.id).first)
        XCTAssertThrowsError(try service.remove(selector: primary.id)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.code, "invalid_argument")
        }
        XCTAssertEqual(try service.listWorkspaces(repo: record.id).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path))
    }

    func testCreatedWorktreeDoesNotHidePrimaryCheckout() async throws {
        let repo = try makeRepo()
        let service = makeService()
        let record = try service.addRepo(path: repo)
        let created = try await service.create(WorkspaceCreateRequest(repo: record.id, name: "apricot"))
        let listed = try service.listWorkspaces(repo: record.id)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(Set(listed.map(\.id)), Set([
            "\(record.id)::\(repo.standardizedFileURL.path)",
            created.workspace.id,
        ]))
        let byPath = try service.show(selector: "path:\(repo.path)")
        XCTAssertEqual(byPath.path, repo.standardizedFileURL.path)
        XCTAssertNotEqual(byPath.id, created.workspace.id)
    }
}

private final class StubLauncher: AgentLaunching, @unchecked Sendable {
    let handle: String
    var lastEngine: String?
    var lastPrompt: String?

    init(handle: String) { self.handle = handle }

    func launch(engineID: String, prompt: String, worktree: Worktree,
                title: String?, worktreeId: String?) async throws -> LaunchedAgent {
        lastEngine = engineID
        lastPrompt = prompt
        return LaunchedAgent(terminalHandle: handle) { _ in }
    }
}
