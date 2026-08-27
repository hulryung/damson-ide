import XCTest
@testable import OrchardRuntime

/// T90: Space view projection + local disk scanner. No git, no host transport.
final class WorkspaceSpaceProjectionTests: XCTestCase {

    private let projectA = UUID()
    private let projectB = UUID()
    private let extraID = UUID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func subject(
        id: String = "repo::/tmp/a",
        recordID: UUID? = nil,
        projectID: UUID? = nil,
        repoID: String = "repo",
        repoName: String = "damson-ide",
        displayName: String = "main",
        path: String = "/tmp/a",
        branch: String = "main",
        hostId: String = "local",
        isMain: Bool = true,
        isRemote: Bool = false,
        isArchived: Bool = false,
        lastActivity: Date? = nil,
        kind: String = "worktree"
    ) -> WorkspaceSpaceSubject {
        WorkspaceSpaceSubject(
            id: id,
            recordID: recordID,
            projectID: projectID ?? projectA,
            repoID: repoID,
            repoName: repoName,
            displayName: displayName,
            path: path,
            branch: branch,
            hostId: hostId,
            isMainWorktree: isMain,
            isRemote: isRemote,
            isArchived: isArchived,
            lastActivityAt: lastActivity ?? now,
            kind: kind)
    }

    private func measurement(status: WorkspaceSpaceScanStatus = .ok, size: Int = 1000,
                             error: String? = nil) -> WorkspaceSpaceMeasurement {
        WorkspaceSpaceMeasurement(status: status, error: error, sizeBytes: size)
    }

    // MARK: - Reclaimable / canDelete

    func testMainWorktreeSizeCountsButIsNotReclaimableOrDeletable() {
        let main = subject()
        let row = WorkspaceSpaceProjection.row(subject: main, measurement: measurement(size: 4096))
        XCTAssertEqual(row.sizeBytes, 4096)
        XCTAssertEqual(row.reclaimableBytes, 0)
        XCTAssertFalse(row.canDelete)
        XCTAssertEqual(row.status, .ok)
    }

    func testExtraLocalWorktreeIsFullyReclaimableAndDeletable() {
        let extra = subject(id: "repo::/tmp/wt", recordID: extraID, displayName: "t90",
                            path: "/tmp/wt", branch: "orchard/t90", isMain: false)
        let row = WorkspaceSpaceProjection.row(subject: extra, measurement: measurement(size: 8192))
        XCTAssertEqual(row.reclaimableBytes, 8192)
        XCTAssertTrue(row.canDelete)
    }

    func testFailedScanIsNotReclaimable() {
        let extra = subject(id: "repo::/tmp/wt", recordID: extraID, isMain: false)
        for status: WorkspaceSpaceScanStatus in [.missing, .permissionDenied, .error, .unavailable] {
            let row = WorkspaceSpaceProjection.row(
                subject: extra, measurement: measurement(status: status, size: 99))
            XCTAssertEqual(row.reclaimableBytes, 0, status.rawValue)
        }
    }

    func testRemoteIsUnavailableWithoutAMeasurementAndCannotDelete() {
        let remote = subject(id: "r::/remote", recordID: extraID, hostId: "ssh:box",
                             isMain: false, isRemote: true)
        let snapshot = WorkspaceSpaceProjection.snapshot(
            subjects: [remote],
            measurements: [remote.id: measurement(size: 999_999)],
            scannedAt: now)
        let row = snapshot.rows[0]
        XCTAssertEqual(row.status, .unavailable)
        XCTAssertEqual(row.error, WorkspaceSpaceProjection.remoteUnavailableMessage)
        XCTAssertEqual(row.sizeBytes, 0)
        XCTAssertEqual(row.reclaimableBytes, 0)
        XCTAssertFalse(row.canDelete)
    }

    func testUnscannedLocalRowIsATypedErrorNotABlank() {
        let extra = subject(id: "repo::/tmp/wt", recordID: extraID, isMain: false)
        let snapshot = WorkspaceSpaceProjection.snapshot(
            subjects: [extra], measurements: [:], scannedAt: now)
        XCTAssertEqual(snapshot.rows[0].status, .error)
        XCTAssertEqual(snapshot.rows[0].error, "Not scanned")
        XCTAssertEqual(snapshot.unavailableCount, 1)
        XCTAssertEqual(snapshot.scannedCount, 0)
    }

    // MARK: - Sort / filter / group

    func testSortBySizeDescendingThenName() {
        let rows = [
            WorkspaceSpaceProjection.row(
                subject: subject(id: "a", recordID: extraID, displayName: "beta", isMain: false),
                measurement: measurement(size: 100)),
            WorkspaceSpaceProjection.row(
                subject: subject(id: "b", recordID: extraID, displayName: "alpha", isMain: false),
                measurement: measurement(size: 100)),
            WorkspaceSpaceProjection.row(
                subject: subject(id: "c", displayName: "gamma", isMain: true),
                measurement: measurement(size: 500)),
        ]
        let sorted = WorkspaceSpaceProjection.sort(rows, key: .size, direction: .descending)
        XCTAssertEqual(sorted.map(\.displayName), ["gamma", "alpha", "beta"])
    }

    func testSortByActivityAscending() {
        let older = now.addingTimeInterval(-3600)
        let rows = [
            WorkspaceSpaceProjection.row(
                subject: subject(id: "new", displayName: "new", lastActivity: now),
                measurement: measurement(size: 1)),
            WorkspaceSpaceProjection.row(
                subject: subject(id: "old", displayName: "old", lastActivity: older),
                measurement: measurement(size: 1)),
        ]
        let sorted = WorkspaceSpaceProjection.sort(rows, key: .activity, direction: .ascending)
        XCTAssertEqual(sorted.map(\.displayName), ["old", "new"])
    }

    func testFilterByQueryAndOnlyDeletable() {
        let main = WorkspaceSpaceProjection.row(
            subject: subject(repoName: "damson-ide", displayName: "damson-ide"),
            measurement: measurement(size: 10))
        let extra = WorkspaceSpaceProjection.row(
            subject: subject(id: "other::/tmp/wt", recordID: extraID, repoID: "other",
                             repoName: "other", displayName: "t90-space",
                             path: "/tmp/wt", isMain: false),
            measurement: measurement(size: 20))
        let rows = [main, extra]
        XCTAssertEqual(WorkspaceSpaceProjection.filter(rows, query: "t90", onlyDeletable: false)
            .map(\.displayName), ["t90-space"])
        XCTAssertEqual(WorkspaceSpaceProjection.filter(rows, query: "", onlyDeletable: true)
            .map(\.displayName), ["t90-space"])
        XCTAssertEqual(WorkspaceSpaceProjection.filter(rows, query: "damson", onlyDeletable: true)
            .count, 0)
    }

    func testOversizedFilterQueryMatchesNothing() {
        let row = WorkspaceSpaceProjection.row(subject: subject(), measurement: measurement())
        let huge = String(repeating: "a", count: WorkspaceSpaceProjection.filterQueryMaxBytes + 1)
        XCTAssertTrue(WorkspaceSpaceProjection.filter([row], query: huge, onlyDeletable: false).isEmpty)
        XCTAssertTrue(WorkspaceSpaceProjection.isFilterQueryTooLarge(huge))
        XCTAssertFalse(WorkspaceSpaceProjection.isFilterQueryTooLarge("space"))
    }

    func testGroupsPreserveFirstSeenRepoOrderAndRollUpBytes() {
        let aMain = WorkspaceSpaceProjection.row(
            subject: subject(id: "a::/a", repoID: "a", repoName: "alpha", displayName: "alpha"),
            measurement: measurement(size: 100))
        let bExtra = WorkspaceSpaceProjection.row(
            subject: subject(id: "b::/b", recordID: extraID, repoID: "b", repoName: "beta",
                             displayName: "beta-wt", isMain: false),
            measurement: measurement(size: 50))
        let aExtra = WorkspaceSpaceProjection.row(
            subject: subject(id: "a::/a2", recordID: extraID, repoID: "a", repoName: "alpha",
                             displayName: "alpha-wt", isMain: false),
            measurement: measurement(size: 25))
        let groups = WorkspaceSpaceProjection.groups([aMain, bExtra, aExtra])
        XCTAssertEqual(groups.map(\.repoName), ["alpha", "beta"])
        XCTAssertEqual(groups[0].worktreeCount, 2)
        XCTAssertEqual(groups[0].totalSizeBytes, 125)
        XCTAssertEqual(groups[0].reclaimableBytes, 25)
        XCTAssertEqual(groups[1].reclaimableBytes, 50)
    }

    func testSnapshotTotalsIgnoreUnreclaimableMainAndFailedRows() {
        let main = subject(id: "a::/a")
        let extra = subject(id: "a::/wt", recordID: extraID, isMain: false)
        let missing = subject(id: "a::/gone", recordID: extraID, displayName: "gone",
                              isMain: false)
        let snapshot = WorkspaceSpaceProjection.snapshot(
            subjects: [main, extra, missing],
            measurements: [
                main.id: measurement(size: 1000),
                extra.id: measurement(size: 200),
                missing.id: measurement(status: .missing, size: 0),
            ],
            scannedAt: now)
        XCTAssertEqual(snapshot.totalSizeBytes, 1200)
        XCTAssertEqual(snapshot.reclaimableBytes, 200)
        XCTAssertEqual(snapshot.scannedCount, 2)
        XCTAssertEqual(snapshot.unavailableCount, 1)
        XCTAssertEqual(snapshot.worktreeCount, 3)
        XCTAssertEqual(snapshot.row(id: extra.id)?.reclaimableLabel, "200 B")
    }

    // MARK: - Formatting

    func testByteLabelMatchesVaultShape() {
        XCTAssertEqual(WorkspaceSpaceProjection.byteLabel(0), "0 B")
        XCTAssertEqual(WorkspaceSpaceProjection.byteLabel(512), "512 B")
        XCTAssertEqual(WorkspaceSpaceProjection.byteLabel(2048), "2 KB")
        XCTAssertEqual(WorkspaceSpaceProjection.byteLabel(5 * 1024 * 1024), "5.0 MB")
        XCTAssertEqual(WorkspaceSpaceProjection.byteLabel(3 * 1024 * 1024 * 1024), "3.0 GB")
    }

    func testBranchLabelStripsRefsAndFallsBack() {
        XCTAssertEqual(WorkspaceSpaceProjection.branchLabel(branch: "refs/heads/main", isMain: true),
                       "main")
        XCTAssertEqual(WorkspaceSpaceProjection.branchLabel(branch: "  ", isMain: true),
                       "main worktree")
        XCTAssertEqual(WorkspaceSpaceProjection.branchLabel(branch: "", isMain: false),
                       "detached")
        XCTAssertEqual(WorkspaceSpaceProjection.branchLabel(branch: "orchard/t90", isMain: false),
                       "orchard/t90")
    }

    func testStatusLabelsAreTypedAndVisible() {
        XCTAssertEqual(WorkspaceSpaceScanStatus.ok.label, "Scanned")
        XCTAssertEqual(WorkspaceSpaceScanStatus.missing.label, "Missing")
        XCTAssertEqual(WorkspaceSpaceScanStatus.permissionDenied.label, "No access")
        XCTAssertEqual(WorkspaceSpaceScanStatus.unavailable.label, "Unavailable")
        XCTAssertEqual(WorkspaceSpaceScanStatus.error.label, "Failed")
    }

    func testSizeFractionIsCappedAndZeroSafe() {
        XCTAssertEqual(WorkspaceSpaceProjection.sizeFraction(sizeBytes: 25, largestBytes: 100), 0.25)
        XCTAssertEqual(WorkspaceSpaceProjection.sizeFraction(sizeBytes: 200, largestBytes: 100), 1)
        XCTAssertEqual(WorkspaceSpaceProjection.sizeFraction(sizeBytes: 10, largestBytes: 0), 0)
        XCTAssertEqual(WorkspaceSpaceProjection.largestRowSize([]), 0)
    }

    func testCompactTopLevelItemsFoldsTheTailIntoOther() {
        let items = (0..<50).map { i in
            WorkspaceSpaceItem(name: String(format: "d%02d", i), path: "/t/\(i)",
                               kind: .directory, sizeBytes: 50 - i)
        }
        let compacted = WorkspaceSpaceProjection.compactTopLevelItems(items)
        XCTAssertEqual(compacted.items.count, WorkspaceSpaceProjection.maxTopLevelItems)
        XCTAssertEqual(compacted.items.last?.name, "Other")
        XCTAssertEqual(compacted.items.last?.kind, .other)
        XCTAssertEqual(compacted.omittedCount, 50 - (WorkspaceSpaceProjection.maxTopLevelItems - 1))
        XCTAssertEqual(compacted.items.last?.sizeBytes, compacted.omittedBytes)
        XCTAssertEqual(compacted.items.first?.name, "d00")
    }

    func testCompactUnderCapIsIdentitySortedBySize() {
        let items = [
            WorkspaceSpaceItem(name: "b", path: "/b", kind: .file, sizeBytes: 1),
            WorkspaceSpaceItem(name: "a", path: "/a", kind: .file, sizeBytes: 3),
        ]
        let compacted = WorkspaceSpaceProjection.compactTopLevelItems(items)
        XCTAssertEqual(compacted.items.map(\.name), ["a", "b"])
        XCTAssertEqual(compacted.omittedCount, 0)
    }
}

final class WorkspaceSpaceScannerTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-space-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    func testMissingPathIsTypedMissing() {
        let gone = scratch.appendingPathComponent("nope")
        let measured = WorkspaceSpaceScanner.measure(path: gone.path)
        XCTAssertEqual(measured.status, .missing)
        XCTAssertEqual(measured.sizeBytes, 0)
        XCTAssertNotNil(measured.error)
    }

    func testDirectorySizeIncludesNestedFilesAndHiddenGit() throws {
        let git = scratch.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let nested = scratch.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x61, count: 32 * 1024)
        try payload.write(to: nested.appendingPathComponent("big.swift"))
        try payload.write(to: git.appendingPathComponent("index"))

        let measured = WorkspaceSpaceScanner.measure(path: scratch.path)
        XCTAssertEqual(measured.status, .ok)
        XCTAssertGreaterThan(measured.sizeBytes, 60 * 1024,
                             "hidden .git and src both have to count")
        let names = Set(measured.topLevelItems.map(\.name))
        XCTAssertTrue(names.contains(".git"))
        XCTAssertTrue(names.contains("src"))
    }

    func testSymlinkToAFileOutsideTheTreeIsNotFollowed() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchard-space-target-\(UUID().uuidString)")
        let payload = Data(repeating: 0x62, count: 256 * 1024)
        try payload.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = scratch.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let measured = WorkspaceSpaceScanner.measure(path: scratch.path)
        XCTAssertEqual(measured.status, .ok)
        XCTAssertLessThan(measured.sizeBytes, 64 * 1024,
                          "following the symlink would count the 256 KB target")
        XCTAssertEqual(measured.topLevelItems.first?.kind, .symlink)
    }

    func testTopLevelItemSizesSumToAtMostTheRoot() throws {
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("one"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("two"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(
            to: scratch.appendingPathComponent("one").appendingPathComponent("a.txt"))
        try Data("world!!".utf8).write(
            to: scratch.appendingPathComponent("two").appendingPathComponent("b.txt"))
        let measured = WorkspaceSpaceScanner.measure(path: scratch.path)
        XCTAssertEqual(measured.status, .ok)
        let childSum = measured.topLevelItems.reduce(0) { $0 + $1.sizeBytes }
        XCTAssertLessThanOrEqual(childSum, measured.sizeBytes)
        XCTAssertGreaterThan(measured.sizeBytes, 0)
    }
}
