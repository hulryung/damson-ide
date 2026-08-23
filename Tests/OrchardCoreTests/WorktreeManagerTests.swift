import XCTest
@testable import OrchardCore

final class WorktreeManagerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damson-wt-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Run a git command directly to build the fixture repo.
    @discardableResult
    private func git(_ args: [String], cwd: URL) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func makeRepo() throws -> URL {
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try XCTSkipIf(FileManager.default.isExecutableFile(atPath: "/usr/bin/git") == false, "git unavailable")
        XCTAssertEqual(try git(["init", "-q"], cwd: repo), 0)
        try git(["config", "user.email", "test@damson.app"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try git(["add", "."], cwd: repo), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "init"], cwd: repo), 0)
        return repo
    }

    func testFullLifecycle() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))

        let base = try mgr.detectBaseRepo(from: repo)
        // Compare filesystem paths, not full URLs: `git rev-parse --show-toplevel`
        // yields a directory URL (trailing-slash directory hint) while the test's
        // own URL has none, so URL equality spuriously fails on that hint alone.
        XCTAssertEqual(base.resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path)

        try mgr.validateReady(base)
        let ref = try mgr.resolveRef("HEAD", in: base)
        XCTAssertEqual(ref.count, 40)

        let wt = try mgr.create(base: base, branch: "orchestrator/test/fix-bug", from: ref)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path.appendingPathComponent("README.md").path))

        let listed = try mgr.list(base: base)
        XCTAssertTrue(listed.contains { $0.contains(wt.path.lastPathComponent) })

        XCTAssertTrue(try mgr.remove(wt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path.path))
    }

    func testDirtyWorktreePreservedWithoutForce() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)
        let wt = try mgr.create(base: base, branch: "orchestrator/test/dirty", from: ref)

        // Make it dirty.
        try "uncommitted".write(to: wt.path.appendingPathComponent("scratch.txt"),
                                atomically: true, encoding: .utf8)

        // Non-force remove should refuse (return false) and keep the worktree.
        XCTAssertFalse(try mgr.remove(wt, force: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path.path))

        // Force removes it.
        XCTAssertTrue(try mgr.remove(wt, force: true))
    }

    func testDetectBaseRepoFailsOutsideRepo() throws {
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let notRepo = tmp.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: notRepo, withIntermediateDirectories: true)
        XCTAssertThrowsError(try mgr.detectBaseRepo(from: notRepo))
    }

    // MARK: - Persistence

    /// The point of worktree persistence: a *different* manager instance — standing in for
    /// a relaunched app — rebuilds the full list from the repo's git config alone.
    func testRestoreRebuildsWorktreesAfterRelaunch() throws {
        let repo = try makeRepo()
        let root = tmp.appendingPathComponent("worktrees")
        let mgr = WorktreeManager(root: root)
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)

        let one = try mgr.create(base: base, branch: "orchard/fix-parser", from: ref, title: "Fix parser")
        let two = try mgr.create(base: base, branch: "orchard/add-tests", from: ref, title: "Add tests")

        let restored = WorktreeManager(root: root).restore(repo: base)
        XCTAssertEqual(restored.count, 2)

        let byBranch = Dictionary(uniqueKeysWithValues: restored.map { ($0.branch, $0) })
        XCTAssertEqual(byBranch["orchard/fix-parser"]?.title, "Fix parser")
        XCTAssertEqual(byBranch["orchard/fix-parser"]?.baseRef, ref)
        XCTAssertEqual(byBranch["orchard/fix-parser"]?.id, one.id)
        XCTAssertEqual(byBranch["orchard/add-tests"]?.title, "Add tests")
        XCTAssertEqual(byBranch["orchard/add-tests"]?.path.path, two.path.path)
    }

    /// A worktree removed behind the app's back must not come back as a ghost row.
    func testRestoreDropsMetadataForVanishedWorktrees() throws {
        let repo = try makeRepo()
        let root = tmp.appendingPathComponent("worktrees")
        let mgr = WorktreeManager(root: root)
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)

        let wt = try mgr.create(base: base, branch: "orchard/gone", from: ref)
        XCTAssertEqual(mgr.restore(repo: base).count, 1)

        // Remove it the way a user would, outside the app.
        XCTAssertEqual(try git(["worktree", "remove", wt.path.path], cwd: repo), 0)

        XCTAssertTrue(mgr.restore(repo: base).isEmpty)
        // …and the stale config section is gone too, not merely filtered out of the result.
        XCTAssertTrue(mgr.restore(repo: base).isEmpty)
    }

    func testRemoveClearsPersistedMetadata() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)
        let wt = try mgr.create(base: base, branch: "orchard/temp", from: ref)

        XCTAssertTrue(try mgr.remove(wt))
        XCTAssertTrue(mgr.restore(repo: base).isEmpty)
    }

    // MARK: - Naming

    /// Two agents given the same task title get readable sibling branches, not UUID salad.
    func testCollidingBranchNamesGetReadableSuffixes() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)

        let a = try mgr.create(base: base, branch: "orchard/same", from: ref)
        let b = try mgr.create(base: base, branch: "orchard/same", from: ref)
        let c = try mgr.create(base: base, branch: "orchard/same", from: ref)

        XCTAssertEqual(a.branch, "orchard/same")
        XCTAssertEqual(b.branch, "orchard/same-2")
        XCTAssertEqual(c.branch, "orchard/same-3")
        // Directories are named for the branch leaf, and are likewise distinct.
        XCTAssertEqual(Set([a, b, c].map(\.path.path)).count, 3)
        XCTAssertEqual(a.path.lastPathComponent, "same")
    }

    // MARK: - Delete preflight

    func testPreflightIsSafeForUntouchedWorktree() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)
        let wt = try mgr.create(base: base, branch: "orchard/untouched", from: ref)

        let preflight = mgr.deletionPreflight(wt)
        XCTAssertTrue(preflight.isSafe)
        XCTAssertTrue(preflight.warnings.isEmpty)
        XCTAssertTrue(preflight.status.isPristine)
    }

    /// Deleting an agent's only output is the mistake this preflight exists to prevent, so
    /// both uncommitted files and unpushed commits have to be named in the warnings.
    func testPreflightWarnsAboutUncommittedAndUnpushedWork() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)
        let wt = try mgr.create(base: base, branch: "orchard/busy", from: ref)

        try "committed\n".write(to: wt.path.appendingPathComponent("done.txt"),
                                atomically: true, encoding: .utf8)
        XCTAssertEqual(try git(["add", "."], cwd: wt.path), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "agent work"], cwd: wt.path), 0)
        try "wip\n".write(to: wt.path.appendingPathComponent("wip.txt"),
                          atomically: true, encoding: .utf8)

        let preflight = mgr.deletionPreflight(wt)
        XCTAssertFalse(preflight.isSafe)
        XCTAssertEqual(preflight.warnings.count, 2)
        XCTAssertTrue(preflight.warnings.contains { $0.contains("uncommitted") })
        XCTAssertTrue(preflight.warnings.contains { $0.contains("not pushed") })
        XCTAssertEqual(preflight.status.commitsAhead, 1)
        XCTAssertEqual(preflight.status.lastCommitSubject, "agent work")
    }

    /// Removing a checkout must not destroy the commits on its branch — that's a separate,
    /// explicit decision.
    func testRemoveKeepsBranchUnlessAskedToDeleteIt() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)

        let keep = try mgr.create(base: base, branch: "orchard/keep-branch", from: ref)
        XCTAssertTrue(try mgr.remove(keep))
        XCTAssertTrue(mgr.localBranches(in: base).contains("orchard/keep-branch"))

        let drop = try mgr.create(base: base, branch: "orchard/drop-branch", from: ref)
        let mergedPreflight = mgr.deletionPreflight(drop)
        XCTAssertTrue(mergedPreflight.branchMerged)
        XCTAssertEqual(mergedPreflight.branchStatusMessage,
                       "branch 'orchard/drop-branch' is merged")
        XCTAssertTrue(try mgr.remove(drop, deleteBranch: true))
        XCTAssertFalse(mgr.localBranches(in: base).contains("orchard/drop-branch"))
    }

    /// T40: `--delete-branch` is `git branch -d`. Unmerged branches are refused with
    /// git's exact first line and the worktree is left in place; `--force-branch`
    /// uses `-D` and actually deletes it.
    func testDeleteBranchRefusesUnmergedUnlessForceBranch() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        let ref = try mgr.resolveRef("HEAD", in: base)
        let wt = try mgr.create(base: base, branch: "orchard/unmerged", from: ref)

        try "extra\n".write(to: wt.path.appendingPathComponent("extra.txt"),
                            atomically: true, encoding: .utf8)
        XCTAssertEqual(try git(["add", "."], cwd: wt.path), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "unmerged work"], cwd: wt.path), 0)

        let preflight = mgr.deletionPreflight(wt)
        XCTAssertFalse(preflight.branchMerged)
        XCTAssertEqual(preflight.branchStatusMessage,
                       "branch 'orchard/unmerged' is not fully merged")
        XCTAssertTrue(preflight.warnings.contains { $0.contains("not pushed") })

        XCTAssertThrowsError(try mgr.remove(wt, deleteBranch: true)) { error in
            let refusal = error as? BranchDeletionError
            XCTAssertEqual(refusal?.branch, "orchard/unmerged")
            XCTAssertEqual(refusal?.message,
                           BranchDeletionError.unmergedMessage(for: "orchard/unmerged"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path.path),
                      "an unmerged --delete-branch must not remove the worktree")
        XCTAssertTrue(mgr.localBranches(in: base).contains("orchard/unmerged"))

        XCTAssertTrue(try mgr.remove(wt, deleteBranch: true, forceBranch: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path.path))
        XCTAssertFalse(mgr.localBranches(in: base).contains("orchard/unmerged"))
    }

    func testLocalBranchesListsCurrentBranchFirst() throws {
        let repo = try makeRepo()
        let mgr = WorktreeManager(root: tmp.appendingPathComponent("worktrees"))
        let base = try mgr.detectBaseRepo(from: repo)
        XCTAssertEqual(try git(["branch", "zzz-later"], cwd: repo), 0)

        let branches = mgr.localBranches(in: base)
        XCTAssertEqual(branches.first, mgr.currentBranch(in: base))
        XCTAssertTrue(branches.contains("zzz-later"))
    }
}
