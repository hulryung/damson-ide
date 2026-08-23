import XCTest
@testable import OrchardCore

/// `git worktree list --porcelain` is the only way a remote worktree can be known, so
/// its parse is pinned here rather than discovered against a live host (T32).
final class WorktreePorcelainTests: XCTestCase {
    func testParsesPathHeadAndShortBranch() {
        let entries = WorktreePorcelain.parse("""
            worktree /srv/repo
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /home/ci/Orchard/worktrees/repo/apricot
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/ci/apricot

            """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "/srv/repo")
        XCTAssertEqual(entries[0].branch, "main")
        XCTAssertEqual(entries[1].branch, "ci/apricot")
        XCTAssertEqual(entries[1].head, "2222222222222222222222222222222222222222")
    }

    func testBareDetachedLockedAndPrunableAreFlaggedNotDropped() {
        let entries = WorktreePorcelain.parse("""
            worktree /srv/repo.git
            bare

            worktree /home/ci/wt/detached
            HEAD 3333333333333333333333333333333333333333
            detached

            worktree /home/ci/wt/stale
            HEAD 4444444444444444444444444444444444444444
            branch refs/heads/stale
            locked
            prunable gitdir file points to non-existent location
            """)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries[0].isBare)
        XCTAssertTrue(entries[1].isDetached)
        XCTAssertEqual(entries[1].branch, "")
        XCTAssertTrue(entries[2].isLocked)
        XCTAssertTrue(entries[2].isPrunable)
    }

    func testAnUnknownAttributeDoesNotMakeTheListingUnparseable() {
        // A newer git adding a line must not cost us the whole listing — the fallback
        // would be "this repo has no worktrees", which is the one wrong answer.
        let entries = WorktreePorcelain.parse("""
            worktree /srv/repo
            HEAD 5555555555555555555555555555555555555555
            branch refs/heads/main
            something-new whatever
            """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].branch, "main")
    }

    func testEmptyOutputIsNoEntries() {
        XCTAssertTrue(WorktreePorcelain.parse("").isEmpty)
        XCTAssertTrue(WorktreePorcelain.parse("\n\n").isEmpty)
    }

    func testNonBranchRefsAreLeftAlone() {
        XCTAssertEqual(WorktreePorcelain.shortBranch("refs/heads/a/b"), "a/b")
        XCTAssertEqual(WorktreePorcelain.shortBranch("refs/tags/v1"), "refs/tags/v1")
    }
}
