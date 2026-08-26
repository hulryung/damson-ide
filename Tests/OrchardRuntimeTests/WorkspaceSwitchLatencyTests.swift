import XCTest
@testable import OrchardRuntime
import OrchardCore

/// T86: what a workspace switch is allowed to cost, in `git` processes.
///
/// Wall-clock belongs in `scripts/bench-switch-latency.sh`, which measures the same calls
/// end to end through the CLI. What is pinned here is the shape that produced the
/// wall-clock: a listing that spawns one git per repo instead of two-plus-one-per-worktree,
/// and an `id:<repoId>::<path>` selector that reads the repo it names and no other.
@MainActor
final class WorkspaceSwitchLatencyTests: XCTestCase {
    private var tmp: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-switch-\(UUID().uuidString)")
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

    private func makeRepo(_ name: String) throws -> URL {
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

    private func makeService() -> WorkspaceService {
        WorkspaceService(dataURL: storeURL, worktreesRoot: tmp.appendingPathComponent("wt"))
    }

    /// Creating and restoring worktrees kicks off detached status refreshes. Counting
    /// spawns while those are still in flight would attribute another test's git to this
    /// one, so the count only starts once the runner has been quiet for a beat.
    private func settledSpawnCount() async -> Int {
        var last = GitRunner.Trace.snapshot()
        for _ in 0..<400 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            let now = GitRunner.Trace.snapshot()
            if now.inFlight == 0 && now.spawns == last.spawns { return now.spawns }
            last = now
        }
        return last.spawns
    }

    /// Three repos with a worktree each: three `git` processes for the whole listing.
    /// Before T86 this was two per repo plus one per worktree — nine — laid end to end.
    func testWarmListingSpawnsOneGitPerRepo() async throws {
        let service = makeService()
        for name in ["one", "two", "three"] {
            let repo = try makeRepo(name)
            let record = try service.addRepo(path: repo)
            _ = try await service.create(WorkspaceCreateRequest(repo: record.id, name: name))
        }
        _ = try service.listWorkspaces()   // warm: pay each repo's one-time start()

        let before = await settledSpawnCount()
        let all = try service.listWorkspaces()
        let spawned = GitRunner.Trace.snapshot().spawns - before

        XCTAssertEqual(all.count, 6, "three primary checkouts plus three worktrees")
        XCTAssertEqual(spawned, 3, "one `git worktree list --porcelain` per repo, no more")
        // The facts still have to be right, or the cheap read bought nothing.
        for workspace in all {
            XCTAssertFalse(workspace.head.isEmpty, "\(workspace.id) lost its head commit")
            XCTAssertFalse(workspace.branch.isEmpty, "\(workspace.id) lost its branch")
        }
    }

    /// The selector a pane materialization actually hands over. It names one repo and one
    /// path, so resolving it must read that repo and nothing else — this is the call that
    /// used to enumerate every registered repo before the pane could appear.
    func testResolvingAnIdSelectorReadsOnlyTheRepoItNames() async throws {
        let service = makeService()
        var target = ""
        for name in ["one", "two", "three"] {
            let repo = try makeRepo(name)
            let record = try service.addRepo(path: repo)
            let created = try await service.create(WorkspaceCreateRequest(repo: record.id, name: name))
            if name == "three" { target = created.workspace.id }
        }
        _ = try service.listWorkspaces()

        let before = await settledSpawnCount()
        let resolved = try service.resolveWorkspace("id:\(target)")
        let spawned = GitRunner.Trace.snapshot().spawns - before

        XCTAssertEqual(resolved.id, target)
        XCTAssertFalse(resolved.head.isEmpty)
        XCTAssertFalse(resolved.branch.isEmpty)
        XCTAssertLessThanOrEqual(spawned, 1,
                                 "an id selector already names its repo — resolving it "
                                     + "must not enumerate the others")
    }

    /// The repo primary checkout resolves the same cheap way, and still reports the branch
    /// it is really on rather than an empty string.
    func testResolvingAPrimaryCheckoutIdIsAlsoDirect() async throws {
        let service = makeService()
        var ids: [String] = []
        for name in ["one", "two"] {
            let repo = try makeRepo(name)
            ids.append(try service.addRepo(path: repo).id)
        }
        let all = try service.listWorkspaces()
        let primary = try XCTUnwrap(all.first { $0.repoId == ids[1] })

        let before = await settledSpawnCount()
        let resolved = try service.resolveWorkspace("id:\(primary.id)")
        XCTAssertLessThanOrEqual(GitRunner.Trace.snapshot().spawns - before, 1)
        XCTAssertEqual(resolved.branch, "main")
        XCTAssertFalse(resolved.head.isEmpty)
    }

    /// A selector naming a path the repo does not hold must still fail typed, not resolve
    /// to something adjacent — the fast path is a shortcut, never a looser match.
    func testAnIdForAPathTheRepoDoesNotHoldStillFails() throws {
        let service = makeService()
        let repo = try makeRepo("one")
        let record = try service.addRepo(path: repo)
        _ = try service.listWorkspaces()

        XCTAssertThrowsError(
            try service.resolveWorkspace("id:\(record.id)::\(tmp.path)/nowhere")
        ) { error in
            XCTAssertEqual((error as? WorkspaceError)?.code, "unknown_worktree")
        }
    }

    /// A repo registered by a path inside the checkout still gets its branch and head.
    /// git answers `worktree list` with the toplevel, so a lookup keyed on the spelling
    /// the registry holds finds nothing unless the main entry backstops it.
    func testARepoRegisteredBySubdirectoryStillProjectsBranchAndHead() throws {
        let service = makeService()
        let repo = try makeRepo("one")
        let inner = repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let record = try service.addRepo(path: inner, kind: .git)
        let all = try service.listWorkspaces()
        let primary = try XCTUnwrap(all.first { $0.repoId == record.id })
        XCTAssertEqual(primary.branch, "main")
        XCTAssertFalse(primary.head.isEmpty)
    }

    /// Non-id selectors keep working: they genuinely need the listing, and the fast path
    /// must not have quietly narrowed what resolves.
    func testNameAndBranchSelectorsStillResolve() async throws {
        let service = makeService()
        let repo = try makeRepo("one")
        let record = try service.addRepo(path: repo)
        let created = try await service.create(
            WorkspaceCreateRequest(repo: record.id, name: "apricot"))

        XCTAssertEqual(try service.resolveWorkspace("name:apricot").id, created.workspace.id)
        XCTAssertEqual(try service.resolveWorkspace("branch:\(created.workspace.branch)").id,
                       created.workspace.id)
        XCTAssertEqual(try service.resolveWorkspace("path:\(created.workspace.path)").id,
                       created.workspace.id)
    }
}
