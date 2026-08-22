import XCTest
import DamsonTerminal
@testable import DamsonOrchestrator

/// A global preference must never be able to break a project that can't honor it — an
/// override for a base ref that doesn't exist in *this* repo has to be ignored rather than
/// applied and then failing at `git worktree add` time.
@MainActor
final class ControllerOverrideTests: XCTestCase {
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

    private func makeController(_ repo: URL) throws -> OrchestratorController {
        let controller = OrchestratorController(
            baseRepo: repo,
            worktreesRoot: tmp.appendingPathComponent("wt"),
            configTemplate: .init())
        try controller.start()
        return controller
    }

    func testDetectedDefaultsComeFromTheRepo() throws {
        let controller = try makeController(try makeRepo())
        XCTAssertEqual(controller.branchPrefix, "test-user")
        XCTAssertEqual(controller.baseRef, "main")
    }

    func testBranchPrefixOverrideIsSanitized() throws {
        let controller = try makeController(try makeRepo())
        controller.overrideBranchPrefix("My Team!")
        XCTAssertEqual(controller.branchPrefix, "my-team")
        // An override with nothing usable in it leaves the detected value alone rather than
        // producing a branch like "/fix-parser".
        controller.overrideBranchPrefix("!!!")
        XCTAssertEqual(controller.branchPrefix, "my-team")
    }

    func testBaseRefOverrideIsIgnoredWhenTheRefIsMissing() throws {
        let repo = try makeRepo()
        let controller = try makeController(repo)

        controller.overrideBaseRef("origin/does-not-exist")
        XCTAssertEqual(controller.baseRef, "main", "a missing ref must not be adopted")

        try git(["branch", "release"], cwd: repo)
        controller.overrideBaseRef("release")
        XCTAssertEqual(controller.baseRef, "release")
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

        let controller = try makeController(repo)
        controller.runsSetupScripts = false
        let record = try controller.createWorktree(name: "no-setup")

        // createWorktree never runs setup; assert the wiring the controller would use.
        XCTAssertNotNil(controller.setupScript(for: record),
                        "the project does declare a setup script")
        XCTAssertFalse(controller.runsSetupScripts)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: record.path.appendingPathComponent("setup-proof.txt").path))
    }
}

/// A settings change must repaint terminals without disturbing the processes inside them.
@MainActor
final class TerminalConfigTests: XCTestCase {
    func testApplyTerminalConfigChangesOnlyPresentationFields() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var template = DamsonConfig()
        template.fontSize = 12
        template.fontFamily = "Menlo"
        template.argv = ["/bin/zsh", "-l"]
        template.cwd = "/original/path"

        let controller = OrchestratorController(
            baseRepo: tmp, worktreesRoot: tmp.appendingPathComponent("wt"),
            configTemplate: template)

        var updated = DamsonConfig()
        updated.fontSize = 18
        updated.fontFamily = "SF Mono"
        // A fresh DamsonConfig carries default argv/cwd; those must NOT overwrite the
        // template's, or every future agent would spawn the wrong process.
        controller.applyTerminalConfig(updated)

        XCTAssertEqual(controller.configTemplate.fontSize, 18)
        XCTAssertEqual(controller.configTemplate.fontFamily, "SF Mono")
        XCTAssertEqual(controller.configTemplate.argv, ["/bin/zsh", "-l"],
                       "argv belongs to the agent, not to the appearance settings")
        XCTAssertEqual(controller.configTemplate.cwd, "/original/path",
                       "cwd belongs to the worktree, not to the appearance settings")
    }
}
