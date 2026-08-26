import Foundation

/// Shared `git` process runner. Everything in the orchestrator that shells out to git goes
/// through here so there is exactly one place that resolves the binary, captures output,
/// and turns a nonzero exit into a `GitError`.
///
/// `git` is resolved to an absolute path because a GUI-launched app inherits a minimal
/// `PATH` (no `/opt/homebrew/bin`), so a bare `git` would fail only when launched from the
/// Dock — the worst kind of bug to discover.
public struct GitRunner: Sendable {
    public static let shared = GitRunner()

    /// Absolute path to the `git` binary.
    public let gitPath: String

    public init(gitPath: String? = nil) {
        self.gitPath = gitPath ?? Self.resolveGit()
    }

    private static func resolveGit() -> String {
        for path in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/git"
    }

    /// Run git and return stdout, throwing `GitError` on a nonzero exit.
    @discardableResult
    public func run(_ args: [String], cwd: URL? = nil) throws -> String {
        let result = try capture(args, cwd: cwd)
        guard result.status == 0 else {
            throw GitError("git \(args.joined(separator: " ")) failed (\(result.status)): "
                + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// Run git in a worktree/repo directory (`git -C <dir> …`).
    @discardableResult
    public func run(in dir: URL, _ args: [String]) throws -> String {
        try run(["-C", dir.path] + args)
    }

    /// Run git in a directory and return stdout, or `nil` if it failed. For queries where a
    /// failure is an ordinary answer ("no upstream", "not a repo") rather than an error worth
    /// surfacing — the caller substitutes a default instead of unwinding.
    public func query(in dir: URL, _ args: [String]) -> String? {
        guard let result = try? capture(["-C", dir.path] + args), result.status == 0 else { return nil }
        return result.stdout
    }

    /// Same as `query`, trimmed of surrounding whitespace and nil when empty.
    public func line(in dir: URL, _ args: [String]) -> String? {
        guard let out = query(in: dir, args)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else { return nil }
        return out
    }

    // MARK: - Raw bytes
    //
    // Everything above decodes stdout as UTF-8 *lossily*: any byte git emits that is not
    // valid UTF-8 becomes U+FFFD, and re-encoding that string writes three bytes where one
    // stood. That is fine for prose git wrote itself (status codes, refs, diffs shown to a
    // human) and catastrophic for file content that gets written back to disk — it silently
    // rewrites bytes nobody touched. Content round-trips go through these instead.

    /// Run git and return stdout as raw bytes, throwing `GitError` on a nonzero exit.
    @discardableResult
    public func runData(_ args: [String], cwd: URL? = nil) throws -> Data {
        let result = try captureData(args, cwd: cwd)
        guard result.status == 0 else {
            throw GitError("git \(args.joined(separator: " ")) failed (\(result.status)): "
                + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// Run git in a worktree/repo directory and return stdout as raw bytes.
    @discardableResult
    public func runData(in dir: URL, _ args: [String]) throws -> Data {
        try runData(["-C", dir.path] + args)
    }

    /// Byte-exact counterpart of `query`: raw stdout, or nil when git failed. Used for blob
    /// content (`git show :2:path`), where "it isn't there" is an ordinary answer.
    public func queryData(in dir: URL, _ args: [String]) -> Data? {
        guard let result = try? captureData(["-C", dir.path] + args), result.status == 0 else {
            return nil
        }
        return result.stdout
    }

    // MARK: - Process

    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// `capture` before the stdout bytes are decoded. `stderr` stays a `String` because it
    /// only ever carries git's own diagnostics, which are the text of an error message.
    public struct DataOutput: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
    }

    /// Default ceiling on a single git invocation.
    ///
    /// Every git call here is synchronous, and `WorktreeManager` serializes its mutations on
    /// one queue — so a single wedged process (a network remote that never answers, an
    /// iCloud/OneDrive placeholder that never materializes) would block every other agent's
    /// worktree operation indefinitely. A generous bound still beats an unbounded hang.
    public static let defaultTimeout: TimeInterval = 180

    /// Launch git and capture both streams. Reads stdout/stderr concurrently — draining them
    /// sequentially deadlocks as soon as either pipe's buffer fills (a large `git diff` does).
    ///
    /// A process that outlives `timeout` is terminated and reported as a `GitError` rather
    /// than left to hold the caller forever.
    public func capture(_ args: [String], cwd: URL? = nil,
                        timeout: TimeInterval = GitRunner.defaultTimeout) throws -> Output {
        let raw = try captureData(args, cwd: cwd, timeout: timeout)
        return Output(status: raw.status,
                      stdout: String(decoding: raw.stdout, as: UTF8.self),
                      stderr: raw.stderr)
    }

    /// Every `git` process this runner has launched, and the wall-clock they cost.
    ///
    /// A spawn counter rather than a log: the thing that made a workspace switch slow was
    /// never one slow git call, it was six fast ones per worktree, and only a count makes
    /// that visible. `ORCHARD_GIT_TRACE=1` additionally prints each invocation.
    public enum Trace {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var count = 0
        nonisolated(unsafe) private static var mainThread = 0
        nonisolated(unsafe) private static var running = 0
        nonisolated(unsafe) private static var nanos: UInt64 = 0
        private static let enabled = ProcessInfo.processInfo.environment["ORCHARD_GIT_TRACE"] == "1"

        /// Counted at launch, not at exit, so `inFlight` is the truth while a spawn is
        /// still running — a test that waits for the runner to go quiet needs to see a
        /// git that has started but not yet finished.
        static func began(_ args: [String]) -> Int {
            let onMain = Thread.isMainThread
            lock.lock()
            count += 1
            running += 1
            if onMain { mainThread += 1 }
            let n = count
            lock.unlock()
            if enabled {
                let line = "git-trace #\(n)\(onMain ? " MAIN" : "") start: "
                    + "git \(args.joined(separator: " "))\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            return n
        }

        static func finished(_ id: Int, _ args: [String], _ elapsed: UInt64) {
            lock.lock()
            running -= 1
            nanos += elapsed
            lock.unlock()
            if enabled {
                let line = "git-trace #\(id) \(elapsed / 1_000_000)ms: "
                    + "git \(args.joined(separator: " "))\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }

        /// Spawns started so far, how many of them blocked the main thread, how many are
        /// still running, and the total time spent inside the finished ones.
        ///
        /// `mainThreadSpawns` is the number the workbench cares about: a git call on the
        /// main thread is a frame the UI did not draw. Tests assert it stays at zero
        /// across the paths a workspace switch runs.
        public static func snapshot()
            -> (spawns: Int, mainThreadSpawns: Int, inFlight: Int, milliseconds: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (count, mainThread, running, Int(nanos / 1_000_000))
        }

        /// Zero the totals. `inFlight` is deliberately untouched: a spawn that is still
        /// running will decrement it when it finishes, and resetting it here would drive
        /// the count negative.
        public static func reset() {
            lock.lock()
            count = 0
            mainThread = 0
            nanos = 0
            lock.unlock()
        }
    }

    /// The same launch, with stdout left as the bytes git actually wrote.
    public func captureData(_ args: [String], cwd: URL? = nil,
                            timeout: TimeInterval = GitRunner.defaultTimeout) throws -> DataOutput {
        let started = DispatchTime.now().uptimeNanoseconds
        let traceID = Trace.began(args)
        defer { Trace.finished(traceID, args, DispatchTime.now().uptimeNanoseconds - started) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitPath)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = cwd }
        // Keep git non-interactive: never pop a credential/askpass GUI from a background query.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"   // read-only queries must not take index.lock
        proc.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Reaped through the termination handler rather than `waitUntilExit()`, which is
        // documented to poll the *current run loop*. On the app's main thread that is
        // AppKit's run loop, and the wake is nowhere near prompt: a git call that costs
        // ~10 ms from the headless runtime costs ~85 ms from inside the app, and the gap
        // does not scale with how many gits are running. A semaphore signalled off the
        // run loop costs the same everywhere.
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do {
            try proc.run()
        } catch {
            throw GitError("failed to launch git: \(error.localizedDescription)")
        }

        var outData = Data(), errData = Data()
        // Both pipes are drained on *this* thread with `poll`, not on two dispatched
        // reader blocks. Sequentially reading one pipe then the other would deadlock as
        // soon as either buffer fills (a large `git diff` does), but the two dispatched
        // readers had their own cost: every git call parked two threads on the global
        // concurrent queue while its caller blocked on a third, so a handful of git
        // queries running at once starved that pool and turned 10 ms spawns into 80 ms
        // ones. `poll` watches both descriptors from one thread with no pool at all.
        let deadline = DispatchTime.now() + timeout
        var timedOut = Self.drain(outPipe.fileHandleForReading, errPipe.fileHandleForReading,
                                  into: &outData, &errData, deadline: deadline)
        if timedOut {
            proc.terminate()
            // Give it a moment to die and release the pipes, then escalate.
            timedOut = Self.drain(outPipe.fileHandleForReading, errPipe.fileHandleForReading,
                                  into: &outData, &errData, deadline: .now() + 2)
            if timedOut, proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                _ = Self.drain(outPipe.fileHandleForReading, errPipe.fileHandleForReading,
                               into: &outData, &errData, deadline: .now() + 2)
            }
            throw GitError("git \(args.joined(separator: " ")) timed out after \(Int(timeout))s")
        }
        // Both pipes are at EOF, so the child has closed its descriptors and is about to
        // be reaped; the bound is only there so a wedged handler cannot hold the caller.
        if exited.wait(timeout: .now() + 5) == .timedOut {
            proc.waitUntilExit()
        }

        return DataOutput(status: proc.terminationStatus,
                          stdout: outData,
                          stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Read both pipes until each hits EOF, or until `deadline`. Returns true when the
    /// deadline arrived first — the caller decides whether that means "kill it".
    ///
    /// Descriptors already at EOF are simply skipped, so this is safe to call again after
    /// terminating the child to collect whatever it managed to write.
    private static func drain(_ out: FileHandle, _ err: FileHandle,
                              into outData: inout Data, _ errData: inout Data,
                              deadline: DispatchTime) -> Bool {
        let fds = [out.fileDescriptor, err.fileDescriptor]
        for fd in fds {
            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        }
        var live = [true, true]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while live.contains(true) {
            let now = DispatchTime.now()
            if now >= deadline { return true }
            let remainingMS = Int32(min((deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                                        / 1_000_000, 1_000))
            var watched: [pollfd] = []
            var slots: [Int] = []
            for (index, fd) in fds.enumerated() where live[index] {
                watched.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0))
                slots.append(index)
            }
            let ready = poll(&watched, nfds_t(watched.count), max(remainingMS, 1))
            if ready < 0 {
                if errno == EINTR { continue }
                return false        // the descriptors are unusable; treat it as EOF
            }
            if ready == 0 { continue }   // tick; the loop re-checks the deadline

            for (slot, watcher) in zip(slots, watched) where watcher.revents != 0 {
                // POLLHUP can arrive with data still buffered, so read until the
                // descriptor says EAGAIN (nothing more now) or 0 (nothing more ever).
                readLoop: while true {
                    let count = buffer.withUnsafeMutableBytes {
                        read(fds[slot], $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        buffer.withUnsafeBufferPointer {
                            let bytes = UnsafeBufferPointer(start: $0.baseAddress, count: count)
                            if slot == 0 { outData.append(bytes) } else { errData.append(bytes) }
                        }
                        continue
                    }
                    if count == 0 { live[slot] = false; break readLoop }
                    switch errno {
                    case EINTR: continue
                    case EAGAIN: break readLoop
                    default: live[slot] = false; break readLoop
                    }
                }
            }
        }
        return false
    }
}
