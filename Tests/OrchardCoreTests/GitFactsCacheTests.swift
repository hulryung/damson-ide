import XCTest
@testable import OrchardCore

/// T87: what a workspace switch is allowed to cost, and what a cached reading is allowed
/// to claim.
///
/// The wall-clock half of this task is measured on the live app and written up in
/// `docs/reports/t87-switch-cache.md`. What is pinned here is the two rules that produced
/// it: a second visit to an unchanged worktree runs no `git` at all, and a reading stops
/// being served the moment anything that could make it untrue happens — including a commit
/// or a branch switch made by a process Orchard knows nothing about.
final class GitFactsCacheTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Fixtures

    /// git run as a plain subprocess, deliberately *not* through `GitRunner`: these stand
    /// in for the user's own terminal, an agent, or any other process on the machine, and
    /// none of them tell Orchard what they did.
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

    private func makeRepo(_ name: String = "repo") throws -> URL {
        let repo = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: repo)
        try git(["config", "user.email", "t@t.io"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        try "a\nb\nc\n".write(to: repo.appendingPathComponent("keep.txt"),
                              atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        return repo
    }

    /// A linked worktree, whose `.git` is a *file* and whose refs live in the base repo —
    /// the layout every Orchard workspace actually has.
    private func makeLinkedWorktree(of repo: URL, name: String = "wt") throws -> URL {
        let path = tmp.appendingPathComponent(name)
        try git(["worktree", "add", "-q", "-b", "feature", path.path], cwd: repo)
        return path
    }

    private func head(of repo: URL) -> String {
        GitRunner.shared.line(in: repo, ["rev-parse", "HEAD"]) ?? ""
    }

    private func spawns() -> Int { GitRunner.Trace.snapshot().spawns }

    /// Wait until the cache stops answering for `worktree` — i.e. until whatever changed
    /// it has been noticed. Returns false if it never was, which is the failure this whole
    /// type exists to make impossible.
    private func waitForInvalidation(_ cache: GitFactsCache, worktree: URL, baseRef: String,
                                     timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cache.cached(worktree: worktree, baseRef: baseRef) == nil { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return false
    }

    /// Give the freshly-started FSEvents stream a moment to register before the test
    /// mutates the tree it is watching.
    private func settleWatcher() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    // MARK: - Rule 2: do not recompute what has not changed

    func testASecondReadingOfAnUnchangedWorktreeRunsNoGit() async throws {
        let repo = try makeRepo()
        let cache = GitFactsCache()
        defer { cache.reset() }

        let base = head(of: repo)
        let first = await cache.facts(worktree: repo, baseRef: base)
        let before = spawns()
        let second = await cache.facts(worktree: repo, baseRef: base)

        XCTAssertEqual(spawns(), before, "a warm reading must not spawn git at all")
        XCTAssertEqual(first.status, second.status)
        XCTAssertEqual(first.conflicts, second.conflicts)
        XCTAssertNotNil(cache.cached(worktree: repo, baseRef: base),
                        "the synchronous reading a workspace switch uses must be there")
    }

    /// The sidebar row, the workbench's conflict check and the source-control panel all ask
    /// about the same worktree in the same turn of the run loop. Before T87 that was three
    /// unrelated fan-outs of git; now it is one reading they share.
    func testConcurrentReadersOfOneWorktreeShareOneReading() async throws {
        let repo = try makeRepo()
        let cache = GitFactsCache()
        defer { cache.reset() }
        let base = head(of: repo)

        let before = spawns()
        async let a = cache.facts(worktree: repo, baseRef: base)
        async let b = cache.facts(worktree: repo, baseRef: base)
        async let c = cache.facts(worktree: repo, baseRef: base)
        async let d = cache.facts(worktree: repo, baseRef: base)
        let all = await [a, b, c, d]

        XCTAssertEqual(spawns() - before, 3, "one reading is three spawns, whoever asked")
        XCTAssertEqual(cache.snapshotStats().computes, 1)
        XCTAssertEqual(Set(all.map(\.status.branch)), ["main"])
    }

    /// Nothing is cached that is not watched: dropping a worktree drops its watcher too, so
    /// a deleted directory cannot leave a live stream behind.
    func testForgettingAWorktreeDropsItsReadingAndItsWatcher() async throws {
        let repo = try makeRepo()
        let cache = GitFactsCache()
        defer { cache.reset() }
        _ = await cache.facts(worktree: repo, baseRef: head(of: repo))
        XCTAssertTrue(cache.isWatching)

        cache.forget(worktree: repo)
        XCTAssertNil(cache.cached(worktree: repo, baseRef: head(of: repo)))
        XCTAssertFalse(cache.isWatching)
    }

    // MARK: - Honest invalidation

    func testAWorkingTreeEditIsNoticed() async throws {
        let repo = try makeRepo()
        let cache = GitFactsCache()
        defer { cache.reset() }
        let base = head(of: repo)
        _ = await cache.facts(worktree: repo, baseRef: base)
        await settleWatcher()

        try "a\nb\nc\nd\n".write(to: repo.appendingPathComponent("keep.txt"),
                                 atomically: true, encoding: .utf8)

        let noticed = await waitForInvalidation(cache, worktree: repo, baseRef: base)
        XCTAssertTrue(noticed, "an edit in the working tree must retire the reading")
        let fresh = await cache.facts(worktree: repo, baseRef: base)
        XCTAssertTrue(fresh.status.hasUncommittedChanges)
    }

    /// The one that decides whether the cache is honest. A commit inside a *linked*
    /// worktree touches nothing in the working tree — it moves a ref that lives in the base
    /// repo's git dir — so a cache watching only the checkout would go on reporting the old
    /// commit count forever.
    func testACommitMadeOutsideOrchardIsNoticed() async throws {
        let repo = try makeRepo()
        let worktree = try makeLinkedWorktree(of: repo)
        let base = head(of: repo)
        let cache = GitFactsCache()
        defer { cache.reset() }

        let before = await cache.facts(worktree: worktree, baseRef: base)
        XCTAssertEqual(before.status.commitsAhead, 0)
        await settleWatcher()

        try "new\n".write(to: worktree.appendingPathComponent("added.txt"),
                          atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: worktree)
        try git(["commit", "-q", "-m", "outside"], cwd: worktree)

        let noticed = await waitForInvalidation(cache, worktree: worktree, baseRef: base)
        XCTAssertTrue(noticed, "a commit made in a terminal must retire the reading")
        let after = await cache.facts(worktree: worktree, baseRef: base)
        XCTAssertEqual(after.status.commitsAhead, 1)
        XCTAssertEqual(after.status.lastCommitSubject, "outside")
    }

    /// "A cache that can serve a stale branch must be invalidated by whatever changed it,
    /// or not exist." Switching a linked worktree's branch rewrites one file in its git
    /// dir and nothing else.
    func testABranchSwitchMadeOutsideOrchardIsNoticed() async throws {
        let repo = try makeRepo()
        let worktree = try makeLinkedWorktree(of: repo)
        let base = head(of: repo)
        let cache = GitFactsCache()
        defer { cache.reset() }

        let opening = await cache.facts(worktree: worktree, baseRef: base)
        XCTAssertEqual(opening.status.branch, "feature")
        await settleWatcher()
        try git(["checkout", "-q", "-b", "elsewhere"], cwd: worktree)

        let noticed = await waitForInvalidation(cache, worktree: worktree, baseRef: base)
        XCTAssertTrue(noticed, "a branch switch must retire the reading")
        let after = await cache.facts(worktree: worktree, baseRef: base)
        XCTAssertEqual(after.status.branch, "elsewhere")
    }

    /// A resolved conflict is the other half of the same rule: the summary that opened a
    /// conflict tab must not survive the resolution that closed it.
    func testAResolvedConflictIsNoticed() async throws {
        let repo = try makeRepo()
        try git(["checkout", "-q", "-b", "side"], cwd: repo)
        try "side\n".write(to: repo.appendingPathComponent("keep.txt"),
                           atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "side"], cwd: repo)
        try git(["checkout", "-q", "main"], cwd: repo)
        try "main\n".write(to: repo.appendingPathComponent("keep.txt"),
                           atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "main"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "-q", "side"], cwd: repo), 0, "expected a conflict")

        let base = head(of: repo)
        let cache = GitFactsCache()
        defer { cache.reset() }
        let conflicted = await cache.facts(worktree: repo, baseRef: base)
        XCTAssertEqual(conflicted.conflicts.operation, .merge)
        XCTAssertEqual(conflicted.conflicts.files.map(\.path), ["keep.txt"])
        XCTAssertEqual(conflicted.conflicts.files.first?.kind, .bothModified)
        await settleWatcher()

        try "resolved\n".write(to: repo.appendingPathComponent("keep.txt"),
                               atomically: true, encoding: .utf8)
        try git(["add", "keep.txt"], cwd: repo)
        try git(["commit", "-q", "--no-edit"], cwd: repo)

        let noticed = await waitForInvalidation(cache, worktree: repo, baseRef: base)
        XCTAssertTrue(noticed, "resolving the merge must retire the summary that showed it")
        let after = await cache.facts(worktree: repo, baseRef: base)
        XCTAssertEqual(after.conflicts.operation, .none)
        XCTAssertTrue(after.conflicts.files.isEmpty)
    }

    /// A reading invalidated *while it was running* is handed to the caller who asked for
    /// it — it is the newest thing anyone has — but never stored, so the next caller reads
    /// again instead of inheriting a value that was already out of date when it landed.
    func testAReadingInvalidatedWhileItRanIsNotStored() async throws {
        let repo = try makeRepo()
        // A deliberately slow stand-in for git, so "the change landed mid-reading" is the
        // case under test rather than a race the test happened to win.
        let slowGit = tmp.appendingPathComponent("slow-git")
        try "#!/bin/sh\nsleep 0.2\nexit 0\n".write(to: slowGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: slowGit.path)
        let cache = GitFactsCache(service: GitService(git: GitRunner(gitPath: slowGit.path)))
        defer { cache.reset() }

        let pending = Task { await cache.facts(worktree: repo, baseRef: "HEAD") }
        while cache.snapshotStats().computes == 0 { await Task.yield() }
        cache.invalidate(worktree: repo)
        _ = await pending.value

        XCTAssertNil(cache.cached(worktree: repo, baseRef: "HEAD"),
                     "a reading overtaken by a change must not become the cached answer")
        // …and the one that was not overtaken still is, or the guard is just a leak.
        _ = await cache.facts(worktree: repo, baseRef: "HEAD")
        XCTAssertNotNil(cache.cached(worktree: repo, baseRef: "HEAD"))
    }

    // MARK: - Rule 1: collapse the spawns

    /// `refreshConflicts` used to be two `git` processes of its own on top of the status
    /// reading's three. All five facts now come from three.
    func testStatusAndConflictSummaryTogetherCostThreeSpawns() async throws {
        let repo = try makeRepo()
        let cache = GitFactsCache()
        defer { cache.reset() }

        let base = head(of: repo)
        let before = spawns()
        let facts = await cache.facts(worktree: repo, baseRef: base)
        XCTAssertEqual(spawns() - before, 3)
        XCTAssertEqual(facts.status.branch, "main")
        XCTAssertEqual(facts.conflicts, .none)
    }

    /// Which operation is mid-flight is read from the control files in the git dir, and
    /// finding that directory no longer costs a `rev-parse`.
    func testALinkedWorktreesGitDirIsResolvedWithoutSpawningGit() throws {
        let repo = try makeRepo()
        let worktree = try makeLinkedWorktree(of: repo)

        let before = spawns()
        let resolved = GitConflictService.gitDirectoryWithoutGit(worktree: worktree)
        XCTAssertEqual(spawns(), before, "resolving the git dir must not run git")

        let asGitSeesIt = GitRunner.shared.line(in: worktree, ["rev-parse", "--absolute-git-dir"])
        XCTAssertEqual(resolved?.resolvingSymlinksInPath().path,
                       asGitSeesIt.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })

        let common = GitConflictService.commonDirectory(gitDirectory: resolved!)
        let asGitSeesCommon = GitRunner.shared.line(in: worktree, ["rev-parse", "--git-common-dir"])
        XCTAssertEqual(common.resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: asGitSeesCommon!, relativeTo: worktree)
                        .resolvingSymlinksInPath().path)
    }

    func testAPrimaryCheckoutsGitDirIsTheDirectoryItself() throws {
        let repo = try makeRepo()
        XCTAssertEqual(GitConflictService.gitDirectoryWithoutGit(worktree: repo)?.lastPathComponent,
                       ".git")
        // Same directory back when there is no `commondir` file to follow.
        let git = repo.appendingPathComponent(".git")
        XCTAssertEqual(GitConflictService.commonDirectory(gitDirectory: git).path, git.path)
    }

    // MARK: - Mutation classification

    func testMutatingVerbsAreToldApartFromReadOnlyOnes() {
        XCTAssertEqual(GitRunner.verb(["-C", "/tmp/x", "status", "--porcelain"]), "status")
        XCTAssertEqual(GitRunner.verb(["-C", "/tmp/x", "commit", "-m", "x"]), "commit")
        XCTAssertEqual(GitRunner.verb(["worktree", "list", "--porcelain"]), "worktree")
        XCTAssertEqual(GitRunner.target(["-C", "/tmp/x", "commit"], cwd: nil)?.path, "/tmp/x")
        XCTAssertEqual(GitRunner.target(["status"], cwd: URL(fileURLWithPath: "/tmp/y"))?.path,
                       "/tmp/y")
        XCTAssertTrue(GitRunner.readOnlyVerbs.contains("status"))
        XCTAssertFalse(GitRunner.readOnlyVerbs.contains("commit"))
        XCTAssertFalse(GitRunner.readOnlyVerbs.contains("checkout"))
    }

    /// The latency shortcut: a mutation Orchard itself runs retires the reading without
    /// waiting for the file-system notification to arrive.
    func testAMutationThroughTheRunnerRetiresTheReadingImmediately() async throws {
        let repo = try makeRepo()
        let cache = GitFactsCache()
        defer { cache.reset() }
        let previous = GitRunner.onMutation
        GitRunner.onMutation = { [cache] url in cache.invalidate(worktree: url) }
        defer { GitRunner.onMutation = previous }

        let base = head(of: repo)
        _ = await cache.facts(worktree: repo, baseRef: base)
        XCTAssertNotNil(cache.cached(worktree: repo, baseRef: base))

        // A read-only query must not retire anything, or the cache buys nothing.
        _ = GitRunner.shared.query(in: repo, ["status", "--porcelain"])
        XCTAssertNotNil(cache.cached(worktree: repo, baseRef: base))

        try "z\n".write(to: repo.appendingPathComponent("added.txt"),
                        atomically: true, encoding: .utf8)
        try GitRunner.shared.run(in: repo, ["add", "added.txt"])
        XCTAssertNil(cache.cached(worktree: repo, baseRef: base),
                     "staging a file must retire the reading that predates it")
    }

    // MARK: - Untracked files

    func testUntrackedLineCountsAreExactIncludingAMissingFinalNewline() throws {
        var budget = GitService.ReadBudget()
        let three = tmp.appendingPathComponent("three.txt")
        try "a\nb\nc\n".write(to: three, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitService.countLines(at: three, budget: &budget).lines, 3)

        let unterminated = tmp.appendingPathComponent("unterminated.txt")
        try "a\nb\nc".write(to: unterminated, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitService.countLines(at: unterminated, budget: &budget).lines, 3)

        let empty = tmp.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        let emptyReading = GitService.countLines(at: empty, budget: &budget)
        XCTAssertEqual(emptyReading.lines, 0)
        XCTAssertTrue(emptyReading.counted)

        let binary = tmp.appendingPathComponent("binary.bin")
        try Data([0x41, 0x00, 0x42]).write(to: binary)
        XCTAssertTrue(GitService.countLines(at: binary, budget: &budget).binary)
    }

    /// A file the refresh declined to read is a real change of unknown size. Reporting it
    /// as zero lines or as binary would both be claims nobody checked.
    func testAFileBeyondTheReadBudgetIsFlaggedRatherThanCalledEmpty() throws {
        let big = tmp.appendingPathComponent("big.txt")
        try Data(repeating: 0x41, count: 4096).write(to: big)

        var exhausted = GitService.ReadBudget(bytes: 0, files: 10)
        let reading = GitService.countLines(at: big, budget: &exhausted)
        XCTAssertFalse(reading.counted)
        XCTAssertFalse(reading.binary, "not reading a file is not evidence that it is binary")
        XCTAssertEqual(reading.lines, 0)

        let change = GitFileChange(path: "big.txt", kind: .untracked, added: 0, deleted: 0,
                                   isBinary: false, linesCounted: false)
        XCTAssertFalse(GitDiffStat(files: [change]).countsComplete)
        XCTAssertTrue(GitDiffStat(files: [
            GitFileChange(path: "a", kind: .modified, added: 1, deleted: 0),
        ]).countsComplete)
    }

    /// The budget is spent, not ignored: the first untracked files in a refresh are counted
    /// exactly and only what is past the budget goes unmeasured.
    func testTheReadBudgetIsSpentBeforeAnythingGoesUncounted() throws {
        let a = tmp.appendingPathComponent("a.txt")
        let b = tmp.appendingPathComponent("b.txt")
        try "x\ny\n".write(to: a, atomically: true, encoding: .utf8)   // 4 bytes
        try "p\nq\n".write(to: b, atomically: true, encoding: .utf8)

        var budget = GitService.ReadBudget(bytes: 4, files: 10)
        let first = GitService.countLines(at: a, budget: &budget)
        let second = GitService.countLines(at: b, budget: &budget)
        XCTAssertTrue(first.counted)
        XCTAssertEqual(first.lines, 2)
        XCTAssertFalse(second.counted)
    }

    func testUntrackedFilesInARealRepoAreCountedFromTheStatusReading() async throws {
        let repo = try makeRepo()
        try "1\n2\n3\n4\n".write(to: repo.appendingPathComponent("fresh.txt"),
                                 atomically: true, encoding: .utf8)
        let cache = GitFactsCache()
        defer { cache.reset() }

        let facts = await cache.facts(worktree: repo, baseRef: head(of: repo))
        let fresh = facts.status.stat.files.first { $0.path == "fresh.txt" }
        XCTAssertEqual(fresh?.kind, .untracked)
        XCTAssertEqual(fresh?.added, 4)
        XCTAssertTrue(facts.status.stat.countsComplete)
    }
}

/// The acceptance shape of T87, at the layer the workbench actually uses: a
/// `WorktreeRecord` per workspace, refreshed on selection.
///
/// The live-app numbers are in `docs/reports/t87-switch-cache.md`; this is the guarantee
/// behind them — alternating between two workspaces that have been visited once costs no
/// `git` processes at all, and the facts are still right.
@MainActor
final class WorkspaceSwitchSpawnBudgetTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-switch-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        GitFactsCache.shared.reset()
    }

    override func tearDownWithError() throws {
        GitFactsCache.shared.reset()
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
        try git(["config", "user.name", "Test User"], cwd: repo)
        try "x\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        return repo
    }

    /// Wait for the runner to go quiet so the restore's own refreshes are not counted
    /// against the switch.
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

    func testAlternatingBetweenTwoVisitedWorkspacesRunsNoGit() async throws {
        let repo = try makeRepo()
        let service = WorktreeService(baseRepo: repo,
                                      worktreesRoot: tmp.appendingPathComponent("wt"))
        try service.start()
        let one = try service.createWorktree(name: "one")
        let two = try service.createWorktree(name: "two")

        // First visit to each: the readings that a cold switch pays for.
        await one.refresh()
        await two.refresh()
        _ = await service.primaryCheckoutFacts()
        let before = await settledSpawnCount()

        for _ in 0..<3 {
            await one.refresh()
            await two.refresh()
            _ = await service.primaryCheckoutFacts()
            one.applyCachedFacts()
            two.applyCachedFacts()
        }

        XCTAssertEqual(GitRunner.Trace.snapshot().spawns, before,
                       "switching between visited workspaces must spawn no git at all")
        XCTAssertEqual(one.status.branch, "test-user/one")
        XCTAssertEqual(two.status.branch, "test-user/two")
        XCTAssertNotNil(service.cachedPrimaryCheckoutFacts())
        // The conflict summary rides along on the same reading, so the workbench's
        // per-key conflict check is answered without a second reading of its own.
        XCTAssertEqual(one.conflicts, .none)
    }

    /// The cheap synchronous read a selection uses is only available once, and only while
    /// it is still true — a first visit has nothing to serve.
    func testAFirstVisitHasNoCachedReadingToServe() throws {
        let repo = try makeRepo()
        let service = WorktreeService(baseRepo: repo,
                                      worktreesRoot: tmp.appendingPathComponent("wt"))
        try service.start()
        let record = try service.createWorktree(name: "fresh")
        GitFactsCache.shared.reset()
        XCTAssertFalse(record.applyCachedFacts())
        XCTAssertNil(service.cachedPrimaryCheckoutFacts())
    }
}

/// A reproducible wall-clock reading of the reading itself, against a repo named by the
/// environment rather than a fixture — the fixtures are three files, and the cost this
/// task is about only appears on a real checkout.
///
///     ORCHARD_BENCH_REPO=~/dev/CAN-debugger-hw swift test --filter GitFactsBenchTests
///
/// Skipped when the variable is unset, so it never runs in the ordinary suite. It reads
/// and never writes.
final class GitFactsBenchTests: XCTestCase {
    private func millis(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testReadingOneWorktreeColdAndWarm() async throws {
        guard let raw = ProcessInfo.processInfo.environment["ORCHARD_BENCH_REPO"] else {
            throw XCTSkip("set ORCHARD_BENCH_REPO to a checkout to measure")
        }
        let repo = URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
        let cache = GitFactsCache()
        defer { cache.reset() }
        let base = GitRunner.shared.line(in: repo, ["rev-parse", "HEAD"]) ?? "HEAD"

        var cold = 0.0, warm = 0.0
        let spawnsBefore = GitRunner.Trace.snapshot().spawns
        let facts = await withCheckedContinuation { (c: CheckedContinuation<GitWorktreeFacts, Never>) in
            Task {
                let start = DispatchTime.now().uptimeNanoseconds
                let value = await cache.facts(worktree: repo, baseRef: base)
                cold = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                c.resume(returning: value)
            }
        }
        let coldSpawns = GitRunner.Trace.snapshot().spawns - spawnsBefore
        let warmBefore = GitRunner.Trace.snapshot().spawns
        for _ in 0..<20 {
            warm += millis { _ = cache.cached(worktree: repo, baseRef: base) }
        }
        let warmSpawns = GitRunner.Trace.snapshot().spawns - warmBefore

        // The five processes the pre-T87 switch actually ran, spelled out rather than
        // called through today's code — every layer above has changed, so replaying the
        // command set is the only comparison that still means the same thing.
        let old = [
            ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            ["diff", "--no-renames", "--raw", "--numstat", "-z", base, "--"],
            ["log", "-z", "--format=%s", "\(base)..HEAD"],
            ["rev-parse", "--absolute-git-dir"],          // the conflict summary's own…
            ["status", "--porcelain", "-z"],              // …two processes
        ]
        let oldSpawnsBefore = GitRunner.Trace.snapshot().spawns
        let beforeShape = millis {
            for args in old { _ = GitRunner.shared.query(in: repo, args) }
        }
        let oldSpawns = GitRunner.Trace.snapshot().spawns - oldSpawnsBefore

        print("""
        ORCHARD_BENCH \(repo.lastPathComponent): \
        pre-T87 shape \(String(format: "%.1f", beforeShape)) ms / \(oldSpawns) git, \
        cold \(String(format: "%.1f", cold)) ms / \(coldSpawns) git, \
        warm \(String(format: "%.3f", warm / 20)) ms / \(warmSpawns) git, \
        \(facts.status.stat.fileCount) changed files, branch \(facts.status.branch)
        """)
        XCTAssertEqual(warmSpawns, 0)
    }

    /// The untracked-file half. `GitService` has to read a file git is not tracking to put
    /// a `+N` on it, and it was doing that with a per-byte `Data.reduce`. Both counters
    /// must agree — the point of the change is that it is the same number, faster.
    func testUntrackedLineCountingCostAndAgreement() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-untracked-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let line = String(repeating: "x", count: 79) + "\n"
        let body = String(repeating: line, count: 400)          // ~32 KB, 400 lines
        var files: [URL] = []
        for index in 0..<300 {
            let url = dir.appendingPathComponent("file-\(index).txt")
            try body.write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }

        var budget = GitService.ReadBudget()
        var fast = 0
        let fastMS = millis {
            for url in files { fast += GitService.countLines(at: url, budget: &budget).lines }
        }

        // The reader this replaced, spelled out: whole-file `Data(contentsOf:)` after an
        // `attributesOfItem` for the size, then a per-byte reduce.
        var slow = 0
        let slowMS = millis {
            for url in files {
                guard let size = (try? FileManager.default
                    .attributesOfItem(atPath: url.path))?[.size] as? Int,
                    size <= 2 * 1024 * 1024,
                    let data = try? Data(contentsOf: url) else { continue }
                slow += data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
            }
        }

        // Tiny files, where per-file overhead rather than bytes is the whole cost.
        let manyDir = dir.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: manyDir, withIntermediateDirectories: true)
        var tiny: [URL] = []
        for index in 0..<3000 {
            let url = manyDir.appendingPathComponent("t-\(index).txt")
            try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
            tiny.append(url)
        }
        var tinyBudget = GitService.ReadBudget(bytes: .max, files: .max)
        var tinyLines = 0
        let tinyMS = millis {
            for url in tiny {
                tinyLines += GitService.countLines(at: url, budget: &tinyBudget).lines
            }
        }
        var tinySlow = 0
        let tinySlowMS = millis {
            for url in tiny {
                guard let size = (try? FileManager.default
                    .attributesOfItem(atPath: url.path))?[.size] as? Int,
                    size <= 2 * 1024 * 1024,
                    let data = try? Data(contentsOf: url) else { continue }
                tinySlow += data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
            }
        }
        XCTAssertEqual(tinyLines, tinySlow)
        print("""
        ORCHARD_BENCH untracked counting over 3000 tiny files: \
        stat+read \(String(format: "%.1f", tinyMS)) ms, \
        attributesOfItem+Data \(String(format: "%.1f", tinySlowMS)) ms
        """)

        XCTAssertEqual(fast, slow, "the fast counter must produce the identical number")
        XCTAssertEqual(fast, 300 * 400)
        print("""
        ORCHARD_BENCH untracked counting over 300 files / ~9.5 MB: \
        memchr \(String(format: "%.1f", fastMS)) ms, per-byte reduce \
        \(String(format: "%.1f", slowMS)) ms
        """)
    }
}

/// Ordering: at launch every worktree in every repo asks for a reading at once, and the
/// queue is bounded. The workspace the user just selected must not wait behind the fan-out.
final class GitFactsUrgencyTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-urgency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testAForegroundReadingOvertakesABacklogOfBackgroundOnes() async throws {
        // A stand-in for git that costs a fixed 60 ms, so the ordering is what is measured
        // rather than how big each repo happens to be.
        let slowGit = tmp.appendingPathComponent("slow-git")
        try "#!/bin/sh\nsleep 0.06\nexit 0\n".write(to: slowGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: slowGit.path)
        let cache = GitFactsCache(service: GitService(git: GitRunner(gitPath: slowGit.path)),
                                  concurrency: 2)
        defer { cache.reset() }

        var roots: [URL] = []
        for index in 0..<24 {
            let dir = tmp.appendingPathComponent("bg-\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            roots.append(dir)
        }
        let selected = tmp.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)

        // The floor: one reading with nothing else running.
        let soloStart = DispatchTime.now().uptimeNanoseconds
        _ = await cache.facts(worktree: tmp.appendingPathComponent("solo"), baseRef: "HEAD",
                              urgency: .foreground)
        let solo = Double(DispatchTime.now().uptimeNanoseconds - soloStart) / 1_000_000

        let backlog = Task {
            await withTaskGroup(of: Void.self) { group in
                for root in roots {
                    group.addTask { _ = await cache.facts(worktree: root, baseRef: "HEAD") }
                }
            }
        }
        // Let the backlog fill the queue before the selection arrives.
        try? await Task.sleep(nanoseconds: 30_000_000)

        let start = DispatchTime.now().uptimeNanoseconds
        _ = await cache.facts(worktree: selected, baseRef: "HEAD", urgency: .foreground)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        await backlog.value

        // The claim is not "instant" — a first visit really does have to run git. It is
        // that the wait is bounded by the readings already in flight (two here) rather than
        // by the twenty-four queued behind them, which would be an order of magnitude more.
        print("ORCHARD_BENCH urgency: solo \(String(format: "%.0f", solo)) ms, "
              + "with a 24-deep backlog \(String(format: "%.0f", ms)) ms")
        XCTAssertLessThan(ms, solo * 4,
                          "the selected workspace waited behind the fan-out "
                          + "(\(ms) ms against a \(solo) ms floor)")
    }
}
