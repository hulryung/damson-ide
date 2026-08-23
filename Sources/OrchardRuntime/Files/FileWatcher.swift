import CoreServices
import Foundation

/// Snapshot-diff used by `FileWatcher`. Public so tests can assert created /
/// deleted / renamed pairing without waiting on FSEvents.
public enum FileWatchReconciler {
    /// `snapshot` maps worktree-relative path → inode. Paths present only in
    /// `current` are created; only in `previous` are deleted; the same inode at
    /// two paths in one burst is a rename.
    public static func diff(previous: [String: UInt64],
                            current: [String: UInt64]) -> [FileWatchChange] {
        let gone = Set(previous.keys).subtracting(current.keys)
        let appeared = Set(current.keys).subtracting(previous.keys)

        var goneByInode: [UInt64: [String]] = [:]
        for path in gone.sorted() {
            if let inode = previous[path] {
                goneByInode[inode, default: []].append(path)
            }
        }

        var usedGone = Set<String>()
        var usedAppeared = Set<String>()
        var changes: [FileWatchChange] = []

        for path in appeared.sorted() {
            guard let inode = current[path],
                  let candidates = goneByInode[inode],
                  let from = candidates.first(where: { !usedGone.contains($0) })
            else { continue }
            usedGone.insert(from)
            usedAppeared.insert(path)
            changes.append(FileWatchChange(kind: .renamed, relativePath: path,
                                           previousRelativePath: from))
        }
        for path in gone.sorted() where !usedGone.contains(path) {
            changes.append(FileWatchChange(kind: .deleted, relativePath: path))
        }
        for path in appeared.sorted() where !usedAppeared.contains(path) {
            changes.append(FileWatchChange(kind: .created, relativePath: path))
        }
        return changes
    }

    /// Worktree-confined snapshot of files and directories. `.git` is skipped
    /// and symlink descendants are not followed, matching `FileService.walk`.
    public static func snapshot(root: URL) throws -> [String: UInt64] {
        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootStd.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw FileServiceError.notADirectory
        }
        var result: [String: UInt64] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: rootStd,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey],
            options: [.skipsPackageDescendants]
        ) else { return result }

        let prefix = rootStd.path.hasSuffix("/") ? rootStd.path : rootStd.path + "/"
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if name == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            if rel.isEmpty { continue }
            if let inode = inode(at: url) {
                result[rel] = inode
            }
        }
        return result
    }

    static func inode(at url: URL) -> UInt64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

/// One FSEvents/kqueue watcher per explorer root.
///
/// Events are snapshot-diffed after a debounce so a burst of writes collapses
/// to created/deleted/renamed paths. Deleting the watch root yields a single
/// `rootDeleted` batch and stops the stream.
public final class FileWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<FileWatchBatch>.Continuation] = [:]
    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var previous: [String: UInt64] = [:]
    private var root: URL?
    private var running = false
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    /// Test seam: invoked after every snapshot reconcile, including no-op diffs
    /// and `rootDeleted`. Tests wait on this instead of sleeping for FSEvents.
    private var onReconciledHandler: (@Sendable (FileWatchBatch) -> Void)?

    public init(debounce: TimeInterval = 0.12) {
        self.debounce = debounce
        self.queue = DispatchQueue(label: "orchard.file-watcher")
    }

    deinit { stop() }

    /// Test seam. Set before mutating the watched tree; cleared by the test
    /// after the matching batch arrives.
    public var onReconciled: (@Sendable (FileWatchBatch) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return onReconciledHandler }
        set { lock.lock(); onReconciledHandler = newValue; lock.unlock() }
    }

    public func events() -> AsyncStream<FileWatchBatch> {
        // Register immediately so `let stream = events()` cannot miss a batch
        // that lands before the first `for await` (the live-test flake).
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: FileWatchBatch.self)
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    public func start(root: URL) throws {
        stop()
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
            throw FileServiceError.notFound(resolved.lastPathComponent)
        }
        guard isDir.boolValue else { throw FileServiceError.notADirectory }

        let snap = try FileWatchReconciler.snapshot(root: resolved)
        lock.lock()
        self.root = resolved
        self.previous = snap
        self.running = true
        lock.unlock()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let paths = [resolved.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            FileWatcher.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce / 2,
            flags)
        else {
            throw FileServiceError.invalidArgument("failed to start directory watcher")
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw FileServiceError.invalidArgument("failed to start directory watcher")
        }
        lock.lock()
        stream = created
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        running = false
        debounceWork?.cancel()
        debounceWork = nil
        let existing = stream
        stream = nil
        lock.unlock()
        if let existing {
            FSEventStreamStop(existing)
            FSEventStreamInvalidate(existing)
            FSEventStreamRelease(existing)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        _ = array as? [String] ?? (array as NSArray).compactMap { $0 as? String }
        var rootChanged = false
        for i in 0..<count {
            let flag = eventFlags[i]
            if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                rootChanged = true
            }
        }
        watcher.scheduleReconcile(forceRootCheck: rootChanged)
    }

    private func scheduleReconcile(forceRootCheck: Bool) {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconcile(forceRootCheck: forceRootCheck)
        }
        debounceWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func reconcile(forceRootCheck _: Bool) {
        lock.lock()
        guard running, let root else {
            lock.unlock()
            return
        }
        let previous = self.previous
        lock.unlock()

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            let batch = FileWatchBatch(rootDeleted: true)
            emit(batch)
            notifyReconciled(batch)
            // Don't FSEventStreamStop from inside the callback's debounce work
            // if we're already on the watcher queue — schedule a clean stop.
            lock.lock()
            running = false
            lock.unlock()
            queue.async { [weak self] in self?.stop() }
            return
        }

        let current: [String: UInt64]
        do {
            current = try FileWatchReconciler.snapshot(root: root)
        } catch {
            let batch = FileWatchBatch(rootDeleted: true)
            emit(batch)
            notifyReconciled(batch)
            lock.lock()
            running = false
            lock.unlock()
            queue.async { [weak self] in self?.stop() }
            return
        }

        let changes = FileWatchReconciler.diff(previous: previous, current: current)
        lock.lock()
        self.previous = current
        lock.unlock()
        let batch = FileWatchBatch(changes: changes)
        if !changes.isEmpty {
            emit(batch)
        }
        notifyReconciled(batch)
    }

    private func notifyReconciled(_ batch: FileWatchBatch) {
        lock.lock()
        let handler = onReconciledHandler
        lock.unlock()
        handler?(batch)
    }

    private func emit(_ batch: FileWatchBatch) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(batch)
        }
    }
}
