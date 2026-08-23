import XCTest
@testable import OrchardCore

final class ReviewFileTreeTests: XCTestCase {
    private func file(_ path: String) -> GitFileChange {
        GitFileChange(path: path, kind: .modified, added: 1, deleted: 0)
    }

    func testRootFilesStayUngrouped() {
        let roots = ReviewFileTree.collapsedRoots(from: [file("README.md"), file("LICENSE")])
        XCTAssertEqual(roots.map(\.path), ["LICENSE", "README.md"])
        XCTAssertEqual(roots.map(\.label), ["LICENSE", "README.md"])
        XCTAssertTrue(roots.allSatisfy { $0.file != nil && $0.children.isEmpty })
    }

    func testSiblingFilesShareADirectoryNode() {
        let roots = ReviewFileTree.collapsedRoots(from: [
            file("Sources/A.swift"),
            file("Sources/B.swift"),
        ])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].path, "Sources")
        XCTAssertEqual(roots[0].label, "Sources")
        XCTAssertNil(roots[0].file)
        XCTAssertEqual(roots[0].fileCount, 2)
        XCTAssertEqual(roots[0].children.map(\.label), ["A.swift", "B.swift"])
    }

    func testUnaryDirectoryChainsCollapse() {
        let roots = ReviewFileTree.collapsedRoots(from: [
            file("Sources/OrchardCore/Git/GitService.swift"),
            file("Sources/OrchardCore/Git/GitRunner.swift"),
        ])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].label, "Sources/OrchardCore/Git")
        XCTAssertEqual(roots[0].path, "Sources/OrchardCore/Git")
        XCTAssertEqual(roots[0].fileCount, 2)
        XCTAssertEqual(roots[0].children.map(\.label), ["GitRunner.swift", "GitService.swift"])
    }

    func testDoesNotCollapseADirectoryThatOnlyHoldsOneFile() {
        let roots = ReviewFileTree.collapsedRoots(from: [file("docs/REBUILD-PLAN.md")])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].label, "docs")
        XCTAssertEqual(roots[0].children.map(\.label), ["REBUILD-PLAN.md"])
        XCTAssertEqual(roots[0].children.first?.file?.path, "docs/REBUILD-PLAN.md")
    }

    func testCollapsesPrefixThenBranches() {
        let roots = ReviewFileTree.collapsedRoots(from: [
            file("Sources/OrchardApp/DiffPaneView.swift"),
            file("Sources/OrchardCore/Git/GitService.swift"),
            file("README.md"),
        ])
        XCTAssertEqual(roots.map(\.label), ["README.md", "Sources"])
        let sources = roots[1]
        XCTAssertEqual(sources.children.map(\.label), ["OrchardApp", "OrchardCore/Git"])
        XCTAssertEqual(sources.children[0].children.map(\.label), ["DiffPaneView.swift"])
        XCTAssertEqual(sources.children[1].children.map(\.label), ["GitService.swift"])
    }

    func testEmptyInput() {
        XCTAssertTrue(ReviewFileTree.collapsedRoots(from: []).isEmpty)
    }

    func testOutlineChildrenNilForFiles() {
        let roots = ReviewFileTree.collapsedRoots(from: [file("README.md")])
        XCTAssertNil(roots[0].outlineChildren)
        let grouped = ReviewFileTree.collapsedRoots(from: [file("a/b.swift"), file("a/c.swift")])
        XCTAssertEqual(grouped[0].outlineChildren?.count, 2)
    }
}

final class ReviewHunkIndexTests: XCTestCase {
    func testFindsHunkHeadersAndIgnoresContentLookalikes() {
        let diff = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,4 @@
         context
        +added
        -removed
         @@ not a header
        +@@ still not a header
        @@ -10,2 +11,2 @@ second
         x
        """
        XCTAssertEqual(ReviewHunkIndex.lineIndices(inDiff: diff), [3, 9])
    }

    func testEmptyAndHeaderlessDiffsHaveNoHunks() {
        XCTAssertTrue(ReviewHunkIndex.lineIndices(inDiff: "").isEmpty)
        XCTAssertTrue(ReviewHunkIndex.lineIndices(inDiff: "Binary files a and b differ\n").isEmpty)
    }

    func testMoveWrapsAndEmptyStaysAtZero() {
        XCTAssertEqual(ReviewHunkIndex.move(current: 0, count: 3, delta: 1), 1)
        XCTAssertEqual(ReviewHunkIndex.move(current: 2, count: 3, delta: 1), 0)
        XCTAssertEqual(ReviewHunkIndex.move(current: 0, count: 3, delta: -1), 2)
        XCTAssertEqual(ReviewHunkIndex.move(current: 1, count: 1, delta: 1), 0)
        XCTAssertEqual(ReviewHunkIndex.move(current: 4, count: 0, delta: 1), 0)
    }

    func testClampAfterReload() {
        XCTAssertEqual(ReviewHunkIndex.clamp(current: 4, count: 2), 1)
        XCTAssertEqual(ReviewHunkIndex.clamp(current: -1, count: 2), 0)
        XCTAssertEqual(ReviewHunkIndex.clamp(current: 1, count: 0), 0)
    }

    func testPositionLabelIsOneBased() {
        XCTAssertEqual(ReviewHunkIndex.positionLabel(current: 0, count: 5), "1/5")
        XCTAssertEqual(ReviewHunkIndex.positionLabel(current: 4, count: 5), "5/5")
        XCTAssertEqual(ReviewHunkIndex.positionLabel(current: 0, count: 0), "0 hunks")
    }
}

final class ReviewUpstreamStateTests: XCTestCase {
    func testNilMeansNoUpstreamPushUWording() {
        let state = ReviewUpstreamState(unpushedCommits: nil)
        XCTAssertEqual(state, .noUpstream)
        XCTAssertEqual(state.buttonTitle, "Push -u")
        XCTAssertTrue(state.help.contains("No upstream"))
        XCTAssertTrue(state.help.contains("push -u"))
        XCTAssertTrue(state.canPush)
    }

    func testZeroMeansUpToDate() {
        let state = ReviewUpstreamState(unpushedCommits: 0)
        XCTAssertEqual(state, .upToDate)
        XCTAssertEqual(state.buttonTitle, "Up to date")
        XCTAssertFalse(state.canPush)
    }

    func testPositiveCountShowsAheadWording() {
        XCTAssertEqual(ReviewUpstreamState(unpushedCommits: 1).buttonTitle, "Push 1 commit")
        XCTAssertEqual(ReviewUpstreamState(unpushedCommits: 4).buttonTitle, "Push 4 commits")
        XCTAssertEqual(ReviewUpstreamState(unpushedCommits: 4).help, "4 commits ahead of upstream")
        XCTAssertTrue(ReviewUpstreamState(unpushedCommits: 2).canPush)
    }
}

final class ReviewCommitGateTests: XCTestCase {
    func testMessageRequiredAndNoAutoCommitPath() {
        XCTAssertFalse(ReviewCommitGate.isMessageUsable(""))
        XCTAssertFalse(ReviewCommitGate.isMessageUsable("   \n\t"))
        XCTAssertTrue(ReviewCommitGate.isMessageUsable("fix parser"))
        XCTAssertFalse(ReviewCommitGate.canCommit(message: "ok", hasUncommittedChanges: false, isBusy: false))
        XCTAssertFalse(ReviewCommitGate.canCommit(message: "ok", hasUncommittedChanges: true, isBusy: true))
        XCTAssertFalse(ReviewCommitGate.canCommit(message: "  ", hasUncommittedChanges: true, isBusy: false))
        XCTAssertTrue(ReviewCommitGate.canCommit(message: "ok", hasUncommittedChanges: true, isBusy: false))
    }
}

final class ReviewGitFailureTests: XCTestCase {
    func testPrefersGitStderrEmbeddedInGitError() {
        let error = GitError("git commit -m x failed (1): nothing to commit, working tree clean")
        XCTAssertEqual(ReviewGitFailure.displayText(error),
                       "git commit -m x failed (1): nothing to commit, working tree clean")
    }

    func testFallsBackToLocalizedDescriptionForOtherErrors() {
        struct Other: Error {}
        let text = ReviewGitFailure.displayText(Other())
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("nothing to commit"))
    }
}
