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
/// Each call is its own `ssh` invocation. Orchard deliberately does not implement
/// connection multiplexing (design §7): a user who wants it already has `ControlMaster`
/// in `~/.ssh/config`, and that config is the configuration surface.
public struct SSHRunner: Sendable {
    public let host: HostRecord
    private let runner: HostCommandRunner
    public let timeout: TimeInterval
    public let connectTimeoutSeconds: Int

    /// Ceiling on one remote command. Generous like `GitRunner.defaultTimeout` — a
    /// `worktree add` on a large repo is slow but legitimate — and still finite,
    /// because an agent-facing verb that can hang is worse than one that answers
    /// `unverifiable`.
    public static let defaultTimeout: TimeInterval = 120

    public init(host: HostRecord,
                runner: HostCommandRunner = ProcessHostCommandRunner(),
                timeout: TimeInterval = SSHRunner.defaultTimeout,
                connectTimeoutSeconds: Int = 5) {
        self.host = host
        self.runner = runner
        self.timeout = timeout
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    public var hostName: String { host.name }
    public var executionHostId: ExecutionHostId? { host.executionHostId }

    /// The argv one remote command line runs as, exposed so tests (and `--json`
    /// receipts) can show exactly what would be executed.
    public func argv(for commandLine: String) -> [String] {
        SSHCommand.commandArgv(for: host, command: commandLine,
                               connectTimeoutSeconds: connectTimeoutSeconds)
    }

    /// Run a command line on the far side and classify what came back.
    public func run(_ commandLine: String) async -> RemoteCommandOutcome {
        let result = await runner.run(argv(for: commandLine), timeout: timeout)
        return Self.classify(result, host: host)
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
