import Foundation
import os

/// What one `gh` invocation produced.
public struct GitHubCLIOutcome: Equatable, Sendable {
    /// `nil` when the binary could not be launched at all (missing / not executable).
    public var status: Int32?
    public var stdout: String
    public var stderr: String
    /// True when the deadline passed and the process was killed. Distinct from a
    /// nonzero exit: a timeout is not evidence of anything about the PR.
    public var timedOut: Bool
    /// The binary that was launched, or nil when none was found.
    public var executablePath: String?

    public init(status: Int32?, stdout: String = "", stderr: String = "",
                timedOut: Bool = false, executablePath: String? = nil) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.executablePath = executablePath
    }

    public static func notInstalled() -> GitHubCLIOutcome {
        GitHubCLIOutcome(status: nil, stderr: "gh not found")
    }

    public var launched: Bool { status != nil || timedOut }
}

/// One bounded `gh` invocation. The seam the checks service is tested against.
public protocol GitHubCLIProbe: Sendable {
    /// Absolute path of the `gh` this probe would run, or nil when there is none.
    /// Resolved without launching anything, so "is gh installed" costs no process.
    func resolvedExecutable() -> String?
    func run(_ arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitHubCLIOutcome
}

/// Production probe.
///
/// `gh` is resolved to an absolute path for the same reason `GitRunner` resolves
/// `git`: a Dock-launched app inherits a minimal `PATH` with no `/opt/homebrew/bin`,
/// so a bare `gh` would work from a terminal and be "not installed" from the Dock —
/// and this task's whole contract is that "not installed" must be true when it is
/// shown.
///
/// Every invocation runs on a detached utility task: nothing here may touch the
/// main thread, and nothing here may be called from a view body.
public struct SystemGitHubCLI: GitHubCLIProbe {
    public static let searchPaths = [
        "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", "/opt/local/bin/gh",
    ]

    /// Extra environment layered over the process environment. Tests use it to
    /// point `gh` at a scratch config dir; production passes nothing.
    public var environmentOverrides: [String: String]
    private let explicitPath: String?

    public init(executablePath: String? = nil,
                environmentOverrides: [String: String] = [:]) {
        self.explicitPath = executablePath
        self.environmentOverrides = environmentOverrides
    }

    public func resolvedExecutable() -> String? {
        if let explicitPath {
            return FileManager.default.isExecutableFile(atPath: explicitPath) ? explicitPath : nil
        }
        for path in Self.searchPaths
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: whatever this process's own PATH can see. A terminal-launched
        // build with gh somewhere unusual still works.
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = String(directory) + "/gh"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func run(_ arguments: [String], cwd: URL,
                    timeout: TimeInterval) async -> GitHubCLIOutcome {
        let overrides = environmentOverrides
        let path = resolvedExecutable()
        return await Task.detached(priority: .utility) { () -> GitHubCLIOutcome in
            guard let path else { return .notInstalled() }
            return Self.launch(path, arguments: arguments, cwd: cwd,
                               timeout: timeout, overrides: overrides)
        }.value
    }

    static func launch(_ path: String, arguments: [String], cwd: URL,
                       timeout: TimeInterval,
                       overrides: [String: String]) -> GitHubCLIOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        // Never let a pager or a prompt hold the process: this runs unattended.
        environment["GH_PAGER"] = ""
        environment["PAGER"] = "cat"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["CLICOLOR"] = "0"
        environment["NO_COLOR"] = "1"
        for (key, value) in overrides { environment[key] = value }
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return GitHubCLIOutcome(status: nil, stderr: String(describing: error),
                                    executablePath: path)
        }

        // Both pipes drained concurrently: reading them in sequence deadlocks the
        // moment either buffer fills, and a job log fills one immediately.
        let lock = NSLock()
        var stdoutData = Data(), stderrData = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { stdoutData = data } else { stderrData = data }
                lock.unlock()
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            // A `gh` wedged on a socket ignores SIGTERM; SIGKILL is what actually
            // frees the pipes so the drain threads can finish.
            let hardDeadline = Date().addingTimeInterval(1.0)
            while process.isRunning, Date() < hardDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        // Bounded: the drains finish the instant the pipes close, which exiting
        // does. The timeout exists so a grandchild holding a pipe open cannot
        // strand this thread — whatever was captured by then is what we report.
        _ = group.wait(timeout: .now() + 2)
        lock.lock()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        lock.unlock()
        return GitHubCLIOutcome(status: timedOut ? nil : process.terminationStatus,
                                stdout: stdout, stderr: stderr,
                                timedOut: timedOut, executablePath: path)
    }
}

/// Test double: canned outcomes keyed by the first two arguments (`pr view`,
/// `run view`, …), plus an invocation log so tests can assert the cache actually
/// prevented a second spawn.
public final class FixtureGitHubCLI: GitHubCLIProbe, @unchecked Sendable {
    private struct State {
        var executable: String? = "/fixture/gh"
        var responses: [String: GitHubCLIOutcome] = [:]
        var fallback: GitHubCLIOutcome = GitHubCLIOutcome(status: 1, stderr: "unscripted")
        var invocations: [[String]] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// `nil` means "gh is not installed on this machine".
    public func setExecutable(_ path: String?) {
        state.withLock { $0.executable = path }
    }

    /// Script a response for a command prefix, e.g. `["pr", "view"]`.
    public func script(_ prefix: [String], _ outcome: GitHubCLIOutcome) {
        state.withLock { $0.responses[prefix.joined(separator: " ")] = outcome }
    }

    public func scriptFallback(_ outcome: GitHubCLIOutcome) {
        state.withLock { $0.fallback = outcome }
    }

    public var invocations: [[String]] { state.withLock { $0.invocations } }

    public func resolvedExecutable() -> String? { state.withLock { $0.executable } }

    public func run(_ arguments: [String], cwd: URL,
                    timeout: TimeInterval) async -> GitHubCLIOutcome {
        state.withLock { s in
            s.invocations.append(arguments)
            guard s.executable != nil else { return GitHubCLIOutcome.notInstalled() }
            for length in stride(from: min(3, arguments.count), through: 1, by: -1) {
                let key = arguments.prefix(length).joined(separator: " ")
                if let hit = s.responses[key] { return hit }
            }
            return s.fallback
        }
    }
}
