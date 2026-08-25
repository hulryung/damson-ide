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

    /// The same launch, with stdout left as the bytes git actually wrote.
    public func captureData(_ args: [String], cwd: URL? = nil,
                            timeout: TimeInterval = GitRunner.defaultTimeout) throws -> DataOutput {
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
        do {
            try proc.run()
        } catch {
            throw GitError("failed to launch git: \(error.localizedDescription)")
        }

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let lock = NSLock()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isStdout { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        // Waiting on the readers rather than on the process is what bounds this correctly:
        // both pipes hit EOF only once git has exited and its output is fully drained.
        if group.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            // Give it a moment to die and release the pipes, then escalate.
            if group.wait(timeout: .now() + 2) == .timedOut, proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 2)
            }
            throw GitError("git \(args.joined(separator: " ")) timed out after \(Int(timeout))s")
        }
        proc.waitUntilExit()

        return DataOutput(status: proc.terminationStatus,
                          stdout: outData,
                          stderr: String(decoding: errData, as: UTF8.self))
    }
}
