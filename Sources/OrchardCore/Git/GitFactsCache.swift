import CoreServices
import Foundation

/// Everything a workspace switch needs to know about a worktree's git state, from one
/// reading: what changed, and what is unmerged.
///
/// The two used to be fetched by two unrelated callers running five `git` processes
/// between them, at the moment the user was waiting for a pane to appear. They are one
/// value because they come from one reading.
public struct GitWorktreeFacts: Equatable, Sendable {
    public let status: GitWorktreeStatus
    public let conflicts: GitConflictSummary

    public static let unknown = GitWorktreeFacts(status: .unknown, conflicts: .none)

    public init(status: GitWorktreeStatus, conflicts: GitConflictSummary) {
        self.status = status
        self.conflicts = conflicts
    }
}

/// Per-worktree git facts, cached until something changes them.
///
/// The rule this type exists to keep is *honest invalidation*: a cached reading is served
/// only while a watcher is alive over everything that could make it untrue — the working
/// tree, the worktree's own git dir, and the repo-wide git dir that holds the refs. If a
/// watcher cannot be started, nothing is cached at all, because a value nobody is watching
/// is a value that can quietly become a lie. Invalidation drops the entry rather than
/// marking it "probably still fine": the cache never answers with a reading it knows is
/// out of date, and the UI keeps showing the last fact it was given until a fresh one
/// lands — visibly late, which is the honest way to be behind.
///
/// It also coalesces: several callers asking for the same worktree at the same moment
/// (the sidebar row, the workbench's conflict check, the source-control panel) share one
/// reading instead of each spawning their own git.
public final class GitFactsCache: @unchecked Sendable {
    public static let shared = GitFactsCache()

    /// Counters for tests and for the switch trace. `computes` is the number that matters:
    /// it is how many times a reading actually ran git.
    public struct Stats: Equatable, Sendable {
        public var hits = 0
        public var misses = 0
        public var computes = 0
        public var coalesced = 0
        public var invalidations = 0
    }

    private struct Entry {
        let facts: GitWorktreeFacts
        let baseRef: String
        let generation: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var generations: [String: UInt64] = [:]
    private var watchers: [String: GitTreeWatcher] = [:]
    private var inFlight: [String: Task<GitWorktreeFacts, Never>] = [:]
    /// The urgency a key's in-flight reading is queued at, and its scheduler ticket once
    /// it has one. A reading started for the sidebar's background fan-out and then asked
    /// for by a selection has to change queues, or the workspace the user just picked
    /// waits behind the fan-out it happened to be part of.
    private var inFlightUrgency: [String: Urgency] = [:]
    private var inFlightTicket: [String: ReadScheduler.Ticket] = [:]
    private var observers: [UUID: @Sendable (URL) -> Void] = [:]
    private var stats = Stats()
    private let service: GitService

    /// Counts the readings one call waited on, so a trace can attribute git to the phase
    /// that caused it.
    ///
    /// A process-wide counter cannot: at launch every worktree in every repo asks at once,
    /// and those readings land inside whatever phase window happens to be open — which is
    /// how a `refreshConflicts` running a single reading reported four. This is bound as a
    /// task local around a phase, and only that phase's own calls reach it.
    public final class ReadTally: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        public init() {}
        public var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func bump() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    @TaskLocal public static var tally: ReadTally?

    /// Whether a reading is the one the user is waiting for.
    ///
    /// The queue is bounded, and at launch every worktree in every repo asks for a reading
    /// at once. Without an ordering, the workspace the user just selected waits behind all
    /// of them — which is exactly the shape of a 172 ms `refreshCheckout` in a trace whose
    /// reading takes 25 ms.
    public enum Urgency: Sendable {
        case foreground
        case background
    }

    /// Bounded, ordered, and deliberately *not* the cooperative thread pool.
    private let scheduler: ReadScheduler

    public init(service: GitService = GitService(), concurrency: Int = 4) {
        self.service = service
        self.scheduler = ReadScheduler(limit: max(1, concurrency))
    }

    // MARK: - Reading

    /// The cached reading, or nil when there is none — because it was never taken, because
    /// something invalidated it, or because it was taken against a different base ref.
    ///
    /// Synchronous and spawn-free by construction: this is what a workspace switch calls,
    /// and it is the reason switching back to a workspace costs no git at all.
    public func cached(worktree: URL, baseRef: String) -> GitWorktreeFacts? {
        let key = Self.key(worktree)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.baseRef == baseRef else {
            stats.misses += 1
            return nil
        }
        stats.hits += 1
        return entry.facts
    }

    /// The current reading: the cached one when it is still true, otherwise a fresh one.
    ///
    /// Concurrent callers for the same worktree share a single reading. A reading whose
    /// worktree was invalidated while it ran is returned to its caller — it is the newest
    /// thing anyone has — but not stored, so the next caller reads again instead of
    /// inheriting a value that was already out of date when it landed.
    public func facts(worktree: URL, baseRef: String,
                      urgency: Urgency = .background) async -> GitWorktreeFacts {
        if let hit = cached(worktree: worktree, baseRef: baseRef) { return hit }
        // Counted on a miss, whether this call starts the reading or joins one already
        // running: either way it is waiting on git, which is what the phase's duration is
        // made of and what "zero git on the critical path" is a claim about.
        Self.tally?.bump()
        return await reading(worktree: worktree, baseRef: baseRef, urgency: urgency).value
    }

    /// The in-flight reading for this worktree, starting one if there is none. Synchronous
    /// so the lock is never held across a suspension — and so two callers arriving in the
    /// same turn of the run loop cannot both start a git.
    private func reading(worktree: URL, baseRef: String,
                         urgency: Urgency) -> Task<GitWorktreeFacts, Never> {
        let key = Self.key(worktree)
        lock.lock()
        defer { lock.unlock() }
        if let running = inFlight[key] {
            stats.coalesced += 1
            if urgency == .foreground, inFlightUrgency[key] != .foreground {
                inFlightUrgency[key] = .foreground
                if let ticket = inFlightTicket[key] { scheduler.promote(ticket) }
            }
            return running
        }
        inFlightUrgency[key] = urgency
        let generation = generations[key] ?? 0
        stats.computes += 1
        let task = Task<GitWorktreeFacts, Never> { [weak self] in
            guard let self else { return .unknown }
            let fresh = await self.read(key: key, worktree: worktree, baseRef: baseRef)
            self.store(fresh, key: key, worktree: worktree, baseRef: baseRef,
                       startedAt: generation)
            return fresh
        }
        inFlight[key] = task
        return task
    }

    private func read(key: String, worktree: URL, baseRef: String) async -> GitWorktreeFacts {
        let service = self.service
        return await withCheckedContinuation { continuation in
            // Read under the lock: a selection may have promoted this key between the task
            // being created and the work being queued.
            lock.lock()
            let urgency = inFlightUrgency[key] ?? .background
            lock.unlock()
            let ticket = scheduler.submit(urgency) {
                continuation.resume(returning: service.facts(worktree: worktree, baseRef: baseRef))
            }
            lock.lock()
            let promoted = inFlightUrgency[key] == .foreground && urgency == .background
            inFlightTicket[key] = ticket
            lock.unlock()
            if promoted { scheduler.promote(ticket) }
        }
    }

    private func store(_ facts: GitWorktreeFacts, key: String, worktree: URL,
                       baseRef: String, startedAt generation: UInt64) {
        // Started *before* the entry is published: a reading that is cached without a live
        // watcher over it is exactly the stale-branch hazard this type exists to refuse.
        let watched = ensureWatcher(key: key, worktree: worktree)
        lock.lock()
        inFlight[key] = nil
        inFlightUrgency[key] = nil
        inFlightTicket[key] = nil
        let current = generations[key] ?? 0
        if watched, current == generation {
            entries[key] = Entry(facts: facts, baseRef: baseRef, generation: current)
        }
        lock.unlock()
    }

    // MARK: - Invalidation

    /// Forget this worktree's reading. Called by the watcher for anything that touches the
    /// tree or the git dir, and directly by the operations Orchard itself runs — a commit
    /// or a resolve should not wait out a file-system notification to be believed.
    public func invalidate(worktree: URL) {
        invalidate(key: Self.key(worktree), worktree: worktree)
    }

    private func invalidate(key: String, worktree: URL) {
        lock.lock()
        generations[key] = (generations[key] ?? 0) + 1
        entries[key] = nil
        stats.invalidations += 1
        let targets = Array(observers.values)
        lock.unlock()
        // Observers are told every time, not only when an entry was dropped. A reading
        // that was invalidated *while it ran* leaves no entry behind, and if that silence
        // were the last word the workspace on screen would simply stop updating for as
        // long as an agent kept writing to it. Observers are expected to debounce.
        for observer in targets { observer(worktree) }
    }

    /// Forget everything. For a repo-wide event (a `gc`, a registry reload) and for tests.
    public func invalidateAll() {
        lock.lock()
        for key in entries.keys { generations[key] = (generations[key] ?? 0) + 1 }
        entries.removeAll()
        lock.unlock()
    }

    /// Drop a worktree entirely — its reading and its watcher. For a worktree that has
    /// been deleted; keeping a stream open on a directory that is gone leaks a watch.
    public func forget(worktree: URL) {
        let key = Self.key(worktree)
        lock.lock()
        generations[key] = (generations[key] ?? 0) + 1
        entries[key] = nil
        let watcher = watchers.removeValue(forKey: key)
        lock.unlock()
        watcher?.stop()
    }

    /// Called with the worktree whose reading just became untrue. The workbench uses it to
    /// re-read the workspace the user is actually looking at; everything else is re-read
    /// the next time it is asked for.
    @discardableResult
    public func observe(_ body: @escaping @Sendable (URL) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = body
        lock.unlock()
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    // MARK: - Watching

    /// True when this worktree has a live watcher — which is the precondition for caching
    /// anything about it at all.
    private func ensureWatcher(key: String, worktree: URL) -> Bool {
        lock.lock()
        if watchers[key] != nil {
            lock.unlock()
            return true
        }
        lock.unlock()
        let watcher = GitTreeWatcher(worktree: worktree) { [weak self] in
            self?.invalidate(key: key, worktree: worktree)
        }
        guard let watcher else { return false }
        lock.lock()
        if watchers[key] != nil {
            lock.unlock()
            watcher.stop()
            return true
        }
        watchers[key] = watcher
        lock.unlock()
        return true
    }

    public var isWatching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !watchers.isEmpty
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    public func resetStats() {
        lock.lock()
        stats = Stats()
        lock.unlock()
    }

    /// Tear everything down. Tests use it so one case's watchers cannot answer for the next.
    public func reset() {
        lock.lock()
        let live = Array(watchers.values)
        watchers.removeAll()
        entries.removeAll()
        generations.removeAll()
        stats = Stats()
        lock.unlock()
        for watcher in live { watcher.stop() }
    }

    /// The identity a worktree is cached under: its real path. git prints realpaths and
    /// Orchard holds the symlinked spelling (`/tmp` vs `/private/tmp`), so two callers
    /// naming the same directory differently must land on the same entry.
    public static func key(_ worktree: URL) -> String {
        worktree.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Runs readings a few at a time, newest selection first.
///
/// Every reading blocks its thread inside `poll` while git runs, so this cannot be the
/// cooperative thread pool: that pool is as wide as the machine has cores, and a fan-out
/// over every worktree in every repo fills it with blocked threads — which is what turned
/// a two-spawn conflict check into 445 ms while a sidebar refresh was in flight.
///
/// Two queues rather than a priority number, because the ordering has to be exact: at
/// launch, twenty background readings are already waiting when the user selects a
/// workspace, and that selection has to be the *next* thing that runs, not the twenty-first.
/// Work already in flight is never preempted — a git process is not interruptible — so the
/// wait is bounded by one reading, not by the backlog.
final class ReadScheduler: @unchecked Sendable {
    /// One queued reading. Identity matters: a reading queued in the background can be
    /// promoted once someone starts waiting for it, and promoting the wrong one would
    /// reorder somebody else's work.
    final class Ticket: @unchecked Sendable {
        let work: @Sendable () -> Void
        var started = false
        init(work: @escaping @Sendable () -> Void) { self.work = work }
    }

    private let lock = NSLock()
    private var foreground: [Ticket] = []
    private var background: [Ticket] = []
    private var running = 0
    private let limit: Int
    private let queue = DispatchQueue(label: "orchard.git-facts", attributes: .concurrent)

    init(limit: Int) {
        self.limit = limit
    }

    @discardableResult
    func submit(_ urgency: GitFactsCache.Urgency,
                _ work: @escaping @Sendable () -> Void) -> Ticket {
        let ticket = Ticket(work: work)
        lock.lock()
        if urgency == .foreground {
            foreground.append(ticket)
        } else {
            background.append(ticket)
        }
        lock.unlock()
        pump()
        return ticket
    }

    /// Move a queued reading to the front queue. A no-op once it has started — a git
    /// process is not interruptible, and pretending otherwise would just double-run it.
    func promote(_ ticket: Ticket) {
        lock.lock()
        guard !ticket.started, let index = background.firstIndex(where: { $0 === ticket }) else {
            lock.unlock()
            return
        }
        background.remove(at: index)
        foreground.append(ticket)
        lock.unlock()
        pump()
    }

    private func pump() {
        while true {
            lock.lock()
            guard running < limit else {
                lock.unlock()
                return
            }
            let next: Ticket?
            if !foreground.isEmpty {
                next = foreground.removeFirst()
            } else if !background.isEmpty {
                next = background.removeFirst()
            } else {
                next = nil
            }
            if let next {
                next.started = true
                running += 1
            }
            lock.unlock()
            guard let next else { return }
            queue.async { [weak self] in
                next.work()
                self?.finish()
            }
        }
    }

    private func finish() {
        lock.lock()
        running -= 1
        lock.unlock()
        pump()
    }
}

/// Watches everything that can change a worktree's git facts: the working tree, the
/// worktree's own git dir, and the repo-wide git dir holding the refs.
///
/// Deliberately not `FileWatcher`: that one exists to say *which* files changed and walks
/// the tree to find out, which on a 500 MB checkout is more work than the reading it would
/// be protecting. This one only ever answers "something did", which is all an invalidation
/// needs, so it does no walking at all.
///
/// `objects/` is ignored. A commit writes hundreds of files there and none of them change
/// any fact reported here — they are content-addressed blobs, and it is `refs/` moving
/// that makes a commit visible. Without that filter a single commit would invalidate the
/// cache dozens of times over.
final class GitTreeWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "orchard.git-facts-watch")
    private let onChange: () -> Void
    private let ignoredPrefixes: [String]
    private let lock = NSLock()

    init?(worktree: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let root = worktree.standardizedFileURL.resolvingSymlinksInPath()
        var paths: [String] = [root.path]
        var ignored: [String] = []
        if let gitDir = GitConflictService.gitDirectoryWithoutGit(worktree: root) {
            let resolved = gitDir.standardizedFileURL.resolvingSymlinksInPath()
            paths.append(resolved.path)
            ignored.append(resolved.appendingPathComponent("objects").path + "/")
            let common = GitConflictService.commonDirectory(gitDirectory: resolved)
                .standardizedFileURL.resolvingSymlinksInPath()
            paths.append(common.path)
            ignored.append(common.appendingPathComponent("objects").path + "/")
            ignored.append(common.appendingPathComponent("lfs").path + "/")
        }
        self.ignoredPrefixes = ignored

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, GitTreeWatcher.callback, &context,
            Array(Set(paths)) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05, flags)
        else { return nil }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let existing = stream
        stream = nil
        lock.unlock()
        guard let existing else { return }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<GitTreeWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        watcher.handle(list, count: count)
    }

    private func handle(_ paths: [String], count: Int) {
        guard !paths.isEmpty || count > 0 else { return }
        if !paths.isEmpty, ignoredPrefixes.isEmpty == false {
            let meaningful = paths.contains { path in
                !ignoredPrefixes.contains { path.hasPrefix($0) }
            }
            guard meaningful else { return }
        }
        onChange()
    }
}
