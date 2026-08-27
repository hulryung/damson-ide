import Foundation

/// The one vocabulary Orchard uses to say whether something on a host is still alive.
///
/// `exited` requires positive evidence of absence *from the host that owns the
/// process*. Losing contact with that host — a dropped SSH connection, an unreachable
/// probe, a host that is no longer registered — is `unverifiable`. It is never a death
/// certificate and never a successful stop (docs/research/orca-inventory.md §3
/// "Sessions, sleep, orphans"; rebuild checklist #14; orca
/// `src/shared/pty-liveness-verdict.ts`).
///
/// Why this matters more than it looks: the failure mode it prevents is a coordinator
/// reading a dropped connection as "the worker died", respawning the work, and ending
/// up with two agents editing the same worktree from two machines.
///
/// Host *reachability* (T45, `HostReachability` / `HostLivenessService`) is a different
/// question: a periodic probe publishes reachable|auth-required|unreachable on the
/// host itself. That status never produces a `HostLivenessVerdict` — an unreachable
/// host makes processes `unverifiable`, never `exited`.
public enum HostLivenessVerdict: Equatable, Sendable {
    /// The owning host confirmed the process is running.
    case live
    /// Nobody who can answer for the host was reachable. Not death, not a stop.
    case unverifiable(reason: String)
    /// The owning host confirmed the process is gone.
    case exited

    public var status: String {
        switch self {
        case .live: return "live"
        case .unverifiable: return "unverifiable"
        case .exited: return "exited"
        }
    }

    public var reason: String? {
        if case .unverifiable(let reason) = self { return reason }
        return nil
    }
}

public enum HostLiveness {
    public static let connectionLostReason = "the connection to the host ended before it reported an exit"
    public static let hostUnregisteredReason = "its host is no longer registered"
    public static let hostUnreachableReason = "no reachable connection can observe its host"

    /// OpenSSH's own exit status for a transport-level failure. Any other status came
    /// back *through* a working connection and is the remote command's own.
    public static let sshTransportFailureExitCode: Int32 = 255

    /// The sentence a fenced refusal ends with. It is one sentence and it is verbatim
    /// everywhere, because the temptation it guards against is real: a caller that gets
    /// "generation ended" back is one small edit away from retrying on the new
    /// connection and reporting the result as though nothing had happened.
    public static let generationRefusalReminder =
        "A later connection cannot answer for an earlier one; reopening is a new "
            + "generation, not a continuation."

    /// The rule-2 reminder, parameterised by host. Reused wherever loss of contact has
    /// to be stated without implying anything stopped.
    public static func lossOfContactReminder(host: String) -> String {
        "Loss of contact is not evidence that anything on \(host) stopped."
    }

    /// What a PTY's ending proves about the work that was running in it.
    ///
    /// For a local pane the PTY *is* the process, so an exit status is proof of exit.
    /// For a remote pane the PTY holds `ssh`, not the remote shell: status 255 is
    /// OpenSSH saying its own transport failed, which says nothing about the far side —
    /// that is loss of contact, so `unverifiable`. Any other status was propagated from
    /// the remote command, so it is real evidence of exit.
    public static func verdictForPTYEnd(host: ExecutionHostId, exitCode: Int32?) -> HostLivenessVerdict {
        guard let exitCode else {
            return .unverifiable(reason: connectionLostReason)
        }
        switch host.kind {
        case .local:
            return .exited
        case .ssh:
            return exitCode == sshTransportFailureExitCode
                ? .unverifiable(reason: "the connection to \(host.name) failed before it reported an exit")
                : .exited
        }
    }

    /// The sentence every user-facing surface uses when a remote pane's PTY ends. The
    /// pane is over either way; the difference the copy must carry is whether anything
    /// on the far side is known to have stopped.
    public static func describeConnectionEnd(host: ExecutionHostId, exitCode: Int32?) -> String {
        guard !host.isLocal else {
            return exitCode.map { "The process exited (status \($0))." } ?? "The process exited."
        }
        switch verdictForPTYEnd(host: host, exitCode: exitCode) {
        case .exited:
            let status = exitCode.map { " (status \($0))" } ?? ""
            return "The connection to \(host.name) closed and the remote shell exited\(status)."
        case .unverifiable(let reason):
            return "The connection to \(host.name) ended. Whether anything is still "
                + "running there is unverifiable — \(reason)."
        case .live:
            return "The connection to \(host.name) ended."
        }
    }

    /// What a remote pane's own host said about the process that pane launched
    /// (T89) — the first producer `live` has ever had.
    ///
    /// Every earlier surface could only observe *this* side: a PTY that ended, a probe
    /// that timed out, hooks that stopped arriving. None of those is the owning host
    /// confirming anything, so none of them was allowed to say `live`. This one asks the
    /// host directly, about a process the host itself recorded, and reads its answer:
    ///
    /// - the process is there, and it is still the one we launched → `live`;
    /// - the host looked and there is no such process, or the pid now belongs to
    ///   something else → `exited`, which is the positive evidence of absence the word
    ///   requires;
    /// - the host did not answer, or never recorded an identity for this pane → 
    ///   `unverifiable`. Never `exited`: "we could not look" and "we looked and it is
    ///   gone" are the two facts this vocabulary exists to keep apart.
    public static func verdict(forRemoteProcess answer: RemoteProcessAnswer) -> HostLivenessVerdict {
        switch answer {
        case .live:
            return .live
        case .exited, .pidReused:
            return .exited
        case .noRecord(let reason), .unverifiable(let reason):
            return .unverifiable(reason: reason)
        case .superseded(let asked, let found):
            // A refusal, not a verdict about the process — and `unverifiable` is the
            // only word that can carry "we will not answer this".
            return .unverifiable(reason: "the host holds this pane under generation "
                + "\(found), not \(asked), so nothing it says is about \(asked)")
        }
    }

    /// The sentence for a stop that was issued but never confirmed by the owning host.
    public static func describeUnconfirmedStop(reason: String) -> String {
        "The process was not confirmed stopped: \(reason)."
    }
}
