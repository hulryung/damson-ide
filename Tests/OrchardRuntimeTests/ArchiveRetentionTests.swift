import XCTest
import OrchardOrchestration
@testable import OrchardRuntime

/// T49 retention selection: which archives a size/age cap picks, and — more
/// importantly — which it refuses to pick. A live run's leftovers must survive every
/// policy, including one that cannot get under its own cap without them.
final class ArchiveRetentionTests: XCTestCase {

    private let now = ArchiveRetention.timestamp("2026-08-25 12:00:00")!

    private func record(
        _ dispatch: String,
        run: String? = "run_settled",
        daysAgo: Double,
        bytes: Int,
        kind: WorkerTerminalArchiveKind = .terminalTail
    ) -> WorkerArchiveRecord {
        WorkerArchiveRecord(
            dispatchID: dispatch,
            kind: kind,
            createdAt: OrchestrationStore.sqliteTimestamp(now.addingTimeInterval(-daysAgo * 86_400)),
            byteSize: bytes,
            runID: run,
            runObjective: run.map { "objective for \($0)" },
            taskID: "task_for_\(dispatch)",
            taskDisplayName: "T\(dispatch.suffix(1))",
            taskSpec: "work",
            dispatchStatus: .completed,
            workerState: "succeeded")
    }

    private func plan(
        _ records: [WorkerArchiveRecord],
        _ policy: ArchiveRetentionPolicy,
        protected: Set<String> = []
    ) -> ArchivePrunePlan {
        ArchiveRetention.plan(records: records, policy: policy, now: now, protectedRunIDs: protected)
    }

    // MARK: - Age

    func testAgeCapSelectsOnlyArchivesPastTheCutoff() {
        let result = plan([
            record("ctx_old", daysAgo: 40, bytes: 100),
            record("ctx_edge", daysAgo: 29, bytes: 100),
            record("ctx_new", daysAgo: 1, bytes: 100),
        ], ArchiveRetentionPolicy(maxTotalBytes: 0, maxAgeDays: 30))

        XCTAssertEqual(result.dispatchIDs, ["ctx_old"])
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertEqual(result.totalBytes, 300)
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertEqual(result.entries.first?.reason, .age)
    }

    func testZeroCapsKeepEverythingForever() {
        let records = [record("ctx_ancient", daysAgo: 3650, bytes: 10_000_000)]
        let result = plan(records, .keepForever)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.totalBytes, 10_000_000)
        XCTAssertEqual(result.remainingOverBytes, 0)
        XCTAssertEqual(result.summary, "Retention is off — nothing would be deleted.")
    }

    // MARK: - Size

    func testSizeCapDeletesOldestFirstUntilItFits() {
        let result = plan([
            record("ctx_a", daysAgo: 5, bytes: 100),
            record("ctx_b", daysAgo: 3, bytes: 100),
            record("ctx_c", daysAgo: 1, bytes: 100),
        ], ArchiveRetentionPolicy(maxTotalBytes: 150, maxAgeDays: 0))

        XCTAssertEqual(result.dispatchIDs, ["ctx_a", "ctx_b"])
        XCTAssertEqual(result.freedBytes, 200)
        XCTAssertEqual(result.remainingOverBytes, 0)
        XCTAssertTrue(result.entries.allSatisfy { $0.reason == .size })
    }

    func testSizeCapStopsAsSoonAsItFits() {
        let result = plan([
            record("ctx_a", daysAgo: 5, bytes: 100),
            record("ctx_b", daysAgo: 3, bytes: 100),
        ], ArchiveRetentionPolicy(maxTotalBytes: 150, maxAgeDays: 0))
        XCTAssertEqual(result.dispatchIDs, ["ctx_a"])
    }

    func testAgeAndSizeCombineWithAgeWinningTheReason() {
        let result = plan([
            record("ctx_old", daysAgo: 90, bytes: 100),
            record("ctx_mid", daysAgo: 10, bytes: 100),
            record("ctx_new", daysAgo: 1, bytes: 100),
        ], ArchiveRetentionPolicy(maxTotalBytes: 120, maxAgeDays: 30))

        XCTAssertEqual(result.ageEntries.map(\.dispatchID), ["ctx_old"])
        XCTAssertEqual(result.sizeEntries.map(\.dispatchID), ["ctx_mid"])
        XCTAssertEqual(result.freedBytes, 200)
        XCTAssertEqual(result.remainingOverBytes, 0)
    }

    // MARK: - Protection

    func testLiveRunArchivesAreNeverSelected() {
        let result = plan([
            record("ctx_live", run: "run_live", daysAgo: 500, bytes: 1_000),
            record("ctx_dead", daysAgo: 500, bytes: 100),
        ], .default, protected: ["run_live"])

        XCTAssertEqual(result.dispatchIDs, ["ctx_dead"])
        XCTAssertEqual(result.protectedCount, 1)
        XCTAssertEqual(result.protectedBytes, 1_000)
        XCTAssertEqual(result.protectedRunIDs, ["run_live"])
    }

    func testCapUnreachableBecauseOfALiveRunIsReportedNotForced() {
        let result = plan([
            record("ctx_live", run: "run_live", daysAgo: 1, bytes: 900),
            record("ctx_dead", daysAgo: 2, bytes: 100),
        ], ArchiveRetentionPolicy(maxTotalBytes: 500, maxAgeDays: 0), protected: ["run_live"])

        XCTAssertEqual(result.dispatchIDs, ["ctx_dead"])
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertEqual(result.remainingOverBytes, 400,
                       "the live run holds 900 against a 500 cap; the preview says so")
    }

    func testOrphanedArchivesArePrunableAndLabelled() {
        let orphan = WorkerArchiveRecord(
            dispatchID: "ctx_orphan", kind: .terminalTail,
            createdAt: OrchestrationStore.sqliteTimestamp(now.addingTimeInterval(-400 * 86_400)),
            byteSize: 50)
        let result = plan([orphan], .default, protected: ["run_live"])
        XCTAssertEqual(result.dispatchIDs, ["ctx_orphan"])
        XCTAssertEqual(result.entries[0].runID, VaultProjection.orphanRunID)
        XCTAssertEqual(result.entries[0].runObjective, VaultProjection.orphanRunObjective)
    }

    // MARK: - Timestamps

    func testUndateableArchiveIsNeverAgeSelectedAndSortsLast() {
        let undateable = WorkerArchiveRecord(
            dispatchID: "ctx_undated", kind: .terminalTail, createdAt: "whenever", byteSize: 100,
            runID: "run_settled")

        let byAge = plan([undateable], ArchiveRetentionPolicy(maxTotalBytes: 0, maxAgeDays: 1))
        XCTAssertTrue(byAge.isEmpty, "an archive we cannot date is never aged out")

        let bySize = plan(
            [undateable, record("ctx_dated", daysAgo: 1, bytes: 100)],
            ArchiveRetentionPolicy(maxTotalBytes: 100, maxAgeDays: 0))
        XCTAssertEqual(bySize.dispatchIDs, ["ctx_dated"], "the dated archive goes first")
    }

    func testTimestampParsesSQLiteAndISOForms() {
        XCTAssertNotNil(ArchiveRetention.timestamp("2026-08-25 12:00:00"))
        XCTAssertNotNil(ArchiveRetention.timestamp("2026-08-25T12:00:00Z"))
        XCTAssertNotNil(ArchiveRetention.timestamp("2026-08-25T12:00:00.500Z"))
        XCTAssertNil(ArchiveRetention.timestamp("yesterday"))
    }

    // MARK: - Preview text

    func testSummaryLeadsWithTheConsequence() {
        let result = plan([
            record("ctx_a", daysAgo: 500, bytes: 2 * 1024 * 1024),
        ], .default)
        XCTAssertEqual(result.summary, "Delete 1 archive, freeing 2.0 MB of 2.0 MB.")

        let nothing = plan([record("ctx_a", daysAgo: 1, bytes: 10)], .default)
        XCTAssertEqual(
            nothing.summary,
            "Nothing to prune: every archive is within the caps or belongs to a live run.")
    }

    func testDefaultPolicyIsNotSurprising() {
        XCTAssertEqual(ArchiveRetentionPolicy.default.maxAgeDays, 60)
        XCTAssertEqual(ArchiveRetentionPolicy.default.maxTotalBytes, 512 * 1024 * 1024)
        XCTAssertTrue(ArchiveRetentionPolicy.keepForever.isDisabled)
        XCTAssertFalse(ArchiveRetentionPolicy.default.isDisabled)
        // Negative input is clamped, never inverted into an aggressive cap.
        XCTAssertEqual(ArchiveRetentionPolicy(maxTotalBytes: -5, maxAgeDays: -5).maxTotalBytes, 0)
    }
}
