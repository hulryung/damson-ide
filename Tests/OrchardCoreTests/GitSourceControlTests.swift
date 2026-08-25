import XCTest
@testable import OrchardCore

/// Porcelain decoding for the source-control panel. Same `-z` / rename-second-field
/// trap as conflict porcelain — a mocked runner would not prove the framing.
final class GitSourceControlPorcelainTests: XCTestCase {
    func testSplitsStagedAndUnstagedAndKeepsUntrackedUnstaged() {
        let out = "M  staged.txt\0 M unstaged.txt\0?? new.txt\0"
        let parsed = GitSourceControlService.parsePorcelain(out)
        XCTAssertEqual(parsed.staged.map(\.path), ["staged.txt"])
        XCTAssertEqual(parsed.staged.first?.kind, .modified)
        XCTAssertEqual(parsed.staged.first?.area, .staged)
        XCTAssertEqual(parsed.unstaged.map(\.path), ["new.txt", "unstaged.txt"])
        XCTAssertEqual(parsed.unstaged.first?.kind, .untracked)
        XCTAssertEqual(parsed.unstaged.last?.kind, .modified)
    }

    func testBothStagedAndUnstagedWhenIndexAndWorktreeDiffer() {
        let parsed = GitSourceControlService.parsePorcelain("MM both.txt\0")
        XCTAssertEqual(parsed.staged.map(\.path), ["both.txt"])
        XCTAssertEqual(parsed.unstaged.map(\.path), ["both.txt"])
        XCTAssertEqual(parsed.staged.first?.kind, .modified)
        XCTAssertEqual(parsed.unstaged.first?.kind, .modified)
    }

    func testStatusLettersMatchDiffPaneVocabulary() {
        let parsed = GitSourceControlService.parsePorcelain(
            "A  added.txt\0D  deleted.txt\0T  typed.txt\0")
        XCTAssertEqual(parsed.staged.map(\.kind), [.added, .deleted, .typeChanged])
        XCTAssertEqual(parsed.staged.map(\.kind.letter), ["A", "D", "T"])
    }

    func testUnmergedCodesAreConflictedAndUnstaged() {
        let out = "UU src/a.swift\0AA both.txt\0DU mine.txt\0"
        let parsed = GitSourceControlService.parsePorcelain(out)
        XCTAssertTrue(parsed.staged.isEmpty)
        XCTAssertEqual(parsed.unstaged.map(\.path), ["both.txt", "mine.txt", "src/a.swift"])
        XCTAssertTrue(parsed.unstaged.allSatisfy { $0.kind == .conflicted })
        XCTAssertEqual(parsed.unstaged.first?.kind.letter, "!")
    }

    func testRenameOriginFieldDoesNotShiftLaterRecords() {
        let out = "R  new name.txt\0old name.txt\0 M other.txt\0"
        let parsed = GitSourceControlService.parsePorcelain(out)
        XCTAssertEqual(parsed.staged.map(\.path), ["new name.txt"])
        XCTAssertEqual(parsed.unstaged.map(\.path), ["other.txt"])
    }

    func testPathsWithSpacesSurvive() {
        let parsed = GitSourceControlService.parsePorcelain("?? a folder/with space.txt\0")
        XCTAssertEqual(parsed.unstaged.first?.path, "a folder/with space.txt")
        XCTAssertEqual(parsed.unstaged.first?.directory, "a folder")
        XCTAssertEqual(parsed.unstaged.first?.fileName, "with space.txt")
    }

    func testErrorCodesAreStable() {
        XCTAssertEqual(GitSourceControlError.emptyCommitMessage.code, "empty_commit_message")
        XCTAssertEqual(GitSourceControlError.emptyStagedSet.code, "empty_staged_set")
        XCTAssertEqual(GitSourceControlError.noRemote.code, "no_remote")
        XCTAssertEqual(GitSourceControlError.notARepository.code, "not_a_repository")
        XCTAssertEqual(GitSourceControlError.invalidBranchName.code, "invalid_branch_name")
        XCTAssertEqual(GitSourceControlError.branchExists("x").code, "branch_exists")
        XCTAssertEqual(GitSourceControlError.branchNotFound("x").code, "branch_not_found")
        XCTAssertEqual(GitSourceControlError.gitFailed("boom").code, "git_failed")
        XCTAssertTrue(GitSourceControlError.emptyStagedSet.displayText.hasPrefix("empty_staged_set"))
    }
}

/// Real fixture repos. Stage/commit/branch/push are about git's actual index,
/// so a mocked runner would test the wrong thing.
final class GitSourceControlServiceTests: XCTestCase {
    private var tmp: URL!
    private let service = GitSourceControlService()

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-source-control-\(UUID().uuidString)")
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
        env["GIT_OPTIONAL_LOCKS"] = "0"
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

    private func makeRepo(name: String = "repo") throws -> URL {
        let repo = tmp.appendingPathComponent(name)
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

    private func subject(_ repo: URL) -> String? {
        GitRunner.shared.line(in: repo, ["log", "-1", "--pretty=%s"])
    }

    // MARK: -

    func testCleanRepoSnapshot() throws {
        let repo = try makeRepo()
        let snap = try service.snapshot(worktree: repo)
        XCTAssertEqual(snap.branch, "main")
        XCTAssertEqual(snap.branches, ["main"])
        XCTAssertTrue(snap.isClean)
        XCTAssertFalse(snap.hasRemote)
        XCTAssertNil(snap.preferredRemote)
    }

    func testNotARepositoryIsTyped() throws {
        let folder = tmp.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.snapshot(worktree: folder)) { error in
            XCTAssertEqual(error as? GitSourceControlError, .notARepository)
        }
        XCTAssertThrowsError(try service.stageAll(worktree: folder)) { error in
            XCTAssertEqual(error as? GitSourceControlError, .notARepository)
        }
    }

    func testUntrackedAndModifiedAppearUnstagedUntilStaged() throws {
        let repo = try makeRepo()
        try write("a\nb\nc\nd\n", to: "keep.txt", in: repo)
        try write("x\n", to: "src/new.swift", in: repo)

        let snap = try service.snapshot(worktree: repo)
        XCTAssertTrue(snap.staged.isEmpty)
        XCTAssertEqual(snap.unstaged.map(\.path), ["keep.txt", "src/new.swift"])
        XCTAssertEqual(snap.unstaged.map(\.kind), [.modified, .untracked])
        XCTAssertEqual(snap.unstaged.map(\.kind.letter), ["M", "U"])
    }

    func testStageAndUnstageOneFile() throws {
        let repo = try makeRepo()
        try write("x\n", to: "fresh.txt", in: repo)
        try write("a\nb\nc\nZ\n", to: "keep.txt", in: repo)

        try service.stage(worktree: repo, path: "fresh.txt")
        var snap = try service.snapshot(worktree: repo)
        XCTAssertEqual(snap.staged.map(\.path), ["fresh.txt"])
        XCTAssertEqual(snap.staged.first?.kind, .added)
        XCTAssertEqual(snap.unstaged.map(\.path), ["keep.txt"])

        try service.unstage(worktree: repo, path: "fresh.txt")
        snap = try service.snapshot(worktree: repo)
        XCTAssertTrue(snap.staged.isEmpty)
        XCTAssertEqual(Set(snap.unstaged.map(\.path)), ["fresh.txt", "keep.txt"])
        XCTAssertEqual(snap.unstaged.first { $0.path == "fresh.txt" }?.kind, .untracked)
    }

    func testStageAllAndUnstageAll() throws {
        let repo = try makeRepo()
        try write("x\n", to: "fresh.txt", in: repo)
        XCTAssertEqual(try git(["rm", "-q", "drop.txt"], cwd: repo), 0)

        try service.stageAll(worktree: repo)
        var snap = try service.snapshot(worktree: repo)
        XCTAssertEqual(snap.staged.map(\.path), ["drop.txt", "fresh.txt"])
        XCTAssertEqual(snap.staged.map(\.kind), [.deleted, .added])
        XCTAssertTrue(snap.unstaged.isEmpty)

        try service.unstageAll(worktree: repo)
        snap = try service.snapshot(worktree: repo)
        XCTAssertTrue(snap.staged.isEmpty)
        XCTAssertEqual(Set(snap.unstaged.map(\.path)), ["drop.txt", "fresh.txt"])
    }

    func testUnstageAllOnEmptyIndexIsNotAnError() throws {
        let repo = try makeRepo()
        XCTAssertNoThrow(try service.unstageAll(worktree: repo))
        XCTAssertTrue(try service.snapshot(worktree: repo).isClean)
    }

    func testPathsWithSpacesRoundTripThroughStage() throws {
        let repo = try makeRepo()
        try write("hi\n", to: "a folder/with space.txt", in: repo)
        try service.stage(worktree: repo, path: "a folder/with space.txt")
        let snap = try service.snapshot(worktree: repo)
        XCTAssertEqual(snap.staged.map(\.path), ["a folder/with space.txt"])
    }

    func testCommitRefusesEmptyMessage() throws {
        let repo = try makeRepo()
        try write("x\n", to: "fresh.txt", in: repo)
        try service.stageAll(worktree: repo)
        XCTAssertThrowsError(try service.commit(worktree: repo, message: "   \n")) { error in
            XCTAssertEqual(error as? GitSourceControlError, .emptyCommitMessage)
        }
        XCTAssertEqual(subject(repo), "init")
    }

    func testCommitRefusesEmptyStagedSet() throws {
        let repo = try makeRepo()
        try write("x\n", to: "fresh.txt", in: repo)
        XCTAssertThrowsError(try service.commit(worktree: repo, message: "should not land")) { error in
            XCTAssertEqual(error as? GitSourceControlError, .emptyStagedSet)
        }
        XCTAssertEqual(subject(repo), "init")
        XCTAssertTrue(try service.snapshot(worktree: repo).staged.isEmpty)
    }

    func testCommitLeavesUnstagedFilesAndClearsTheIndex() throws {
        let repo = try makeRepo()
        try write("x\n", to: "fresh.txt", in: repo)
        try write("a\nb\nc\nZ\n", to: "keep.txt", in: repo)
        try service.stage(worktree: repo, path: "fresh.txt")

        let sha = try service.commit(worktree: repo, message: "add fresh")
        XCTAssertFalse(sha.isEmpty)
        XCTAssertEqual(subject(repo), "add fresh")

        let snap = try service.snapshot(worktree: repo)
        XCTAssertTrue(snap.staged.isEmpty)
        XCTAssertEqual(snap.unstaged.map(\.path), ["keep.txt"])
        XCTAssertEqual(snap.unstaged.first?.kind, .modified)
    }

    func testSwitchAndCreateBranch() throws {
        let repo = try makeRepo()
        try service.createBranch(worktree: repo, name: "topic")
        var snap = try service.snapshot(worktree: repo)
        XCTAssertEqual(snap.branch, "topic")
        XCTAssertEqual(snap.branches, ["main", "topic"])

        try service.switchBranch(worktree: repo, name: "main")
        snap = try service.snapshot(worktree: repo)
        XCTAssertEqual(snap.branch, "main")
    }

    func testCreateBranchRefusesEmptyAndExistingAndIllegalNames() throws {
        let repo = try makeRepo()
        XCTAssertThrowsError(try service.createBranch(worktree: repo, name: "  ")) { error in
            XCTAssertEqual(error as? GitSourceControlError, .invalidBranchName)
        }
        XCTAssertThrowsError(try service.createBranch(worktree: repo, name: "main")) { error in
            XCTAssertEqual(error as? GitSourceControlError, .branchExists("main"))
        }
        XCTAssertThrowsError(try service.createBranch(worktree: repo, name: "bad..name")) { error in
            XCTAssertEqual(error as? GitSourceControlError, .invalidBranchName)
        }
        XCTAssertThrowsError(try service.switchBranch(worktree: repo, name: "missing")) { error in
            XCTAssertEqual(error as? GitSourceControlError, .branchNotFound("missing"))
        }
        XCTAssertEqual(try service.snapshot(worktree: repo).branch, "main")
    }

    func testPushAndPullRefuseWithoutARemote() throws {
        let repo = try makeRepo()
        XCTAssertThrowsError(try service.push(worktree: repo)) { error in
            XCTAssertEqual(error as? GitSourceControlError, .noRemote)
        }
        XCTAssertThrowsError(try service.pull(worktree: repo)) { error in
            XCTAssertEqual(error as? GitSourceControlError, .noRemote)
        }
    }

    func testPushAndPullAgainstALocalRemote() throws {
        let repo = try makeRepo()
        let bare = tmp.appendingPathComponent("origin.git")
        XCTAssertEqual(try git(["clone", "-q", "--bare", repo.path, bare.path], cwd: tmp), 0)
        XCTAssertEqual(try git(["remote", "add", "origin", bare.path], cwd: repo), 0)

        let snap = try service.snapshot(worktree: repo)
        XCTAssertTrue(snap.hasRemote)
        XCTAssertEqual(snap.preferredRemote, "origin")

        try write("pushed\n", to: "fresh.txt", in: repo)
        try service.stageAll(worktree: repo)
        try service.commit(worktree: repo, message: "land fresh")
        XCTAssertNoThrow(try service.push(worktree: repo))

        let other = tmp.appendingPathComponent("other")
        XCTAssertEqual(try git(["clone", "-q", bare.path, other.path], cwd: tmp), 0)
        try git(["config", "user.email", "test@orchard.app"], cwd: other)
        try git(["config", "user.name", "Test"], cwd: other)
        try write("from-other\n", to: "other.txt", in: other)
        XCTAssertEqual(try git(["add", "other.txt"], cwd: other), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "from other"], cwd: other), 0)
        XCTAssertEqual(try git(["push", "-q", "origin", "HEAD"], cwd: other), 0)

        XCTAssertNoThrow(try service.pull(worktree: repo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("other.txt").path))
        XCTAssertEqual(subject(repo), "from other")
    }

    func testConflictedFileUsesDiffPaneLetter() throws {
        let repo = try makeRepo()
        XCTAssertEqual(try git(["checkout", "-q", "-b", "feature"], cwd: repo), 0)
        try write("feature\n", to: "keep.txt", in: repo)
        XCTAssertEqual(try git(["commit", "-qam", "feature edit"], cwd: repo), 0)
        XCTAssertEqual(try git(["checkout", "-q", "main"], cwd: repo), 0)
        try write("mainline\n", to: "keep.txt", in: repo)
        XCTAssertEqual(try git(["commit", "-qam", "main edit"], cwd: repo), 0)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)

        let snap = try service.snapshot(worktree: repo)
        let keep = try XCTUnwrap(snap.unstaged.first { $0.path == "keep.txt" })
        XCTAssertEqual(keep.kind, .conflicted)
        XCTAssertEqual(keep.kind.letter, "!")
        XCTAssertTrue(snap.staged.isEmpty)
    }
}
