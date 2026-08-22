import XCTest
@testable import OrchardCore

/// v1 parsed `orchard.yaml` `archive:` and never ran it. T4 wires it behind
/// `--run-hooks`: skipped (with a warning) unless the caller opted in.
@MainActor
final class WorktreeArchiveHookTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-archive-\(UUID().uuidString)")
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
        try "x\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try """
        scripts:
          archive: |
            echo archived > "$ORCHARD_ROOT_PATH/archived.txt"
        """.write(to: repo.appendingPathComponent("orchard.yaml"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        return repo
    }

    private func makeService(_ repo: URL) throws -> WorktreeService {
        let service = WorktreeService(baseRepo: repo,
                                      worktreesRoot: tmp.appendingPathComponent("wt"))
        try service.start()
        return service
    }

    func testArchiveHookIsSkippedWithoutRunHooks() throws {
        let repo = try makeRepo()
        let service = try makeService(repo)
        let record = try service.createWorktree(name: "skip-hooks")
        XCTAssertNotNil(service.archiveScript(for: record))

        let result = try service.deleteWorktree(record, force: true, runHooks: false)
        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.warning?.contains("archive hook skipped"), true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("archived.txt").path))
    }

    func testArchiveHookRunsWithRunHooks() throws {
        let repo = try makeRepo()
        let service = try makeService(repo)
        let record = try service.createWorktree(name: "run-hooks")

        let result = try service.deleteWorktree(record, force: true, runHooks: true)
        XCTAssertTrue(result.removed)
        XCTAssertNil(result.warning)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("archived.txt").path))
    }

    func testFailedArchiveHookWarnsButStillDeletes() throws {
        let repo = try makeRepo()
        try """
        scripts:
          archive: |
            exit 1
        """.write(to: repo.appendingPathComponent("orchard.yaml"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "failing archive"], cwd: repo)

        let service = try makeService(repo)
        let record = try service.createWorktree(name: "fail-archive")
        let path = record.path.path

        let result = try service.deleteWorktree(record, force: true, runHooks: true)
        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.warning?.contains("archive hook failed"), true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
