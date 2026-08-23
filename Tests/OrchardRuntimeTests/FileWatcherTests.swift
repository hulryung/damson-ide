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

    func testReconcilerReportsInPlaceModification() throws {
        try write("old", to: "keep.txt")
        let previous = try FileWatchReconciler.identities(root: tmp)
        // Force a distinct mtime so the identity comparison is deterministic
        // even when the two writes land in the same second.
        var attrs = try FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent("keep.txt").path)
        attrs[.modificationDate] = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: tmp.appendingPathComponent("keep.txt").path)
        let stamped = try FileWatchReconciler.identities(root: tmp)

        try write("new", to: "keep.txt")
        attrs = try FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent("keep.txt").path)
        attrs[.modificationDate] = Date(timeIntervalSince1970: 2)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: tmp.appendingPathComponent("keep.txt").path)
        let current = try FileWatchReconciler.identities(root: tmp)

        let mods = FileWatchReconciler.modifications(previous: stamped, current: current, excluding: [])
        XCTAssertEqual(mods, [FileWatchChange(kind: .modified, relativePath: "keep.txt")])
        XCTAssertEqual(previous["keep.txt"]?.inode, stamped["keep.txt"]?.inode)
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

        // Handshake: a probe write must be reconciled before we trust FSEvents.
        _ = try await mutateAndWait(watcher, timeout: 8, matching: { batch in
            batch.changes.contains { $0.kind == .created && $0.relativePath.hasSuffix(".probe") }
        }) {
            try write("probe", to: ".probe")
        }

        let created = try await mutateAndWait(watcher, timeout: 8, matching: { batch in
            batch.changes.contains { $0.kind == .created && $0.relativePath.hasSuffix("alpha.txt") }
        }) {
            try write("one", to: "alpha.txt")
        }
        XCTAssertTrue(created.changes.contains { $0.kind == .created && $0.relativePath.hasSuffix("alpha.txt") })

        let renamed = try await mutateAndWait(watcher, timeout: 8, matching: { batch in
            batch.changes.contains { $0.kind == .renamed && $0.relativePath.hasSuffix("beta.txt") }
            || batch.changes.contains { $0.kind == .deleted && $0.relativePath.hasSuffix("alpha.txt") }
        }) {
            try FileManager.default.moveItem(
                at: tmp.appendingPathComponent("alpha.txt"),
                to: tmp.appendingPathComponent("beta.txt"))
        }
        XCTAssertTrue(
            renamed.changes.contains { $0.kind == .renamed && $0.relativePath.hasSuffix("beta.txt") }
            || renamed.changes.contains { $0.kind == .deleted && $0.relativePath.hasSuffix("alpha.txt") },
            "expected rename or delete of alpha, got \(renamed.changes)")

        let deleted = try await mutateAndWait(watcher, timeout: 8, matching: { batch in
            batch.changes.contains { $0.kind == .deleted && ($0.relativePath.hasSuffix("beta.txt")
                                                             || $0.relativePath.hasSuffix("alpha.txt")) }
        }) {
            try FileManager.default.removeItem(at: tmp.appendingPathComponent("beta.txt"))
        }
        XCTAssertTrue(
            deleted.changes.contains { $0.kind == .deleted && ($0.relativePath.hasSuffix("beta.txt")
                                                              || $0.relativePath.hasSuffix("alpha.txt")) },
            "expected delete, got \(deleted.changes)")

        // The public stream is registered at `events()` (unbounded buffer), so it
        // must have seen the same create/rename/delete sequence.
        var collected: [FileWatchChange] = []
        let drain = Task {
            for await batch in stream {
                collected.append(contentsOf: batch.changes)
                let kinds = Set(collected.map(\.kind))
                if kinds.contains(.created) && kinds.contains(.deleted) { break }
                if collected.count > 20 { break }
            }
        }
        _ = await withTimeout(seconds: 2, drain)
        XCTAssertTrue(collected.contains { $0.kind == .created && $0.relativePath.hasSuffix("alpha.txt") },
                      "stream missed created alpha, got \(collected)")
        XCTAssertTrue(
            collected.contains { $0.kind == .deleted && ($0.relativePath.hasSuffix("beta.txt")
                                                         || $0.relativePath.hasSuffix("alpha.txt")) },
            "stream missed delete, got \(collected)")
    }

    func testLiveWatcherReportsRootDeletion() async throws {
        let root = tmp.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("x", to: "file.txt", in: root)

        let watcher = FileWatcher(debounce: 0.05)
        let stream = watcher.events()
        try watcher.start(root: root)
        defer { watcher.stop() }

        // Attach handshake against a file inside the watched root.
        _ = try await mutateAndWait(watcher, timeout: 8, matching: { batch in
            batch.changes.contains { $0.kind == .created && $0.relativePath.hasSuffix("probe.txt") }
        }) {
            try write("p", to: "probe.txt", in: root)
        }

        let waiter = Task<Bool, Never> {
            for await batch in stream {
                if batch.rootDeleted { return true }
            }
            return false
        }
        _ = try await mutateAndWait(watcher, timeout: 8, matching: { $0.rootDeleted }) {
            try FileManager.default.removeItem(at: root)
        }
        let deleted = await withTimeout(seconds: 2, waiter) ?? false
        XCTAssertTrue(deleted)
    }

    /// Arm `onReconciled` first, then mutate, then wait. FSEvents/debounce
    /// latency is bounded by `timeout` instead of a guessed sleep.
    @discardableResult
    private func mutateAndWait(
        _ watcher: FileWatcher,
        timeout: TimeInterval,
        matching: @escaping @Sendable (FileWatchBatch) -> Bool,
        mutate: () throws -> Void
    ) async throws -> FileWatchBatch {
        let box = OnceBox<FileWatchBatch>()
        watcher.onReconciled = { batch in
            if matching(batch) { box.resume(batch) }
        }
        try mutate()
        let batch = await withTimeout(seconds: timeout, Task { await box.wait() })
        watcher.onReconciled = nil
        guard let batch else {
            XCTFail("timed out waiting for file-watch reconcile (\(timeout)s)")
            throw CancellationError()
        }
        return batch
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

/// One-shot handoff from the watcher queue onto the test task.
private final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var continuation: CheckedContinuation<T, Never>?

    func resume(_ value: T) {
        lock.lock()
        if self.value != nil {
            lock.unlock()
            return
        }
        self.value = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func wait() async -> T {
        await withCheckedContinuation { cont in
            lock.lock()
            if let value {
                lock.unlock()
                cont.resume(returning: value)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}
