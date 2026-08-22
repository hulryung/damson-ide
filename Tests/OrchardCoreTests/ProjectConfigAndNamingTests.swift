import XCTest
@testable import OrchardCore

/// `orchard.yaml` is written by hand and read on every worktree create, so the parser has to
/// handle the shapes people actually type — block scalars, comments, quoting, odd indents —
/// and degrade to defaults rather than throwing on anything it doesn't recognize.
final class OrchardProjectConfigTests: XCTestCase {

    func testParsesBlockScalarScriptsAndSharedPaths() {
        let config = OrchardProjectConfig.parse("""
        scripts:
          setup: |
            npm install
            cp .env.example .env
          archive: |
            docker compose down
        sharedPaths:
          - node_modules
          - .env
        """)

        XCTAssertEqual(config.setup, "npm install\ncp .env.example .env")
        XCTAssertEqual(config.archive, "docker compose down")
        XCTAssertEqual(config.sharedPaths, ["node_modules", ".env"])
        XCTAssertFalse(config.isEmpty)
    }

    func testBlockScalarPreservesRelativeIndentation() {
        let config = OrchardProjectConfig.parse("""
        scripts:
          setup: |
            if [ -f Gemfile ]; then
              bundle install
            fi
        """)
        // The nested `bundle install` must keep its two extra spaces, or the emitted shell
        // script is malformed.
        XCTAssertEqual(config.setup, "if [ -f Gemfile ]; then\n  bundle install\nfi")
    }

    func testCommentsAndBlankLinesAreIgnored() {
        let config = OrchardProjectConfig.parse("""
        # what a new worktree needs
        scripts:
          # install deps
          setup: |
            make bootstrap

        sharedPaths:
          - .env
        """)
        XCTAssertEqual(config.setup, "make bootstrap")
        XCTAssertEqual(config.sharedPaths, [".env"])
    }

    func testInlineAndQuotedForms() {
        let config = OrchardProjectConfig.parse("""
        scripts:
          setup: "make bootstrap"
        sharedPaths: [node_modules, '.env.local']
        """)
        XCTAssertEqual(config.setup, "make bootstrap")
        XCTAssertEqual(config.sharedPaths, ["node_modules", ".env.local"])
    }

    /// orca calls this key `symlinkPaths`; accepting both means a config copied from an orca
    /// repo keeps working.
    func testAcceptsOrcaSymlinkPathsAlias() {
        let config = OrchardProjectConfig.parse("""
        symlinkPaths:
          - node_modules
        """)
        XCTAssertEqual(config.sharedPaths, ["node_modules"])
    }

    func testUnknownKeysAreIgnoredNotFatal() {
        let config = OrchardProjectConfig.parse("""
        version: 2
        futureFeature:
          nested: true
        scripts:
          setup: |
            echo hi
        """)
        XCTAssertEqual(config.setup, "echo hi")
    }

    func testEmptyAndGarbageInputYieldEmptyConfig() {
        XCTAssertTrue(OrchardProjectConfig.parse("").isEmpty)
        XCTAssertTrue(OrchardProjectConfig.parse("just some prose\nwith no keys").isEmpty)
    }

    func testMissingFileIsNotAnError() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-cfg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(OrchardProjectConfig.load(from: dir).isEmpty)
    }
}

/// Names end up in three user-facing places at once — a sidebar row, a git branch, and a
/// directory — so sanitizing has to produce something valid for git *and* readable.
final class WorktreeNamingTests: XCTestCase {

    func testSanitizeProducesGitSafeNames() {
        XCTAssertEqual(WorktreeNaming.sanitize("Fix the parser!"), "fix-the-parser")
        XCTAssertEqual(WorktreeNaming.sanitize("  spaced  out  "), "spaced-out")
        XCTAssertEqual(WorktreeNaming.sanitize("keep_under.score"), "keep_under.score")
    }

    /// `git check-ref-format` rejects refs containing `..`, and leading/trailing dots and
    /// dashes, so those have to be gone before the name reaches git.
    func testSanitizeRemovesGitIllegalSequences() {
        XCTAssertFalse(WorktreeNaming.sanitize("a..b").contains(".."))
        XCTAssertEqual(WorktreeNaming.sanitize("a...b"), "a.b")
        XCTAssertEqual(WorktreeNaming.sanitize("--lead-and-trail--"), "lead-and-trail")
        XCTAssertEqual(WorktreeNaming.sanitize("...dots..."), "dots")
    }

    func testSanitizeRejectsNamesWithNothingUsable() {
        XCTAssertEqual(WorktreeNaming.sanitize("!!!"), "")
        XCTAssertFalse(WorktreeNaming.isValid("!!!"))
        XCTAssertFalse(WorktreeNaming.isValid("   "))
        XCTAssertTrue(WorktreeNaming.isValid("ok"))
    }

    func testSanitizeIsLengthBounded() {
        XCTAssertLessThanOrEqual(WorktreeNaming.sanitize(String(repeating: "a", count: 300)).count, 60)
    }

    func testBranchPrefixFallsBackWhenGitUserIsUnusable() {
        XCTAssertEqual(WorktreeNaming.branchPrefix(gitUserName: "Dae Keun Kang"), "dae-keun-kang")
        XCTAssertEqual(WorktreeNaming.branchPrefix(gitUserName: nil), "orchard")
        XCTAssertEqual(WorktreeNaming.branchPrefix(gitUserName: "   "), "orchard")
        XCTAssertEqual(WorktreeNaming.branchPrefix(gitUserName: "!!!"), "orchard")
    }

    func testBranchNameComposition() {
        XCTAssertEqual(WorktreeNaming.branchName(prefix: "dkkang", name: "Fix parser"),
                       "dkkang/fix-parser")
        XCTAssertEqual(WorktreeNaming.branchName(prefix: "", name: "solo"), "solo")
        // An unusable leaf must still yield a valid ref rather than "prefix/".
        XCTAssertEqual(WorktreeNaming.branchName(prefix: "p", name: "!!!"), "p/agent")
    }

    func testSuggestNameSkipsTakenNamesAndNeverRepeats() {
        let first = WorktreeNaming.suggestName(taken: [])
        XCTAssertEqual(first, WorktreeNaming.suggestedNames[0])

        let second = WorktreeNaming.suggestName(taken: [first])
        XCTAssertNotEqual(second, first)

        // Exhausting the list rolls over to numbered variants rather than colliding.
        let all = Set(WorktreeNaming.suggestedNames)
        let overflow = WorktreeNaming.suggestName(taken: all)
        XCTAssertFalse(all.contains(overflow))
        XCTAssertTrue(overflow.hasSuffix("-2"))
    }
}

/// These guards stand between a bad path and `git worktree remove --force`, which recursively
/// deletes whatever it is pointed at.
final class WorktreeSafetyTests: XCTestCase {
    private let repo = URL(fileURLWithPath: "/Users/someone/dev/project")

    private func worktree(at path: String) -> Worktree {
        Worktree(baseRepo: repo, path: URL(fileURLWithPath: path), branch: "b")
    }

    func testRefusesToRemoveTheRepoItself() {
        XCTAssertThrowsError(try WorktreeManager.assertRemovable(worktree(at: repo.path)))
    }

    func testRefusesToRemoveAPathContainingTheRepo() {
        XCTAssertThrowsError(try WorktreeManager.assertRemovable(worktree(at: "/Users/someone/dev")))
    }

    func testRefusesFilesystemRootAndHome() {
        XCTAssertThrowsError(try WorktreeManager.assertRemovable(worktree(at: "/")))
        XCTAssertThrowsError(try WorktreeManager.assertRemovable(worktree(at: "/Users")))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertThrowsError(try WorktreeManager.assertRemovable(worktree(at: home)))
    }

    func testAllowsAnOrdinaryWorktreePath() {
        XCTAssertNoThrow(try WorktreeManager.assertRemovable(
            worktree(at: NSHomeDirectory() + "/Orchard/worktrees/project/fix-parser")))
    }

    func testWorktreeDirectoryMustStayInsideItsRoot() {
        let root = URL(fileURLWithPath: "/tmp/orchard-root")
        XCTAssertNoThrow(try WorktreeManager.assertInsideRoot(
            root.appendingPathComponent("fix"), root: root))
        XCTAssertThrowsError(try WorktreeManager.assertInsideRoot(
            URL(fileURLWithPath: "/tmp/elsewhere"), root: root))
        // The root itself is not a valid worktree directory.
        XCTAssertThrowsError(try WorktreeManager.assertInsideRoot(root, root: root))
    }

    /// `sharedPaths` comes from a repo file an agent can edit, so escapes must be rejected.
    func testSharedPathsRejectEscapes() {
        XCTAssertEqual(WorktreeManager.safeRelativePath("node_modules"), "node_modules")
        XCTAssertEqual(WorktreeManager.safeRelativePath("apps/web/.env"), "apps/web/.env")
        XCTAssertNil(WorktreeManager.safeRelativePath("/etc/passwd"))
        XCTAssertNil(WorktreeManager.safeRelativePath("~/.ssh/id_rsa"))
        XCTAssertNil(WorktreeManager.safeRelativePath("../../secrets"))
        XCTAssertNil(WorktreeManager.safeRelativePath("a/../../b"))
        XCTAssertNil(WorktreeManager.safeRelativePath(""))
    }
}

// AgentEnvironmentTests (session-marker scrubbing) moved to
// Tests/OrchardTerminalsTests/AgentEnvironmentTests.swift — the engines it exercises
// live in OrchardTerminals now.
