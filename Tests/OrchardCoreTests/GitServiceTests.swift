import XCTest
@testable import OrchardCore

/// Exercises `GitService` against a real fixture repo — the parsing here is all about
/// git's actual `-z` output framing, so a mocked runner would test the wrong thing.
final class GitServiceTests: XCTestCase {
    private var tmp: URL!
    private let service = GitService()

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-git-tests-\(UUID().uuidString)")
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

    /// Repo with one commit containing `keep.txt` (3 lines) and `drop.txt` (1 line).
    private func makeRepo() throws -> URL {
        let repo = tmp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(try git(["init", "-q", "-b", "main"], cwd: repo), 0)
        try git(["config", "user.email", "test@orchard.app"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        try write("a\nb\nc\n", to: "keep.txt", in: repo)
        try write("gone\n", to: "drop.txt", in: repo)
        XCTAssertEqual(try git(["add", "."], cwd: repo), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "init"], cwd: repo), 0)
        return repo
    }

    private func head(of repo: URL) -> String {
        GitRunner.shared.line(in: repo, ["rev-parse", "HEAD"]) ?? ""
    }

    // MARK: -

    func testCleanWorktreeReportsPristine() throws {
        let repo = try makeRepo()
        let status = service.status(worktree: repo, baseRef: head(of: repo))

        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.isPristine)
        XCTAssertTrue(status.stat.isEmpty)
        XCTAssertEqual(status.commitsAhead, 0)
        XCTAssertFalse(status.hasUncommittedChanges)
        // A fresh local branch has no upstream — distinct from "nothing to push".
        XCTAssertNil(status.unpushedCommits)
    }

    /// The headline case: modified + deleted + committed + untracked all roll up into one
    /// change set measured against the fork point, not against HEAD or the index.
    func testDiffStatSpansCommittedUncommittedAndUntracked() throws {
        let repo = try makeRepo()
        let base = head(of: repo)

        // Committed change on top of base.
        try write("a\nb\nc\nd\n", to: "keep.txt", in: repo)
        XCTAssertEqual(try git(["commit", "-qam", "extend keep"], cwd: repo), 0)

        // Uncommitted: a deletion and a brand-new untracked file.
        XCTAssertEqual(try git(["rm", "-q", "drop.txt"], cwd: repo), 0)
        try write("x\ny\n", to: "src/new.swift", in: repo)

        let status = service.status(worktree: repo, baseRef: base)
        let byPath = Dictionary(uniqueKeysWithValues: status.stat.files.map { ($0.path, $0) })

        XCTAssertEqual(status.stat.fileCount, 3)
        XCTAssertEqual(byPath["keep.txt"]?.kind, .modified)
        XCTAssertEqual(byPath["keep.txt"]?.added, 1)
        XCTAssertEqual(byPath["keep.txt"]?.deleted, 0)
        XCTAssertEqual(byPath["drop.txt"]?.kind, .deleted)
        XCTAssertEqual(byPath["drop.txt"]?.deleted, 1)
        XCTAssertEqual(byPath["src/new.swift"]?.kind, .untracked)
        XCTAssertEqual(byPath["src/new.swift"]?.added, 2)

        XCTAssertEqual(status.stat.added, 3)     // 1 + 2
        XCTAssertEqual(status.stat.deleted, 1)
        XCTAssertEqual(status.commitsAhead, 1)
        XCTAssertTrue(status.hasUncommittedChanges)
        XCTAssertEqual(status.lastCommitSubject, "extend keep")
        XCTAssertFalse(status.isPristine)
    }

    /// Paths with spaces are exactly why the parser reads `-z` framing rather than splitting
    /// on whitespace.
    func testPathsWithSpacesSurviveParsing() throws {
        let repo = try makeRepo()
        let base = head(of: repo)
        try write("hi\n", to: "a folder/with space.txt", in: repo)

        let stat = service.diffStat(worktree: repo, baseRef: base)
        XCTAssertEqual(stat.files.map(\.path), ["a folder/with space.txt"])
        XCTAssertEqual(stat.files.first?.directory, "a folder")
        XCTAssertEqual(stat.files.first?.fileName, "with space.txt")
    }

    func testDiffIncludesUntrackedFileContent() throws {
        let repo = try makeRepo()
        let base = head(of: repo)
        try write("brand new\n", to: "fresh.txt", in: repo)
        try write("a\nb\nc\nZ\n", to: "keep.txt", in: repo)

        let all = service.diff(worktree: repo, baseRef: base)
        XCTAssertTrue(all.contains("+Z"), "tracked modification should appear")
        XCTAssertTrue(all.contains("+brand new"), "untracked file should appear")

        // Scoping to one path excludes the other.
        let scoped = service.diff(worktree: repo, baseRef: base, path: "fresh.txt")
        XCTAssertTrue(scoped.contains("+brand new"))
        XCTAssertFalse(scoped.contains("+Z"))
    }

    func testBinaryFileReportsZeroCountsAndIsFlagged() throws {
        let repo = try makeRepo()
        let base = head(of: repo)
        try Data([0x00, 0x01, 0x02, 0x00, 0xFF])
            .write(to: repo.appendingPathComponent("blob.bin"))

        let stat = service.diffStat(worktree: repo, baseRef: base)
        let blob = try XCTUnwrap(stat.files.first { $0.path == "blob.bin" })
        XCTAssertTrue(blob.isBinary)
        XCTAssertEqual(blob.added, 0)
    }

    func testCommitAllStagesEverythingAndClearsDirtyState() throws {
        let repo = try makeRepo()
        let base = head(of: repo)
        try write("untracked\n", to: "new.txt", in: repo)

        let sha = try service.commitAll(worktree: repo, message: "agent work")
        XCTAssertFalse(sha.isEmpty)

        let status = service.status(worktree: repo, baseRef: base)
        XCTAssertFalse(status.hasUncommittedChanges)
        XCTAssertEqual(status.commitsAhead, 1)
        XCTAssertEqual(status.lastCommitSubject, "agent work")
        // The change is still visible against the fork point — that's the whole point of
        // measuring from base rather than HEAD.
        XCTAssertEqual(status.stat.files.map(\.path), ["new.txt"])
        XCTAssertEqual(status.stat.files.first?.kind, .added)
    }
}

/// Regression: the branch prefix comes from `git config user.name`, and a repo-local value
/// must win over the machine's global one — otherwise every agent branch in a repo with a
/// project-specific identity gets namespaced under the wrong person.
final class GitUserNameTests: XCTestCase {
    func testRepoLocalUserNameWinsOverGlobal() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-username-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = tmp
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Repo Local Name"])

        let manager = WorktreeManager(root: tmp.appendingPathComponent("wt"))
        XCTAssertEqual(manager.gitUserName(in: tmp), "Repo Local Name")
        XCTAssertEqual(WorktreeNaming.branchPrefix(gitUserName: manager.gitUserName(in: tmp)),
                       "repo-local-name")
    }
}
