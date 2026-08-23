import XCTest
@testable import OrchardRuntime

/// Snapshot-diff reconciliation (with a real temp dir) plus a live FSEvents
/// watcher covering create/delete/rename and watch-root deletion.
final class FileWatcherTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-watch-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, to name: String, in root: URL? = nil) throws {
        let url = (root ?? tmp!).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReconcilerPairsRenameAndReportsCreateDelete() throws {
        try write("a", to: "keep.txt")
        try write("b", to: "gone.txt")
        try write("c", to: "src/old.swift")
        let previous = try FileWatchReconciler.snapshot(root: tmp)

        try FileManager.default.removeItem(at: tmp.appendingPathComponent("gone.txt"))
        try write("d", to: "fresh.txt")
        try FileManager.default.moveItem(
            at: tmp.appendingPathComponent("src/old.swift"),
            to: tmp.appendingPathComponent("src/new.swift"))

        let current = try FileWatchReconciler.snapshot(root: tmp)
        let changes = FileWatchReconciler.diff(previous: previous, current: current)

        XCTAssertTrue(changes.contains { $0.kind == .deleted && $0.relativePath == "gone.txt" })
        XCTAssertTrue(changes.contains { $0.kind == .created && $0.relativePath == "fresh.txt" })
        let renamed = changes.first { $0.kind == .renamed && $0.relativePath == "src/new.swift" }
        XCTAssertEqual(renamed?.previousRelativePath, "src/old.swift")
        XCTAssertFalse(changes.contains { $0.relativePath.contains("..") })
        XCTAssertTrue(previous.keys.allSatisfy { !$0.hasPrefix("/") && !$0.contains("..") })
    }

    func testReconcilerSnapshotSkipsGitAndSymlinkEscape() throws {
        try write("x", to: "ok.txt")
        try write("x", to: ".git/objects/pack")
        let outside = tmp.deletingLastPathComponent()
            .appendingPathComponent("orchard-watch-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "leaked".write(to: outside.appendingPathComponent("leak.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent("escape"), withDestinationURL: outside)

        let snap = try FileWatchReconciler.snapshot(root: tmp)
        XCTAssertTrue(snap.keys.contains("ok.txt"))
        XCTAssertTrue(snap.keys.contains("escape"))
        XCTAssertFalse(snap.keys.contains { $0.hasPrefix(".git") })
        XCTAssertFalse(snap.keys.contains { $0.hasPrefix("escape/") })
    }

    func testLiveWatcherEmitsCreateDeleteRename() async throws {
        let watcher = FileWatcher(debounce: 0.05)
        let stream = watcher.events()
        try watcher.start(root: tmp)
        defer { watcher.stop() }

        let collector = Task<[FileWatchChange], Never> {
            var collected: [FileWatchChange] = []
            for await batch in stream {
                if batch.rootDeleted { break }
                collected.append(contentsOf: batch.changes)
                let kinds = Set(collected.map(\.kind))
                if kinds.contains(.created) && kinds.contains(.deleted) && kinds.contains(.renamed) {
                    break
                }
                if collected.count > 20 { break }
            }
            return collected
        }

        // Give FSEvents a moment to attach before mutating.
        try await Task.sleep(nanoseconds: 80_000_000)
        try write("one", to: "alpha.txt")
        try await Task.sleep(nanoseconds: 120_000_000)
        try FileManager.default.moveItem(
            at: tmp.appendingPathComponent("alpha.txt"),
            to: tmp.appendingPathComponent("beta.txt"))
        try await Task.sleep(nanoseconds: 120_000_000)
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("beta.txt"))

        let collected = await withTimeout(seconds: 3, collector) ?? []
        XCTAssertTrue(collected.contains { $0.kind == .created && $0.relativePath.hasSuffix("alpha.txt") },
                      "expected created alpha, got \(collected)")
        XCTAssertTrue(
            collected.contains { $0.kind == .renamed && $0.relativePath.hasSuffix("beta.txt") }
            || collected.contains { $0.kind == .deleted && $0.relativePath.hasSuffix("alpha.txt") },
            "expected rename or delete of alpha, got \(collected)")
        XCTAssertTrue(
            collected.contains { $0.kind == .deleted && ($0.relativePath.hasSuffix("beta.txt")
                                                         || $0.relativePath.hasSuffix("alpha.txt")) },
            "expected delete, got \(collected)")
    }

    func testLiveWatcherReportsRootDeletion() async throws {
        let root = tmp.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("x", to: "file.txt", in: root)

        let watcher = FileWatcher(debounce: 0.05)
        let stream = watcher.events()
        try watcher.start(root: root)
        defer { watcher.stop() }

        let waiter = Task<Bool, Never> {
            for await batch in stream {
                if batch.rootDeleted { return true }
            }
            return false
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        try FileManager.default.removeItem(at: root)
        let deleted = await withTimeout(seconds: 3, waiter) ?? false
        XCTAssertTrue(deleted)
    }

    private func withTimeout<T>(seconds: TimeInterval, _ task: Task<T, Never>) async -> T? {
        let nanos = UInt64(seconds * 1_000_000_000)
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            task.cancel()
            return first ?? nil
        }
    }
}
