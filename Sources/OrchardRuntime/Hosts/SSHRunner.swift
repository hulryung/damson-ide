import Foundation

/// What one bounded remote command answered.
///
/// This is rule 2 (docs/design/remote-hosts.md §1) expressed as a return type: there is
/// no third case where a caller gets an empty result and has to decide for itself what
/// it meant. Either the far side answered — through a working, authenticated
/// connection — or contact was lost, which proves nothing about the far side and is
/// never a licence to guess.
public enum RemoteCommandOutcome: Equatable, Sendable {
    /// The remote command ran and its own status came back through the connection.
    case answered(exitCode: Int32, stdout: String, stderr: String)
    /// Nobody who can answer for the host was reachable. Not "no worktrees", not
    /// "nothing changed", not "it is gone".
    case unverifiable(reason: String)

    public var isUnverifiable: Bool {
        if case .unverifiable = self { return true }
        return false
    }

    /// stdout when the command answered *and* succeeded; nil otherwise.
    public var successOutput: String? {
        guard case .answered(let code, let stdout, _) = self, code == 0 else { return nil }
        return stdout
    }
}

/// Typed failures every remote worktree surface reports with.
///
/// `hostUnverifiable` is deliberately its own code rather than a flavour of
/// `git_error`: a caller that cannot tell "the host said no" from "the host said
/// nothing" is one step away from treating loss of contact as a successful delete.
public struct RemoteHostError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    /// Contact was lost. The message always carries the rule-2 reminder so no surface
    /// can quietly reword it into a death certificate.
    public static func unverifiable(host: String, doing what: String, reason: String) -> RemoteHostError {
        RemoteHostError("host_unverifiable",
                        "\(what) on \(host) is unverifiable — \(reason). "
                            + "Loss of contact is not evidence that anything on \(host) changed.")
    }

    public static func remoteGitFailed(_ message: String) -> RemoteHostError {
        RemoteHostError("remote_git_failed", message)
    }

    public static func invalidArgument(_ message: String) -> RemoteHostError {
        RemoteHostError("invalid_argument", message)
    }

    /// The wave-8 boundary: a surface that only knows how to work on a local
    /// filesystem, asked about a remote workspace.
    public static func unsupported(_ message: String) -> RemoteHostError {
        RemoteHostError("remote_unsupported", message)
    }
}

/// Runs one bounded command on a registered host over the system `ssh`.
///
/// The hardening mirrors `GitRunner` because the failure modes are the same and worse:
/// a wedged child holds the caller forever, and a full pipe buffer deadlocks a
/// sequential drain. On top of git's bounds this adds the two SSH-specific ones —
/// `BatchMode=yes` so OpenSSH fails instead of prompting a human who is not there, and
/// `ConnectTimeout` so the connect phase cannot absorb the whole deadline.
///
/// Since T89 a runner may carry a `RemoteConnection`, and then its calls share one
/// multiplexed `ssh` transport instead of paying a TCP connect, a key exchange and an
/// authentication each (design §3.1). With no connection it behaves exactly as before —
/// one `ssh` per call — which is what every fake-runner test pins and what the paths
/// that must *not* share a transport (the reverse-tunnel port walk, the reachability
/// probe) deliberately keep.
public struct SSHRunner: Sendable {
    public let host: HostRecord
    private let runner: HostCommandRunner
    public let timeout: TimeInterval
    public let connectTimeoutSeconds: Int
    /// The durable connection these calls ride, when there is one. nil is the
    /// historical behaviour: every call its own `ssh`, and no continuity claimed
    /// between two of them.
    public let connection: RemoteConnection?

    /// Ceiling on one remote command. Generous like `GitRunner.defaultTimeout` — a
    /// `worktree add` on a large repo is slow but legitimate — and still finite,
    /// because an agent-facing verb that can hang is worse than one that answers
    /// `unverifiable`.
    public static let defaultTimeout: TimeInterval = 120

    public init(host: HostRecord,
                runner: HostCommandRunner = ProcessHostCommandRunner(),
                timeout: TimeInterval = SSHRunner.defaultTimeout,
                connectTimeoutSeconds: Int = 5,
                connection: RemoteConnection? = nil) {
        self.host = host
        self.runner = runner
        self.timeout = timeout
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.connection = connection
    }

    /// The same runner, riding a durable connection. Used where a caller builds the
    /// runner first and learns about the pool second.
    public func multiplexed(over connection: RemoteConnection?) -> SSHRunner {
        SSHRunner(host: host, runner: runner, timeout: timeout,
                  connectTimeoutSeconds: connectTimeoutSeconds, connection: connection)
    }

    public var hostName: String { host.name }
    public var executionHostId: ExecutionHostId? { host.executionHostId }

    /// The argv one remote command line runs as, exposed so tests (and `--json`
    /// receipts) can show exactly what would be executed.
    public func argv(for commandLine: String, options: [String] = []) -> [String] {
        SSHCommand.commandArgv(for: host, command: commandLine,
                               connectTimeoutSeconds: connectTimeoutSeconds,
                               options: options)
    }

    /// Run a command line on the far side and classify what came back.
    ///
    /// With a durable connection this rides the shared transport, and the answer is
    /// discarded if OpenSSH admits it did not (see `RemoteConnection.settle`).
    public func run(_ commandLine: String, options: [String] = []) async -> RemoteCommandOutcome {
        await runReporting(commandLine, options: options).outcome
    }

    /// `run`, plus the generation that answered.
    ///
    /// Separate from `run` because most callers do not care which span of contact
    /// produced a stateless read — but anything that *records* an answer does, since an
    /// answer is only as current as the connection that carried it.
    public func runReporting(_ commandLine: String, options: [String] = []) async
        -> (outcome: RemoteCommandOutcome, generation: RemoteConnectionGeneration?) {
        guard let connection else {
            let result = await runner.run(argv(for: commandLine, options: options),
                                          timeout: timeout)
            return (Self.classify(result, host: host), nil)
        }
        switch await connection.acquire() {
        case .refused(let error):
            return (.unverifiable(reason: error.message), nil)
        case .ready(let generation, let multiplexOptions):
            let result = await runner.run(
                argv(for: commandLine, options: multiplexOptions + options), timeout: timeout)
            let outcome = Self.classify(result, host: host)
            return await connection.settle(generation: generation, result: result,
                                           outcome: outcome, fenced: false)
        }
    }

    /// Run a command line, but only on `generation` — and refuse if that span of
    /// contact has ended.
    ///
    /// This is the fence. It exists for the questions whose answer only means anything
    /// *within* one connection, where serving them from a later one would present a
    /// reconnect as continuity. The refusal is a typed `connection_generation_ended`,
    /// never a silent retry on the new connection.
    public func runFenced(_ commandLine: String, options: [String] = [],
                          generation: RemoteConnectionGeneration) async -> RemoteCommandOutcome {
        guard let connection else {
            return .unverifiable(reason: RemoteHostError.generationEnded(
                generation, current: nil,
                reason: "this runner holds no durable connection").message)
        }
        switch await connection.acquire(fencedTo: generation) {
        case .refused(let error):
            return .unverifiable(reason: error.message)
        case .ready(let served, let multiplexOptions):
            let result = await runner.run(
                argv(for: commandLine, options: multiplexOptions + options), timeout: timeout)
            let outcome = Self.classify(result, host: host)
            return await connection.settle(generation: served, result: result,
                                           outcome: outcome, fenced: true).outcome
        }
    }

    /// One bounded ssh invocation, returned *before* the answered/unverifiable
    /// classification.
    ///
    /// Exactly one caller needs this: the reverse-tunnel planner (T39). OpenSSH reports
    /// a refused port forward on its own stderr with status 255, and `classify` folds
    /// every 255 into `unverifiable` — correctly, since 255 usually means the transport
    /// failed. But that fold erases the one detail the planner turns on: "that port is
    /// taken, try the next" is not "the host is gone", and treating it as the latter
    /// would abandon a perfectly reachable host after one busy port.
    ///
    /// It is also deliberately *not* multiplexed. A `-R` requested over a shared master
    /// belongs to the master's lifetime rather than to the client that asked for it, so
    /// probing a port that way would tell us about a forward the pane will never own.
    public func runRaw(_ commandLine: String, options: [String] = []) async -> HostCommandResult {
        await runner.run(argv(for: commandLine, options: options), timeout: timeout)
    }

    /// Run `git -C <dir> <args…>` remotely. Every argument is shell-quoted because the
    /// far side evaluates the command line with a shell — an unquoted path with a space
    /// would silently become two arguments.
    public func git(_ args: [String], in directory: String) async -> RemoteCommandOutcome {
        await run(Self.commandLine(["git", "-C", directory] + args))
    }

    /// `git …` remotely, throwing typed errors instead of returning an outcome. Use it
    /// where a missing answer must stop the operation rather than be interpreted.
    @discardableResult
    public func requireGit(_ args: [String], in directory: String,
                           doing what: String) async throws -> String {
        try require(await git(args, in: directory), doing: what)
    }

    /// Collapse an outcome to stdout, or throw. The two failure shapes stay distinct:
    /// a nonzero status is the host's own answer, loss of contact is not an answer.
    public func require(_ outcome: RemoteCommandOutcome, doing what: String) throws -> String {
        switch outcome {
        case .unverifiable(let reason):
            throw RemoteHostError.unverifiable(host: host.name, doing: what, reason: reason)
        case .answered(let code, let stdout, let stderr):
            guard code == 0 else {
                let detail = Self.firstLine(stderr) ?? "exit \(code)"
                throw RemoteHostError.remoteGitFailed("\(what) on \(host.name) failed: \(detail)")
            }
            return stdout
        }
    }

    /// One trimmed line of stdout, or nil when the command answered with nothing.
    public func line(_ outcome: RemoteCommandOutcome, doing what: String) throws -> String? {
        let text = try require(outcome, doing: what).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Quote each token and join: the far side's login shell parses this string.
    public static func commandLine(_ argv: [String]) -> String {
        argv.map(SSHCommand.shellQuote).joined(separator: " ")
    }

    /// The one place a raw runner result becomes a verdict.
    ///
    /// Status 255 is OpenSSH reporting *its own* transport failure, so it says nothing
    /// about the far side: `unverifiable`, never a failed command. Every other status
    /// was propagated back through a working connection and is the remote command's own
    /// answer (`HostLiveness.sshTransportFailureExitCode`, design §1).
    public static func classify(_ result: HostCommandResult, host: HostRecord) -> RemoteCommandOutcome {
        if result.timedOut {
            return .unverifiable(reason: "the command hit its deadline with no answer")
        }
        guard let exitCode = result.exitCode else {
            return .unverifiable(reason: firstLine(result.stderr) ?? "the command could not be run")
        }
        guard exitCode == HostLiveness.sshTransportFailureExitCode else {
            return .answered(exitCode: exitCode, stdout: result.stdout, stderr: result.stderr)
        }
        // Reuse the probe's fragment table so "wrong key" and "no route" read the same
        // here as they do in `host check`.
        let (_, detail) = HostProbe.classify(result)
        return .unverifiable(reason: detail)
    }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
