import Foundation
import OrchardTerminals

/// What the owning host said when asked about a remote pane's process.
///
/// These are the host's words, not a conclusion. Turning them into a verdict is
/// `HostLiveness.verdict(forRemoteProcess:)`'s job, and it is kept separate so the
/// mapping from "the host said X" to "the vocabulary says Y" sits in one readable
/// place rather than being spread through a parser.
public enum RemoteProcessAnswer: Equatable, Sendable {
    /// The pid is running and it is still the process we launched.
    case live(pid: Int32)
    /// The host looked for the pid and there is no such process.
    case exited(pid: Int32)
    /// The pid exists but its start time no longer matches the one recorded at
    /// launch: the number was reused, so the process we launched is gone. Positive
    /// evidence of absence — and the reason a bare `kill -0` would not have been
    /// good enough.
    case pidReused(pid: Int32)
    /// The host answered, but it has no identity recorded for this pane. Not a
    /// death: nobody ever wrote down what to look for.
    case noRecord(reason: String)
    /// Contact was lost, or the answer could not be read.
    case unverifiable(reason: String)
    /// The host holds a record for this pane, but written by a *later* connection than
    /// the one being asked about. Refused, not answered: the pid it would report belongs
    /// to a process the caller has never seen, and handing it back would present a
    /// relaunch as the same span of work.
    case superseded(asked: String, found: String)
}

/// The far-side identity of one remote pane's process.
///
/// A remote pane's PTY child is `ssh`, and its exit status is OpenSSH's, so nothing on
/// this side has ever been able to say whether the *remote* process is running. What
/// makes that answerable is one small fact written on the far side at launch: the pid
/// the pane's command is about to become, and when that pid started.
///
/// Both halves are needed. A pid alone is a trap — pid numbers are reused, and on a
/// busy host "pid 41207 exists" can easily be some unrelated process minutes later,
/// which would report a dead agent as `live`. The recorded start time is compared as an
/// opaque string produced by the same `ps` invocation on the same host, so its format
/// never has to be parsed or normalised; it only has to be stable, which it is.
///
/// The record is written by the pane's own shell immediately before it `exec`s, so
/// `$$` is already the pid the remote command will run under: `exec` replaces the
/// process without changing its pid, twice over for an agent pane (`exec $SHELL -lc`,
/// then `exec <agent>`). The whole write is wrapped so it cannot break the launch —
/// a host where it fails simply has no record, and its panes read `unverifiable`
/// rather than the pane failing to open.
public enum RemotePaneIdentity {
    /// Far-side directory holding one small file per pane. Under `$HOME` because that
    /// is the one directory a remote login is guaranteed to own.
    public static let remoteDirectory = "$HOME/.orchard/panes"
    /// How long a record survives on the far side before a later launch prunes it.
    public static let pruneDays = 7

    /// Tokens name a file on someone else's filesystem, so the vocabulary is the
    /// narrowest one that still cannot collide: lowercase hex.
    public static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 64
            && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public static func mintToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
    }

    /// The shell fragment a remote launch runs *before* it `cd`s and `exec`s.
    ///
    /// Everything about it is defensive. It runs in a group whose output and status are
    /// both discarded (`>/dev/null 2>&1 || true`), so a read-only `$HOME`, a full disk
    /// or a host with no `ps` costs the pane nothing. It ends with `;` rather than
    /// `&&`, so the launch that follows is not conditional on it. And it is inline
    /// rather than wrapped in a subshell, because `$$` in a subshell is still the
    /// parent's pid but the record must be written by the process that will *become*
    /// the remote command.
    public static func recordPrelude(token: String, generation: String) -> String {
        precondition(isValidToken(token), "remote pane identity token must be lowercase hex")
        precondition(RemotePaneGeneration.isValidLabel(generation),
                     "remote pane generation must be host#sequence.epoch")
        let start = RemotePaneIdentity.startMarkerCommand
        var script = "{ __opd=\"$HOME/.orchard/panes\"; "
        script += "\(RemotePaneGeneration.marker)\"\(generation)\"; "
        script += "mkdir -p \"$__opd\" && "
        script += "printf \"%s\\t%s\\t%s\\n\" \"$$\" \"$(\(start))\" \"$__opg\" "
        script += "> \"$__opd/\(token).pane\"; "
        script += "find \"$__opd\" -name \"*.pane\" -mtime +\(pruneDays) -delete; "
        script += "} >/dev/null 2>&1 || true; "
        return script
    }

    /// The one `ps` invocation both halves use. Written once so the recorded value and
    /// the value it is later compared against are produced by literally the same
    /// command — the comparison never has to understand the format, only that it does
    /// not change.
    static let startMarkerCommand = "ps -o lstart= -p $$ 2>/dev/null | tr -s ' '"

    /// The bounded question: does the host still have this pane's process?
    ///
    /// Written as POSIX `sh` so it runs on whatever the far side is, and it answers on
    /// a single ASCII line so parsing cannot be confused by a login banner or a locale.
    /// It always exits 0 — the *answer* is the line, not the status, which keeps a
    /// "no such pane" from being mistaken for a transport failure.
    public static func queryScript(token: String) -> String {
        precondition(isValidToken(token), "remote pane identity token must be lowercase hex")
        return """
        f="$HOME/.orchard/panes/\(token).pane"
        if [ ! -r "$f" ]; then printf 'ORCHARD-PANE/1 no-record -\\n'; exit 0; fi
        p=`cut -f1 "$f" 2>/dev/null`
        m=`cut -f2 "$f" 2>/dev/null`
        g=`cut -f3 "$f" 2>/dev/null`
        if [ -z "$g" ]; then g=-; fi
        case "$p" in ''|*[!0-9]*) printf 'ORCHARD-PANE/1 no-record %s\\n' "$g"; exit 0;; esac
        n=`ps -o lstart= -p "$p" 2>/dev/null | tr -s ' '`  # same command as the record
        if [ -z "$n" ]; then printf 'ORCHARD-PANE/1 exited %s %s\\n' "$g" "$p"; exit 0; fi
        if [ -n "$m" ] && [ "$n" != "$m" ]; then printf 'ORCHARD-PANE/1 reused %s %s\\n' "$g" "$p"; exit 0; fi
        printf 'ORCHARD-PANE/1 live %s %s\\n' "$g" "$p"
        """
    }

    /// Read the one line back: `ORCHARD-PANE/1 <verdict> <generation> [pid]`.
    ///
    /// The generation is checked *before* the verdict is believed. If the record was
    /// written by a connection later than the one asked about, no verdict from it is
    /// usable — the process it describes is not the process the question was about.
    /// Anything unrecognised is `unverifiable`: a garbled answer is not an answer, and
    /// guessing which of three words it meant to be is exactly the guess this whole
    /// vocabulary exists to prevent.
    public static func parse(_ stdout: String, expecting generation: String? = nil)
        -> RemoteProcessAnswer {
        guard let line = stdout.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("ORCHARD-PANE/1") }) else {
            return .unverifiable(reason: "the host answered without the pane-identity "
                + "protocol header, so what it said cannot be read")
        }
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count >= 2 else {
            return .unverifiable(reason: "the host's pane-identity answer carried no verdict")
        }
        let found = fields.count >= 3 ? fields[2] : "-"
        if let generation, found != "-", found != generation {
            return .superseded(asked: generation, found: found)
        }
        let pid = fields.count >= 4 ? Int32(fields[3]) : nil
        switch fields[1] {
        case "live":
            guard let pid else {
                return .unverifiable(reason: "the host reported a running process without a pid")
            }
            return .live(pid: pid)
        case "exited":
            guard let pid else {
                return .unverifiable(reason: "the host reported an absent process without a pid")
            }
            return .exited(pid: pid)
        case "reused":
            guard let pid else {
                return .unverifiable(reason: "the host reported a reused pid without a pid")
            }
            return .pidReused(pid: pid)
        case "no-record":
            return .noRecord(reason: "this pane has no identity recorded on the host, so "
                + "there is nothing there to ask about")
        default:
            return .unverifiable(reason: "the host answered '\(fields[1])', which is not a "
                + "pane-identity verdict")
        }
    }
}

/// One pane's liveness, as answered by the machine that owns the process.
public struct RemoteProcessLivenessReport: Sendable, Equatable {
    public let host: String
    public let paneKey: String
    public let verdict: HostLivenessVerdict
    public let answer: RemoteProcessAnswer
    public let pid: Int32?
    /// The pane connection generation this answer is *about* — the span of contact
    /// the question named.
    public let generation: String?
    /// The durable host-connection generation that carried the question, when there was
    /// one. Recorded because an answer is only as current as the span of contact that
    /// carried it.
    public let connectionGeneration: String?
    /// One sentence for a human, already verdict-safe.
    public let note: String

    public var status: String { verdict.status }
}

/// Asks a host whether a remote pane's process is still running.
///
/// This is the producer `HostLiveness.live` never had. Every earlier path could only
/// observe this side of the connection, and this side is `ssh` — so `live` stayed a
/// defined word with nothing entitled to say it. Here the question goes to the machine
/// that owns the process, about an identity that machine itself recorded, and the three
/// answers map onto the three words without any inference in between.
public struct RemoteProcessLiveness: Sendable {
    private let runner: SSHRunner

    /// Tight: this is a `cut` and a `ps`. A host that cannot answer that quickly is one
    /// whose answer we do without, and `unverifiable` is a fine thing to say quickly.
    public static let defaultTimeout: TimeInterval = 10

    public init(runner: SSHRunner) {
        self.runner = runner
    }

    public init(host: HostRecord, runner: HostCommandRunner = ProcessHostCommandRunner(),
                connection: RemoteConnection? = nil,
                timeout: TimeInterval = RemoteProcessLiveness.defaultTimeout) {
        self.init(runner: SSHRunner(host: host, runner: runner, timeout: timeout,
                                    connection: connection))
    }

    /// Ask, and report. `paneKey` is only used for copy; the far side is addressed by
    /// the pane's identity token, which is the name that exists over there.
    public func report(paneKey: String, token: String?,
                       paneGeneration: String? = nil) async -> RemoteProcessLivenessReport {
        let hostName = runner.hostName
        guard let token, RemotePaneIdentity.isValidToken(token) else {
            let answer = RemoteProcessAnswer.noRecord(
                reason: "this pane was opened without a remote identity, so \(hostName) "
                    + "was never told which process to answer for")
            return report(paneKey: paneKey, answer: answer, generation: paneGeneration,
                          over: nil)
        }
        let script = RemotePaneIdentity.queryScript(token: token)
        let (outcome, connectionGeneration) = await runner.runReporting(
            SSHRunner.commandLine(["sh", "-c", script]))
        switch outcome {
        case .unverifiable(let reason):
            return report(paneKey: paneKey,
                          answer: .unverifiable(reason: reason),
                          generation: paneGeneration,
                          over: connectionGeneration?.label)
        case .answered(let code, let stdout, let stderr):
            guard code == 0 else {
                let detail = SSHRunner.firstLine(stderr) ?? "the check exited \(code)"
                return report(paneKey: paneKey,
                              answer: .unverifiable(
                                reason: "\(hostName) could not run the pane check: \(detail)"),
                              generation: paneGeneration,
                              over: connectionGeneration?.label)
            }
            return report(paneKey: paneKey,
                          answer: RemotePaneIdentity.parse(stdout, expecting: paneGeneration),
                          generation: paneGeneration,
                          over: connectionGeneration?.label)
        }
    }

    private func report(paneKey: String, answer: RemoteProcessAnswer,
                        generation: String?, over connection: String?)
        -> RemoteProcessLivenessReport {
        let hostName = runner.hostName
        let verdict = HostLiveness.verdict(forRemoteProcess: answer)
        let pid: Int32?
        switch answer {
        case .live(let value), .exited(let value), .pidReused(let value): pid = value
        case .noRecord, .unverifiable, .superseded: pid = nil
        }
        return RemoteProcessLivenessReport(
            host: hostName, paneKey: paneKey, verdict: verdict, answer: answer, pid: pid,
            generation: generation, connectionGeneration: connection,
            note: Self.describe(host: hostName, answer: answer))
    }

    /// The one sentence every surface uses. `exited` is allowed to be definite here
    /// precisely because it came from the host; everything else is not.
    public static func describe(host: String, answer: RemoteProcessAnswer) -> String {
        switch answer {
        case .live(let pid):
            return "\(host) confirms process \(pid) is running."
        case .exited(let pid):
            return "\(host) reports process \(pid) is gone."
        case .pidReused(let pid):
            return "\(host) reports pid \(pid) now belongs to a different process, so the "
                + "one this pane started is gone."
        case .noRecord(let reason):
            return "Unverifiable — \(reason). \(HostLiveness.lossOfContactReminder(host: host))"
        case .unverifiable(let reason):
            return "Unverifiable — \(reason). \(HostLiveness.lossOfContactReminder(host: host))"
        case .superseded(let asked, let found):
            return "Refused: \(host) holds this pane under generation \(found), not "
                + "\(asked). The process it would report belongs to a later connection, "
                + "so it is not an answer about \(asked). "
                + "\(HostLiveness.generationRefusalReminder)"
        }
    }
}
