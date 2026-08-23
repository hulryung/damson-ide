import XCTest
@testable import OrchardRuntime

final class PortAttributionTests: XCTestCase {
    private let workspaces = [
        PortWorkspaceProbe(id: "repo::/repo", repoId: "repo",
                           displayName: "main", path: "/repo"),
        PortWorkspaceProbe(id: "repo::/repo/worktrees/feature", repoId: "repo",
                           displayName: "feature", path: "/repo/worktrees/feature"),
    ]

    func testCwdAncestryPicksTheDeepestWorktree() {
        let match = PortAttribution.attribute(
            cwd: "/repo/worktrees/feature/packages/app", to: workspaces)
        XCTAssertEqual(match?.workspace.id, "repo::/repo/worktrees/feature")
        XCTAssertEqual(match?.confidence, .cwd)
    }

    func testExactWorktreeRootMatches() {
        let match = PortAttribution.attribute(cwd: "/repo", to: workspaces)
        XCTAssertEqual(match?.workspace.id, "repo::/repo")
    }

    func testSiblingPathIsNotADescendant() {
        let feature = [workspaces[1]]
        XCTAssertNil(PortAttribution.attribute(
            cwd: "/repo/worktrees/feature-other/server", to: feature))
        XCTAssertNil(PortAttribution.attribute(
            cwd: "/repo/worktrees", to: feature))
    }

    func testTrailingSlashAndDotSegmentsNormalize() {
        let match = PortAttribution.attribute(
            cwd: "/repo/worktrees/feature/./src/", to: workspaces)
        XCTAssertEqual(match?.workspace.id, "repo::/repo/worktrees/feature")
    }

    func testMissingCwdOrEmptyWorkspaceListIsSkipped() {
        XCTAssertNil(PortAttribution.attribute(cwd: nil, to: workspaces))
        XCTAssertNil(PortAttribution.attribute(cwd: "", to: workspaces))
        XCTAssertNil(PortAttribution.attribute(cwd: "/repo/wt", to: []))
        XCTAssertNil(PortAttribution.attribute(cwd: "/unrelated", to: workspaces))
    }
}
