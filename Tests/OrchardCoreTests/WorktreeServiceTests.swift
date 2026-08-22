import XCTest
@testable import OrchardCore

/// A global preference must never be able to break a project that can't honor it — an
/// override for a base ref that doesn't exist in *this* repo has to be ignored rather than
/// applied and then failing at `git worktree add` time.
///
/// Ported from v1's `ControllerOverrideTests`: the same behaviors now live on the headless
/// `WorktreeService` (the worktree half of the deleted `OrchestratorController`). The
/// damson-specific `TerminalConfigTests` case died with the controller's theme glue.
@MainActor
final class WorktreeServiceTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-override-\(UUID().uuidString)")
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
        try git(["config", "user.name", "Test User"], cwd: repo)
        try "x\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        return repo
    }

    private func makeService(_ repo: URL) throws -> WorktreeService {
        let service = WorktreeService(
            baseRepo: repo,
            worktreesRoot: tmp.appendingPathComponent("wt"))
        try service.start()
        return service
    }

    func testDetectedDefaultsComeFromTheRepo() throws {
        let service = try makeService(try makeRepo())
        XCTAssertEqual(service.branchPrefix, "test-user")
        XCTAssertEqual(service.baseRef, "main")
    }

    func testBranchPrefixOverrideIsSanitized() throws {
        let service = try makeService(try makeRepo())
        service.overrideBranchPrefix("My Team!")
        XCTAssertEqual(service.branchPrefix, "my-team")
        // An override with nothing usable in it leaves the detected value alone rather than
        // producing a branch like "/fix-parser".
        service.overrideBranchPrefix("!!!")
        XCTAssertEqual(service.branchPrefix, "my-team")
    }

    func testBaseRefOverrideIsIgnoredWhenTheRefIsMissing() throws {
        let repo = try makeRepo()
        let service = try makeService(repo)

        service.overrideBaseRef("origin/does-not-exist")
        XCTAssertEqual(service.baseRef, "main", "a missing ref must not be adopted")

        try git(["branch", "release"], cwd: repo)
        service.overrideBaseRef("release")
        XCTAssertEqual(service.baseRef, "release")
    }

    /// The setup-script toggle has to actually gate execution, not just render a checkbox.
    func testSetupScriptsCanBeDisabled() throws {
        let repo = try makeRepo()
        try """
        scripts:
          setup: |
            echo ran > setup-proof.txt
        """.write(to: repo.appendingPathComponent("orchard.yaml"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "add config"], cwd: repo)

        let service = try makeService(repo)
        service.runsSetupScripts = false
        let record = try service.createWorktree(name: "no-setup")

        // The gate lives in runSetupScriptIfEnabled; with the toggle off it must no-op.
        XCTAssertNotNil(service.setupScript(for: record),
                        "the project does declare a setup script")
        service.runSetupScriptIfEnabled(for: record)
        XCTAssertEqual(record.setupState, .none, "a disabled toggle must not even mark running")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: record.path.appendingPathComponent("setup-proof.txt").path))
    }
}
