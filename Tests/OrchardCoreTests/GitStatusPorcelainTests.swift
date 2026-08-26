import XCTest
@testable import OrchardCore

/// T86: the collapsed git reads. The parsers are pinned against git's real `-z` framing
/// (a mocked runner would test the wrong thing), and the spawn budget is pinned too —
/// the bug was never one slow git call, it was six fast ones per worktree.
final class GitStatusPorcelainParseTests: XCTestCase {
    private func nulJoined(_ fields: [String]) -> String {
        fields.map { $0 + "\0" }.joined()
    }

    func testBranchUpstreamAndAheadBehindComeFromOneReading() {
        let parsed = GitStatusPorcelainV2.parse(nulJoined([
            "# branch.oid 1111111111111111111111111111111111111111",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +3 -1",
        ]))
        XCTAssertEqual(parsed.branch, "feature/x")
        XCTAssertEqual(parsed.upstream, "origin/feature/x")
        XCTAssertEqual(parsed.ahead, 3)
        XCTAssertEqual(parsed.behind, 1)
        XCTAssertFalse(parsed.hasChanges)
        XCTAssertTrue(parsed.untracked.isEmpty)
    }

    func testDetachedHeadKeepsTheWordCallersAlreadySee() {
        // `rev-parse --abbrev-ref HEAD` reported the literal "HEAD" for a detached
        // worktree; changing that word would change what a sidebar row renders.
        let parsed = GitStatusPorcelainV2.parse(nulJoined(["# branch.head (detached)"]))
        XCTAssertEqual(parsed.branch, "HEAD")
    }

    func testNoUpstreamLeavesAheadUnclaimed() {
        let parsed = GitStatusPorcelainV2.parse(nulJoined(["# branch.head main"]))
        XCTAssertNil(parsed.upstream)
        XCTAssertEqual(parsed.ahead, 0)
    }

    func testChangedUnmergedAndUntrackedEntriesAllCountAsDirty() {
        let parsed = GitStatusPorcelainV2.parse(nulJoined([
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaa bbb a.txt",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt",
            "? new file.txt",
        ]))
        XCTAssertTrue(parsed.hasChanges)
        XCTAssertEqual(parsed.untracked, ["new file.txt"])
    }

    /// A rename record is followed by a second field holding the original path.
    /// Consuming it is what keeps the walk aligned — misreading it as a new record
    /// would turn the old path into a phantom untracked file.
    func testRenameRecordConsumesItsOriginalPathField() {
        let parsed = GitStatusPorcelainV2.parse(nulJoined([
            "# branch.head main",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new.txt",
            "old.txt",
            "? really-untracked.txt",
        ]))
        XCTAssertTrue(parsed.hasChanges)
        XCTAssertEqual(parsed.untracked, ["really-untracked.txt"])
    }

    func testUnknownHeaderIsIgnoredRatherThanFatal() {
        let parsed = GitStatusPorcelainV2.parse(nulJoined([
            "# branch.head main",
            "# something.new whatever",
            "? f.txt",
        ]))
        XCTAssertEqual(parsed.branch, "main")
        XCTAssertEqual(parsed.untracked, ["f.txt"])
    }

    func testRawAndNumstatSectionsAreMatchedByPathNotByOrder() {
        let out = ":100644 100644 aaa bbb M\0keep.txt\0"
            + ":100644 000000 ccc 000 D\0drop.txt\0"
            + "1\t0\tkeep.txt\0"
            + "0\t1\tdrop.txt\0"
        let entries = GitRawNumstat.parse(out)
        XCTAssertEqual(entries.count, 2)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        XCTAssertEqual(byPath["keep.txt"]?.statusLetter, "M")
        XCTAssertEqual(byPath["keep.txt"]?.added, 1)
        XCTAssertEqual(byPath["drop.txt"]?.statusLetter, "D")
        XCTAssertEqual(byPath["drop.txt"]?.deleted, 1)
    }

    func testBinaryCountsSurviveTheCombinedParse() {
        let entries = GitRawNumstat.parse(
            ":100644 100644 aaa bbb M\0blob.bin\0" + "-\t-\tblob.bin\0")
        XCTAssertEqual(entries.first?.isBinary, true)
        XCTAssertEqual(entries.first?.added, 0)
    }

    func testRenameDetectionIsTurnedOffExplicitly() {
        // `diff.renames` defaults to on, and a detected rename changes the framing of
        // both formats — `--numstat -z` emits a record whose path field is empty.
        XCTAssertTrue(GitRawNumstat.arguments(baseRef: "HEAD").contains("--no-renames"))
    }
}

/// The spawn budget, measured against a real repo through the shared runner's counter.
final class GitSpawnBudgetTests: XCTestCase {
    private var tmp: URL!
    private let service = GitService()

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-spawn-\(UUID().uuidString)")
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
        try "a\nb\nc\n".write(to: repo.appendingPathComponent("keep.txt"),
                              atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        return repo
    }

    /// The headline budget: a full status reading is three `git` processes, not eight.
    /// This is a ceiling, not a curiosity — a sidebar refreshes every worktree at once,
    /// so each extra spawn here is multiplied by the number of workspaces on screen.
    func testStatusCostsThreeGitProcesses() throws {
        let repo = try makeRepo()
        let base = GitRunner.shared.line(in: repo, ["rev-parse", "HEAD"]) ?? ""
        try "a\nb\nc\nd\n".write(to: repo.appendingPathComponent("keep.txt"),
                                 atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("fresh.txt"),
                          atomically: true, encoding: .utf8)

        let before = GitRunner.Trace.snapshot().spawns
        let status = service.status(worktree: repo, baseRef: base)
        let spawned = GitRunner.Trace.snapshot().spawns - before

        XCTAssertEqual(spawned, 3, "status must collapse to porcelain-v2 + raw/numstat + log")
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.hasUncommittedChanges)
        XCTAssertNil(status.unpushedCommits)
        XCTAssertEqual(Set(status.stat.files.map(\.path)), ["keep.txt", "fresh.txt"])
        XCTAssertEqual(status.stat.files.first { $0.path == "fresh.txt" }?.kind, .untracked)
    }

    /// A rename must not conjure a change with no path. `diff.renames` is on by default,
    /// and the pre-T86 `--numstat -z` parse read a rename's empty path field as a file.
    func testARenameReadsAsDeletePlusAddWithNoPhantomEntry() throws {
        let repo = try makeRepo()
        let base = GitRunner.shared.line(in: repo, ["rev-parse", "HEAD"]) ?? ""
        try git(["mv", "keep.txt", "moved.txt"], cwd: repo)

        let stat = service.diffStat(worktree: repo, baseRef: base)
        XCTAssertEqual(Set(stat.files.map(\.path)), ["keep.txt", "moved.txt"])
        XCTAssertFalse(stat.files.contains { $0.path.isEmpty })
        XCTAssertEqual(stat.files.first { $0.path == "keep.txt" }?.kind, .deleted)
        XCTAssertEqual(stat.files.first { $0.path == "moved.txt" }?.kind, .added)
    }

    /// One porcelain read answers branch and HEAD for the primary checkout *and* every
    /// linked worktree — the facts the workspace projection used to buy one spawn at a
    /// time.
    func testOnePorcelainReadCoversEveryWorktreeInTheRepo() throws {
        let repo = try makeRepo()
        let wtRoot = tmp.appendingPathComponent("wt")
        let manager = WorktreeManager(root: wtRoot)
        let one = try manager.create(base: repo, branch: "orchard/one", from: "HEAD")
        let two = try manager.create(base: repo, branch: "orchard/two", from: "HEAD")

        let before = GitRunner.Trace.snapshot().spawns
        let facts = WorktreeFactsReader.facts(forRepo: repo)
        XCTAssertEqual(GitRunner.Trace.snapshot().spawns - before, 1)

        XCTAssertEqual(facts[WorktreeFactsReader.key(repo)]?.branch, "main")
        XCTAssertEqual(facts[WorktreeFactsReader.key(one.path)]?.branch, "orchard/one")
        XCTAssertEqual(facts[WorktreeFactsReader.key(two.path)]?.branch, "orchard/two")
        XCTAssertFalse(facts[WorktreeFactsReader.key(two.path)]?.head.isEmpty ?? true)
    }

    /// git prints the realpath of every worktree, so a map keyed on the spelling Orchard
    /// stored would miss every entry under `/tmp` on macOS and report empty branches.
    func testFactsAreKeyedThroughSymlinks() throws {
        let repo = try makeRepo()
        let facts = WorktreeFactsReader.facts(forRepo: repo)
        XCTAssertNotNil(facts[WorktreeFactsReader.key(repo.path)])
    }

    /// The runner drains both pipes from one thread now. Output far larger than a pipe
    /// buffer is exactly what that has to survive: reading one stream to the end before
    /// touching the other deadlocks the moment either buffer fills.
    func testOutputLargerThanAPipeBufferIsCapturedWhole() throws {
        let repo = try makeRepo()
        let big = (0..<40_000).map { "line \($0) of a diff that will not fit in a pipe buffer" }
            .joined(separator: "\n") + "\n"
        try big.write(to: repo.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)

        let out = try GitRunner.shared.run(in: repo, ["diff", "--cached", "--", "big.txt"])
        XCTAssertGreaterThan(out.utf8.count, 1_000_000)
        XCTAssertTrue(out.contains("line 39999 of a diff"), "the tail of the output was lost")
    }

    /// A nonzero exit still carries git's own diagnostic — the stderr half of the drain.
    func testStderrSurvivesANonzeroExit() throws {
        let repo = try makeRepo()
        let result = try GitRunner.shared.capture(["-C", repo.path, "rev-parse", "no/such/ref"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.stderr.isEmpty, "git's diagnostic was dropped")
    }
}

/// The main-thread guarantee. `WorktreeService` and `WorktreeRecord` both live on the
/// main actor and both expose git status — so both have to hand the process spawn to a
/// detached task, or selecting a workspace freezes the window for the length of the read.
@MainActor
final class MainThreadGitTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-mainthread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeRepo() throws -> URL {
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"],
                     ["config", "user.email", "t@t.io"],
                     ["config", "user.name", "Test"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try "x\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "."], ["commit", "-q", "-m", "init"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        return repo
    }

    func testStatusRefreshesNeverSpawnGitOnTheMainThread() async throws {
        let repo = try makeRepo()
        let service = WorktreeService(baseRepo: repo,
                                      worktreesRoot: tmp.appendingPathComponent("wt"))
        try service.start()
        let record = try service.createWorktree(name: "apricot")

        let before = GitRunner.Trace.snapshot().mainThreadSpawns
        await record.refresh()
        _ = await service.primaryCheckoutStatus()
        XCTAssertEqual(GitRunner.Trace.snapshot().mainThreadSpawns - before, 0,
                       "a status read on the main thread is a frame the workbench did not draw")
    }
}
