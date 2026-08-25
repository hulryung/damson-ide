import XCTest
@testable import OrchardCore

/// T71: status-bar copy for workspace+branch, agent-bucket counts, runtime chip.
final class StatusBarProjectionTests: XCTestCase {
    func testWorkspaceLineJoinsNameAndBranch() {
        XCTAssertEqual(StatusBarProjection.workspaceLine(name: "orchard", branch: "main"),
                       "orchard · main")
        XCTAssertEqual(StatusBarProjection.workspaceLine(name: "orchard", branch: nil),
                       "orchard")
        XCTAssertEqual(StatusBarProjection.workspaceLine(name: "orchard", branch: "  "),
                       "orchard")
        XCTAssertEqual(StatusBarProjection.workspaceLine(name: nil, branch: "main"),
                       "No workspace")
        XCTAssertEqual(StatusBarProjection.workspaceLine(name: "  ", branch: "main"),
                       "No workspace")
    }

    func testRuntimeChipReusesT51MenuTitle() {
        XCTAssertEqual(
            StatusBarProjection.runtimeChip(.alive(runtimeId: "rt_abc")),
            WindowLifecycle.RuntimeIndication.alive(runtimeId: "rt_abc").menuTitle)
        XCTAssertEqual(
            StatusBarProjection.runtimeChip(.notListening),
            WindowLifecycle.RuntimeIndication.notListening.menuTitle)
        XCTAssertEqual(
            StatusBarProjection.runtimeChip(.unavailable),
            WindowLifecycle.RuntimeIndication.unavailable.menuTitle)
    }

    func testBucketSummaryKeepsDashboardOrderAndZeroCounts() {
        let buckets = [
            StatusBarBucketCount(id: "attention", glyph: "⚠", count: 1),
            StatusBarBucketCount(id: "working", glyph: "⟳", count: 2),
            StatusBarBucketCount(id: "done", glyph: "✓", count: 0),
            StatusBarBucketCount(id: "idle", glyph: "●", count: 3),
        ]
        XCTAssertEqual(StatusBarProjection.bucketSummary(buckets), "⚠1  ⟳2  ✓0  ●3")
        XCTAssertEqual(StatusBarProjection.bucketSummary([]), "")
    }
}
