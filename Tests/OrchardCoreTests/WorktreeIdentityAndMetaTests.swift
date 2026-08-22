import XCTest
@testable import OrchardCore

final class WorktreeIdentityTests: XCTestCase {
    func testFormatsAndParsesRepoIdAndPath() {
        let raw = WorktreeIdentity.make(repoId: "abc", path: "/tmp/wt/fix")
        XCTAssertEqual(raw, "abc::/tmp/wt/fix")
        let parsed = WorktreeIdentity.parse(raw)
        XCTAssertEqual(parsed?.repoId, "abc")
        XCTAssertEqual(parsed?.path, "/tmp/wt/fix")
    }

    func testFolderSessionIdKeepsWorkspacePrefixInPath() throws {
        let raw = WorktreeIdentity.make(repoId: "repo-1", path: "workspace:deadbeef")
        let parsed = try XCTUnwrap(WorktreeIdentity.parse(raw))
        XCTAssertEqual(parsed.repoId, "repo-1")
        XCTAssertEqual(parsed.path, "workspace:deadbeef")
    }

    func testBareRepoIdIsNotAWorktreeId() {
        XCTAssertNil(WorktreeIdentity.parse("abc"))
        XCTAssertNil(WorktreeIdentity.parse("abc::"))
        XCTAssertNil(WorktreeIdentity.parse("::/tmp/x"))
        XCTAssertNil(WorktreeIdentity.parse(""))
    }

    func testWorktreeWorkspaceIdUsesAbsolutePath() {
        let wt = Worktree(id: UUID(),
                          baseRepo: URL(fileURLWithPath: "/repos/app"),
                          path: URL(fileURLWithPath: "/wt/apricot"),
                          branch: "orchard/apricot")
        XCTAssertEqual(wt.workspaceId(repoId: "r1"), "r1::/wt/apricot")
    }
}

final class WorkspaceStatusTests: XCTestCase {
    func testFourDefaultsArePresent() {
        let ids = WorkspaceStatusDefinition.defaults.map(\.id)
        XCTAssertEqual(ids, ["todo", "in-progress", "in-review", "completed"])
        XCTAssertEqual(WorkspaceStatusDefinition.defaults.map(\.label),
                       ["Todo", "In progress", "In review", "Done"])
    }

    func testMetaDefaultsCopyGitFactsWithoutInventingLinks() {
        let wt = Worktree(id: UUID(),
                          baseRepo: URL(fileURLWithPath: "/r"),
                          path: URL(fileURLWithPath: "/w"),
                          branch: "b", title: "Fix parser")
        let meta = WorktreeMeta.defaults(for: wt)
        XCTAssertEqual(meta.instanceId, wt.id.uuidString)
        XCTAssertEqual(meta.displayName, "Fix parser")
        XCTAssertNil(meta.linkedIssue)
        XCTAssertNil(meta.linkedPR)
        XCTAssertFalse(meta.isPinned)
        XCTAssertNil(meta.workspaceStatus)
    }
}

final class WorktreeLineageTests: XCTestCase {
    func testNoParentIsDistinctFromMissingCapture() {
        let lineage = WorktreeLineage(
            worktreeId: "r::/wt/child",
            worktreeInstanceId: "child-id",
            parentWorktreeId: nil,
            parentWorktreeInstanceId: nil,
            origin: .cli,
            capture: LineageCapture(source: .explicitCLIFlag, confidence: .explicit))
        XCTAssertNil(lineage.parentWorktreeId)
        XCTAssertEqual(lineage.origin, .cli)
    }

    func testStaleInstanceIdIsRejectedAfterPathReuse() {
        let lineage = WorktreeLineage(
            worktreeId: "r::/wt/apricot",
            worktreeInstanceId: "OLD",
            parentWorktreeId: "r::/wt/parent",
            parentWorktreeInstanceId: "parent",
            origin: .orchestration,
            capture: LineageCapture(source: .orchestrationContext, confidence: .explicit))
        XCTAssertTrue(lineage.isStale(currentInstanceId: "NEW"))
        XCTAssertFalse(lineage.isStale(currentInstanceId: "OLD"))
    }
}

final class RetiredNameRegistryTests: XCTestCase {
    private let pool = WorktreeNaming.suggestedNames

    func testGeneratedNameIsNeverReissued() {
        var registry = RetiredNameRegistry.empty
        let first = WorktreeNaming.suggestName(taken: [], retired: registry)
        XCTAssertEqual(first, pool[0])
        registry = RetiredNames.adding([first], to: registry, pool: pool) ?? registry
        let second = WorktreeNaming.suggestName(taken: [], retired: registry)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second, pool[1])
    }

    func testUserTypedNonPoolNameIsNotCoveredByWatermark() {
        // Exhausting tier 1 must not make `fix-login-2` look retired.
        let allPool = Set(pool)
        let names = pool
        var registry = RetiredNameRegistry(names: names)
        registry = RetiredNames.compact(registry, pool: pool)
        XCTAssertEqual(registry.exhaustedTiers, 1)
        XCTAssertTrue(registry.names.isEmpty)
        XCTAssertTrue(RetiredNames.isRetired(pool[0], registry: registry, pool: allPool))
        XCTAssertFalse(RetiredNames.isRetired("fix-login-2", registry: registry, pool: allPool))
        XCTAssertFalse(RetiredNames.isRetired("apricot-2-3", registry: registry, pool: allPool))
    }

    func testCompactionFoldsACompleteTier() {
        let registry = RetiredNames.compact(
            RetiredNameRegistry(names: pool), pool: pool)
        XCTAssertEqual(registry.exhaustedTiers, 1)
        XCTAssertTrue(registry.names.isEmpty)
        let next = WorktreeNaming.suggestName(taken: [], retired: registry)
        XCTAssertTrue(next.hasSuffix("-2"), next)
    }

    func testAddingIsIdempotent() {
        let once = RetiredNames.adding(["apricot"], to: .empty, pool: pool)
        let twice = RetiredNames.adding(["apricot"], to: once!, pool: pool)
        XCTAssertNil(twice)
    }

    func testCollisionSuffixOnPoolNameIsItsOwnTier() {
        XCTAssertEqual(RetiredNames.poolNameTier("apricot", pool: WorktreeNaming.suggestedNameSet), 1)
        XCTAssertEqual(RetiredNames.poolNameTier("apricot-2", pool: WorktreeNaming.suggestedNameSet), 2)
        XCTAssertNil(RetiredNames.poolNameTier("apricot-1", pool: WorktreeNaming.suggestedNameSet))
        XCTAssertNil(RetiredNames.poolNameTier("apricot-2-3", pool: WorktreeNaming.suggestedNameSet))
    }
}
