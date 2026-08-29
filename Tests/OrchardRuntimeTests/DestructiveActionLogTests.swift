import XCTest
@testable import OrchardRuntime

/// The log exists because of one incident: three repositories lost their
/// registration and every worktree record that belonged to them, and afterwards
/// there was no way to tell what had asked for it. These tests pin the parts
/// that would have answered that question.
@MainActor
final class DestructiveActionLogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func log(limit: Int = 2000) -> DestructiveActionLog {
        DestructiveActionLog(url: dir.appendingPathComponent("orchard-audit.jsonl"),
                             limit: limit)
    }

    // MARK: - The log itself

    func testRecordsOriginAndSurvivesReading() {
        let subject = log()
        subject.record("repo_removed", origin: .gui, targetID: "id-1",
                       targetName: "ccse", targetPath: "/dev/ccse",
                       discarded: ["worktree records": 1])
        let entries = subject.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].origin, .gui)
        XCTAssertEqual(entries[0].targetName, "ccse")
        XCTAssertEqual(entries[0].discarded["worktree records"], 1)
    }

    func testAppendsRatherThanOverwrites() {
        let subject = log()
        subject.record("repo_removed", origin: .gui, targetName: "a")
        subject.record("repo_removed", origin: .cli, targetName: "b")
        subject.record("repo_removed", origin: .runtime, targetName: "c")
        XCTAssertEqual(subject.entries().map(\.targetName), ["a", "b", "c"])
        XCTAssertEqual(subject.entries().map(\.origin), [.gui, .cli, .runtime])
    }

    /// A fresh `DestructiveActionLog` over the same file must see the history —
    /// the log outlives the process that wrote it or it is useless for exactly
    /// the question it exists to answer.
    func testHistoryOutlivesTheInstance() {
        log().record("repo_removed", origin: .cli, targetName: "ccse")
        XCTAssertEqual(log().entries().first?.targetName, "ccse")
    }

    /// It lives beside `orchard-data.json`, never inside it: the point is to
    /// survive the write that rewrote the data.
    func testLivesBesideTheDataFileNotInsideIt() {
        let data = dir.appendingPathComponent("orchard-data.json")
        let subject = DestructiveActionLog.beside(data)
        XCTAssertEqual(subject.url.lastPathComponent, "orchard-audit.jsonl")
        XCTAssertEqual(subject.url.deletingLastPathComponent(), data.deletingLastPathComponent())
    }

    func testACorruptLineDoesNotHideTheRest() throws {
        let subject = log()
        subject.record("repo_removed", origin: .gui, targetName: "first")
        let url = subject.url
        try ("{ this is not json\n").appendToFile(url)
        subject.record("repo_removed", origin: .gui, targetName: "third")
        XCTAssertEqual(subject.entries().map(\.targetName), ["first", "third"])
    }

    func testOldestEntriesAreDroppedAtTheLimit() {
        let subject = log(limit: 3)
        for name in ["a", "b", "c", "d", "e"] {
            subject.record("repo_removed", origin: .gui, targetName: name)
        }
        XCTAssertEqual(subject.entries().map(\.targetName), ["c", "d", "e"])
    }

    func testSentenceNamesWhatAndWhere() {
        let entry = DestructiveAction(action: "repo_removed", origin: .gui, at: Date(),
                                      targetName: "ccse",
                                      discarded: ["worktree records": 4, "lineage entries": 0])
        XCTAssertTrue(entry.sentence.contains("ccse"))
        XCTAssertTrue(entry.sentence.contains("4 worktree records"))
        XCTAssertFalse(entry.sentence.contains("0 lineage"), "empty counts are noise")
        XCTAssertTrue(entry.sentence.contains("the Orchard window"))
    }

    // MARK: - Wired into the removal it audits

    private func service() throws -> WorkspaceService {
        let store = OrchardDataStore(url: dir.appendingPathComponent("orchard-data.json"))
        let service = WorkspaceService(store: store)
        service.worktreesRoot = dir.appendingPathComponent("worktrees")
        service.auditLog = log()
        return service
    }

    private func makeRepo(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/git"),
                             arguments: ["-C", url.path, "init", "-q"]).waitUntilExit()
        return url
    }

    func testRemovingARepoLeavesALineNamingTheOrigin() throws {
        let service = try service()
        let repo = try makeRepo("proj")
        let record = try service.addRepo(path: repo)
        try service.removeRepo(record.id, origin: .gui)

        let entries = service.auditLog.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].action, "repo_removed")
        XCTAssertEqual(entries[0].origin, .gui, "this is the field the log exists for")
        XCTAssertEqual(entries[0].targetID, record.id)
        XCTAssertEqual(entries[0].targetName, record.displayName)
    }

    /// The same removal through the two doors must be distinguishable afterwards.
    /// Without this the log records that something happened and still cannot say
    /// what asked for it, which is the whole failure it was written to prevent.
    func testTheGuiAndTheCliAreTellableApartAfterTheFact() throws {
        let service = try service()
        let first = try service.addRepo(path: try makeRepo("one"))
        let second = try service.addRepo(path: try makeRepo("two"))
        try service.removeRepo(first.id, origin: .gui)
        try service.removeRepo(second.id, origin: .cli)

        let origins = service.auditLog.entries().map(\.origin)
        XCTAssertEqual(origins, [.gui, .cli])
    }

    func testARemovalThatRefusesWritesNoLine() throws {
        let service = try service()
        let service2 = service
        XCTAssertThrowsError(try service2.removeRepo("id:nope-not-a-repo", origin: .gui))
        XCTAssertTrue(service.auditLog.entries().isEmpty,
                      "nothing was discarded, so nothing is claimed")
    }
}

private extension String {
    func appendToFile(_ url: URL) throws {
        guard let bytes = data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } else {
            try bytes.write(to: url)
        }
    }
}
