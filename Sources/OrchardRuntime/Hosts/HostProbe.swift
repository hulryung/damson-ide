import Foundation

/// What one bounded connectivity probe answered.
///
/// Three outcomes, and the split between them is deliberate: `authRequired` is a host
/// that answered — the transport worked and only credentials are missing, which a human
/// can fix — while `unreachable` is *loss of contact*, which proves nothing about the
/// host beyond "we could not talk to it just now" (see `HostLivenessVerdict`).
public enum HostReachability: String, Codable, Sendable {
    case reachable
    case authRequired = "auth-required"
    case unreachable
}

public struct HostProbeResult: Codable, Equatable, Sendable {
    public let name: String
    public let executionHostId: String
    public let status: HostReachability
    /// One line a human can act on — OpenSSH's own words where there are any.
    public let detail: String
    /// The exact command that was run, so an operator can reproduce the answer.
    public let command: String
    public let timedOut: Bool
    /// Present when the probe did not reach the host: the reminder that this is loss of
    /// contact, not evidence that anything there stopped.
    public let note: String?
    /// When this probe finished. Presentation-only — never persisted on the host record.
    public let lastCheckedAt: Date
    /// Wall-clock duration of this probe in milliseconds, when it was measured.
    public let latencyMs: Double?

    public init(name: String, executionHostId: String, status: HostReachability,
                detail: String, command: String, timedOut: Bool, note: String? = nil,
                lastCheckedAt: Date = Date(), latencyMs: Double? = nil) {
        self.name = name
        self.executionHostId = executionHostId
        self.status = status
        self.detail = detail
        self.command = command
        self.timedOut = timedOut
        self.note = note
        self.lastCheckedAt = lastCheckedAt
        self.latencyMs = latencyMs
    }

    public func ageSeconds(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(lastCheckedAt))
    }
}

public struct HostCommandResult: Equatable, Sendable {
    public let exitCode: Int32?
    public let stdout: String
    public let stderr: String
    /// The runner hit its own deadline and killed the child.
    public let timedOut: Bool

    public init(exitCode: Int32?, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// The seam that keeps probe *classification* testable without an SSH server: tests
/// install a runner that returns canned OpenSSH output.
public protocol HostCommandRunner: Sendable {
    func run(_ argv: [String], timeout: TimeInterval) async -> HostCommandResult
}

/// Runs the probe as a real child process under a hard deadline.
///
/// Two independent bounds, because either alone can be defeated: `ConnectTimeout=5`
/// bounds OpenSSH's connect phase, and this deadline bounds *everything else* (a TCP
/// connection that opens and then never says anything, a wedged ProxyCommand, a
/// password prompt that BatchMode somehow did not suppress). `host check` must return.
public struct ProcessHostCommandRunner: HostCommandRunner {
    public init() {}

    /// Shared between the child and its watchdog so the result can say *why* the probe
    /// ended: a killed probe is a deadline, not an answer from the host.
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        var didFire: Bool {
            lock.lock(); defer { lock.unlock() }
            return fired
        }
        func fire() {
            lock.lock(); fired = true; lock.unlock()
        }
    }

    /// The blocking work (pipe drain + `waitUntilExit`) runs on a global queue rather
    /// than on the calling task's cooperative thread: a probe that occupied one of
    /// those for its whole deadline would starve unrelated work.
    public func run(_ argv: [String], timeout: TimeInterval) async -> HostCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(argv, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ argv: [String], timeout: TimeInterval) -> HostCommandResult {
        guard let executable = argv.first else {
            return HostCommandResult(exitCode: nil, stderr: "empty command")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Nothing may read from the terminal that launched Orchard: a probe that
        // inherits stdin can park on a prompt forever.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return HostCommandResult(exitCode: nil, stderr: "could not run \(executable): \(error)")
        }

        let deadline = Deadline()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            deadline.fire()
            process.terminate()
            // SIGTERM first, SIGKILL if the child ignores it — an `ssh` parked in a
            // handshake has been known to.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: watchdog)

        // Both pipes are drained *concurrently*, the way `GitRunner.capture` does it.
        // Reading them in sequence deadlocks the moment either 64 KB buffer fills while
        // nothing is reading the other — which a probe never does, but a remote
        // `git worktree list` on a busy repo (stdout) beside a git advice banner
        // (stderr) certainly can.
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
        group.wait()
        let stdout = outData, stderr = errData
        process.waitUntilExit()
        watchdog.cancel()
        let timedOut = deadline.didFire
        return HostCommandResult(
            // A killed probe has no answer from the host: reporting its signal status
            // as an exit code would read as "the host said 143".
            exitCode: timedOut ? nil : process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            timedOut: timedOut)
    }
}

/// Classifies a bounded `ssh … true` probe. Pure: the same output always yields the
/// same verdict, which is what the fake-runner tests pin.
public enum HostProbe {
    /// Total wall-clock bound for one probe, comfortably above `ConnectTimeout=5` so a
    /// slow-but-working handshake is not misreported as a dead host.
    public static let defaultTimeout: TimeInterval = 12

    private static let authFragments = [
        "permission denied",
        "publickey",
        "authentication failed",
        "no supported authentication methods",
        "too many authentication failures",
        "host key verification failed",
        "remote host identification has changed",
        "passphrase",
        "keyboard-interactive"
    ]

    private static let unreachableFragments = [
        "could not resolve hostname",
        "name or service not known",
        "nodename nor servname",
        "temporary failure in name resolution",
        "connection refused",
        "connection timed out",
        "operation timed out",
        "connection reset",
        "no route to host",
        "network is unreachable",
        "network is down",
        "host is down",
        "kex_exchange_identification",
        "ssh_exchange_identification",
        "connection closed by remote",
        "broken pipe"
    ]

    public static func classify(_ result: HostCommandResult) -> (HostReachability, String) {
        if result.timedOut {
            return (.unreachable, "the probe hit its deadline with no answer")
        }
        guard let exitCode = result.exitCode else {
            return (.unreachable, firstLine(result.stderr) ?? "the probe could not be run")
        }
        if exitCode == 0 {
            return (.reachable, "authenticated and ran the probe command")
        }
        let stderr = result.stderr.lowercased()
        // OpenSSH reserves 255 for its own failures; any other status came back through
        // a working, authenticated connection, so the host answered.
        if exitCode != HostLiveness.sshTransportFailureExitCode {
            return (.reachable,
                    firstLine(result.stderr)
                        ?? "the remote command exited \(exitCode); the connection itself worked")
        }
        if authFragments.contains(where: stderr.contains) {
            return (.authRequired, firstLine(result.stderr) ?? "the host refused the offered credentials")
        }
        if unreachableFragments.contains(where: stderr.contains) {
            return (.unreachable, firstLine(result.stderr) ?? "the host could not be contacted")
        }
        return (.unreachable, firstLine(result.stderr) ?? "ssh exited \(exitCode) with no message")
    }

    /// Run and classify one probe. Bounded twice (see `ProcessHostCommandRunner`), so
    /// this cannot hang whatever the host does.
    public static func check(host: HostRecord,
                             runner: HostCommandRunner = ProcessHostCommandRunner(),
                             timeout: TimeInterval = defaultTimeout) async -> HostProbeResult {
        let argv = SSHCommand.probeArgv(for: host)
        let started = Date()
        let result = await runner.run(argv, timeout: timeout)
        let finished = Date()
        let (status, detail) = classify(result)
        return HostProbeResult(
            name: host.name,
            executionHostId: host.executionHostId?.rawValue ?? "ssh:\(host.name)",
            status: status,
            detail: detail,
            command: argv.map(SSHCommand.shellQuote).joined(separator: " "),
            timedOut: result.timedOut,
            note: status == .unreachable
                ? "Unreachable is loss of contact, not evidence that anything on "
                    + "\(host.name) stopped."
                : nil,
            lastCheckedAt: finished,
            latencyMs: finished.timeIntervalSince(started) * 1000)
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        return (line?.isEmpty ?? true) ? nil : line
    }
}
