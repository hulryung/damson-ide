import Foundation
import OrchardProtocol
import OrchardTerminals

// T80 — supervised dispatch across the host boundary.
//
// Until this task, `worker-start` refused every remote placement with a flat
// `remote_unsupported`, and the reason it gave was a *claim about the far side*: "the
// remote host has no orchard CLI, so a worker there cannot send worker_done". That
// claim was right about every host we could reach at the time, and wrong as a rule.
// Whether the far side can discharge a dispatch's duties is a question with an answer,
// and the answer is cheap to get: run the CLI over there and see which runtime it
// reaches.
//
// So the boundary is now a *precondition*, not an assumption. `worker-start` asks the
// host, before it creates anything, and only the host's own answer opens the door:
//
//   ssh <dest> 'export ORCHARD_CLI_COMMAND=…; export ORCHARD_DATA_PATH=…; <cli> status --json'
//
// The two exported variables are the ones that decide *which* runtime the far side
// talks to, and they are byte-identical to what the pane will carry (T78 wraps the
// remote command with the same `OrchardIdentity.exportAssignments`). So the probe is
// not a proxy for the pane's environment — it is that environment.
//
// The answer must name *this* runtime. A far side that reaches some other Orchard is
// worse than one that reaches none: its `worker_done` would settle a dispatch in
// another runtime's tables, and this coordinator would wait forever for a settlement
// that already happened somewhere else.

/// What one host answered about its ability to carry a supervised dispatch.
public enum RemoteDispatchReadiness: Sendable, Equatable {
    /// The far side ran the CLI and reached *this* runtime. `cliCommand` is the command
    /// that answered, so the preamble can tell the worker exactly what ran.
    case ready(runtimeId: String, cliCommand: String)
    /// The far side answered, and its answer rules a supervised dispatch out.
    /// `code` is the machine-readable reason (see `RemoteDispatchProbe`).
    case refused(code: String, detail: String)
    /// Nobody who can answer for the host was reachable. Rule 2: this is loss of
    /// contact, never evidence about anything on the far side.
    case unverifiable(reason: String)
}

/// Runs the precondition over a registered host.
public struct RemoteDispatchProbe: Sendable {
    /// The far side has no runnable `orchard` at the path this runtime hands its panes.
    public static let cliMissing = "remote_cli_missing"
    /// The CLI is there and ran, but could not reach a runtime control plane.
    public static let runtimeUnreachable = "remote_runtime_unreachable"
    /// The CLI reached a runtime — a different one. Its lifecycle calls would settle
    /// somebody else's dispatch rows.
    public static let runtimeMismatch = "remote_runtime_mismatch"
    /// It answered with something that is not an Orchard status envelope.
    public static let unintelligible = "remote_status_unintelligible"
    /// This runtime has no host registry wired, so it cannot even ask.
    public static let notWired = "remote_hosts_unavailable"

    /// Ceiling on the precondition. Deliberately tight: this runs in front of a
    /// coordinator's `worker-start`, and an agent-facing verb that can hang is worse
    /// than one that answers "unverifiable" (docs/design/remote-hosts.md §3).
    public static let timeout: TimeInterval = 20

    public let hosts: HostRegistry
    public let runner: HostCommandRunner
    /// The command every pane on this runtime is told to call, and therefore the one
    /// the probe must run — probing a different binary would prove nothing about the
    /// pane.
    public let cliCommand: String
    /// This runtime's data directory. `ORCHARD_DATA_PATH` names it, and since the CLI
    /// honors that variable it is what points the far side at *us* rather than at
    /// whatever runtime the remote account's own `HOME` happens to hold.
    public let dataPath: String
    public let runtimeId: String

    public init(hosts: HostRegistry, runner: HostCommandRunner = ProcessHostCommandRunner(),
                cliCommand: String, dataPath: String, runtimeId: String) {
        self.hosts = hosts
        self.runner = runner
        self.cliCommand = cliCommand
        self.dataPath = dataPath
        self.runtimeId = runtimeId
    }

    /// The exact far-side command line, exposed so a receipt (and a test) can show what
    /// was asked rather than describing it.
    public var remoteCommandLine: String {
        let exports = OrchardIdentity.exportAssignments([
            ("ORCHARD_CLI_COMMAND", cliCommand),
            ("ORCHARD_DATA_PATH", dataPath),
        ])
        return "\(exports); \(SSHCommand.shellQuote(cliCommand)) status --json"
    }

    public func probe(hostId: String) async -> RemoteDispatchReadiness {
        guard let host = ExecutionHostId(rawValue: hostId), host.kind == .ssh else {
            return .refused(code: RemoteDispatchProbe.notWired,
                            detail: "'\(hostId)' is not a usable remote execution host id")
        }
        guard let record = hosts.find(name: host.name) else {
            return .refused(
                code: RemoteDispatchProbe.notWired,
                detail: "no host named '\(host.name)' is registered, so nothing can be asked of it")
        }
        let ssh = SSHRunner(host: record, runner: runner,
                            timeout: RemoteDispatchProbe.timeout)
        return Self.classify(await ssh.run(remoteCommandLine),
                             cliCommand: cliCommand, runtimeId: runtimeId,
                             hostName: host.name)
    }

    /// The one place a remote `status` result becomes a verdict.
    static func classify(_ outcome: RemoteCommandOutcome, cliCommand: String,
                         runtimeId: String, hostName: String) -> RemoteDispatchReadiness {
        switch outcome {
        case .unverifiable(let reason):
            return .unverifiable(reason: reason)
        case .answered(let code, let stdout, let stderr):
            guard code == 0 else {
                let detail = SSHRunner.firstLine(stderr) ?? SSHRunner.firstLine(stdout)
                    ?? "exit \(code)"
                // 127 is the shell's own "no such command"; the wording of the message
                // is the other half of the same fact, and either one alone is a shaky
                // signal on a host whose login shell we do not control.
                if code == 127 || detail.lowercased().contains("not found") {
                    return .refused(
                        code: cliMissing,
                        detail: "\(cliCommand) is not runnable on \(hostName): \(detail)")
                }
                return .refused(
                    code: runtimeUnreachable,
                    detail: "\(cliCommand) status failed on \(hostName): \(detail)")
            }
            guard let answered = runtimeID(inStatus: stdout) else {
                // A CLI that ran but could not connect prints its own failure. That is
                // still an answer from the host — it is just not one a dispatch can use.
                let detail = SSHRunner.firstLine(stderr)
                    ?? SSHRunner.firstLine(stdout) ?? "no status envelope came back"
                let unreachable = detail.lowercased().contains("runtime_unavailable")
                    || detail.lowercased().contains("no such file")
                    || detail.lowercased().contains("couldn't be opened")
                return .refused(code: unreachable ? runtimeUnreachable : unintelligible,
                                detail: "\(cliCommand) status on \(hostName) answered: \(detail)")
            }
            guard answered == runtimeId else {
                return .refused(
                    code: runtimeMismatch,
                    detail: "\(cliCommand) on \(hostName) reached runtime \(answered), "
                        + "not this one (\(runtimeId))")
            }
            return .ready(runtimeId: answered, cliCommand: cliCommand)
        }
    }

    /// Pull the runtime id out of an `orchard status --json` envelope.
    ///
    /// Scanning from the first `{` rather than decoding the whole stream, because a
    /// remote login shell is allowed to print its own noise first (a `.zshenv` banner,
    /// an MOTD fragment) and that noise is not a reason to refuse a working host.
    static func runtimeID(inStatus stdout: String) -> String? {
        guard let start = stdout.firstIndex(of: "{") else { return nil }
        let body = String(stdout[start...])
        guard let data = body.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value.field("ok")?.boolValue == true else { return nil }
        let id = value.field("result")?.field("runtimeId")?.stringValue
            ?? value.field("_meta")?.field("runtimeId")?.stringValue
        guard let id, !id.isEmpty else { return nil }
        return id
    }
}

extension LiveOrchestrationStore {
    /// Gate one remote placement, or nil when the far side proved it can carry the
    /// dispatch.
    ///
    /// Every refusal lands *before* anything is created, carries the probe's own
    /// machine-readable reason in `data.reason`, and names the command that was run —
    /// a coordinator that is told "your host cannot do this" deserves to see the
    /// question that was asked.
    static func remoteDispatchGate(hostId: String?, worktreeID: String, agent: String?,
                                   readiness: RemoteDispatchReadiness) -> RPCServiceError? {
        let hostLabel = RemoteWorkspacePolicy.hostLabel(hostId)
        switch readiness {
        case .ready:
            return nil
        case .unverifiable(let rawReason):
            // `ssh` stderr arrives with its own CRLF; a message that carries it breaks
            // mid-sentence in every human face that prints it.
            let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
            // Rule 2 (docs/design/remote-hosts.md §1): contact was lost. Refusing is
            // right — we cannot start a worker we cannot supervise — but the wording
            // must not turn "we could not look" into "that host cannot do this".
            return RPCServiceError(
                code: "host_unverifiable",
                message: "Whether \(hostLabel) can carry a supervised dispatch is "
                    + "unverifiable — \(reason). Loss of contact is not evidence that "
                    + "anything on \(hostLabel) is missing or stopped; nothing was created.",
                data: .object([
                    "hostId": hostId.map(JSONValue.string) ?? .null,
                    "worktreeId": .string(worktreeID),
                    "reason": .string("host_unverifiable"),
                    "detail": .string(reason),
                ]))
        case .refused(let code, let rawDetail):
            let detail = rawDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            return RPCServiceError(
                code: "remote_unsupported",
                message: remoteDispatchRefusal(hostLabel: hostLabel, code: code,
                                               detail: detail, worktreeID: worktreeID,
                                               agent: agent),
                data: .object([
                    "hostId": hostId.map(JSONValue.string) ?? .null,
                    "worktreeId": .string(worktreeID),
                    "reason": .string(code),
                    "detail": .string(detail),
                ]))
        }
    }

    /// The one wording for "that host cannot carry a supervised dispatch".
    ///
    /// It names what the host actually answered, then what does work instead — because
    /// the alternative is real: a remote agent pane with live status is a handoff, not
    /// a dispatch, and a coordinator that knows the difference can still use it.
    static func remoteDispatchRefusal(hostLabel: String, code: String, detail: String,
                                      worktreeID: String, agent: String?) -> String {
        let agentFlag = agent.map { " --engine \($0)" } ?? " --engine <agent>"
        let cause: String
        switch code {
        case RemoteDispatchProbe.cliMissing:
            cause = "the orchard CLI this runtime hands its panes is not runnable there, "
                + "so a worker could not send worker_done, heartbeat, or answer a "
                + "blocking question (\(detail))"
        case RemoteDispatchProbe.runtimeUnreachable:
            cause = "its orchard CLI cannot reach this runtime's control plane, so a "
                + "worker's lifecycle calls would go nowhere (\(detail))"
        case RemoteDispatchProbe.runtimeMismatch:
            cause = "its orchard CLI reaches a different runtime, and a worker_done sent "
                + "there would settle somebody else's dispatch (\(detail))"
        case RemoteDispatchProbe.notWired:
            cause = "this runtime cannot reach it (\(detail))"
        default:
            cause = detail
        }
        return "Supervised dispatch cannot run on \(hostLabel): \(cause). Open a "
            + "handoff-style remote agent pane instead — `terminal create --worktree "
            + "\(worktreeID)\(agentFlag)` — which runs the agent there with live status "
            + "but no dispatch lifecycle."
    }
}
