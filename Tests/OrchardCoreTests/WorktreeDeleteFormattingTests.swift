import XCTest
@testable import OrchardCore

final class WorktreeDeleteFormattingTests: XCTestCase {
    func testPredictedOutcomeKeepsBranchUnlessAsked() {
        XCTAssertEqual(
            WorktreeDeleteFormatter.predictedOutcome(
                branch: "orchard/wt", branchMerged: true,
                deleteBranch: false, forceBranch: false),
            "The branch 'orchard/wt' will be kept.")
    }

    func testPredictedOutcomeDeletesMergedBranch() {
        XCTAssertEqual(
            WorktreeDeleteFormatter.predictedOutcome(
                branch: "orchard/wt", branchMerged: true,
                deleteBranch: true, forceBranch: false),
            "The branch 'orchard/wt' will be deleted (merged).")
    }

    func testPredictedOutcomeRefusesUnmergedWithoutForce() {
        XCTAssertEqual(
            WorktreeDeleteFormatter.predictedOutcome(
                branch: "orchard/wt", branchMerged: false,
                deleteBranch: true, forceBranch: false),
            "The branch 'orchard/wt' is not fully merged. Enable force-delete or the removal will be refused.")
    }

    func testPredictedOutcomeForceDeletesUnmergedBranch() {
        XCTAssertEqual(
            WorktreeDeleteFormatter.predictedOutcome(
                branch: "orchard/wt", branchMerged: false,
                deleteBranch: true, forceBranch: true),
            "The branch 'orchard/wt' will be force-deleted (not fully merged).")
    }

    func testResultMessageReportsDeletedOrKeptBranch() {
        XCTAssertEqual(
            WorktreeDeleteFormatter.resultMessage(
                branch: "orchard/wt", removed: true, branchDeleted: true),
            "Removed worktree. Deleted branch 'orchard/wt'.")
        XCTAssertEqual(
            WorktreeDeleteFormatter.resultMessage(
                branch: "orchard/wt", removed: true, branchDeleted: false),
            "Removed worktree. Branch 'orchard/wt' was kept.")
        XCTAssertEqual(
            WorktreeDeleteFormatter.resultMessage(
                branch: "orchard/wt", removed: false, branchDeleted: false),
            "Worktree was not removed.")
    }
}
