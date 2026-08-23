import Foundation

/// Picks the remote listen port for the SSH reverse tunnel that carries a remote
/// agent's lifecycle hooks back to this machine's `HookServer` (docs/design/
/// remote-hosts.md stage 3).
///
/// The whole problem is ordering. Claude Code reads `.claude/settings.local.json` from
/// its cwd *at startup*, and that file has to name the port its `curl` hooks POST to.
/// So the port must be known before the agent launches — but the tunnel that provides
/// it is created by the same `ssh` that launches the agent. The planner breaks the
/// circle by claiming a port in a separate, bounded round trip first.
///
/// Two ways to claim one, in this order:
///
/// 1. **A fixed candidate range** (`defaultCandidatePorts`), asked for explicitly.
///    Preferred because these ports sit *outside* the ephemeral range, so the window
///    between "it was free during the probe" and "the pane's own ssh asks for it" is
///    very unlikely to be lost to an unrelated connection.
/// 2. **Dynamic allocation** (`-R 0:…`), where sshd picks and OpenSSH prints the choice.
///    The fallback for a host whose whole candidate range is busy. It hands back an
///    ephemeral port, which is exactly the port space most likely to be reused, so it
///    is second rather than first.
///
/// Either way the claim is advisory, and deliberately so: the pane's real `ssh` does
/// **not** pass `ExitOnForwardFailure`. If the port is gone by then, OpenSSH warns and
/// carries on, the agent still runs, and the pane degrades to fingerprint-only status.
/// The alternative — killing a working agent because Orchard could not watch it — trades
/// the work for the telemetry.
public enum RemoteHookTunnel {
    /// How the remote listen port was obtained.
    public enum Mode: String, Equatable, Sendable {
        case fixedRange = "fixed-range"
        case dynamic
    }

    public struct Plan: Equatable, Sendable {
        public let remotePort: UInt16
        public let localPort: UInt16
        public let mode: Mode

        public init(remotePort: UInt16, localPort: UInt16, mode: Mode) {
            self.remotePort = remotePort
            self.localPort = localPort
            self.mode = mode
        }

        /// The `-R` arguments this plan contributes to the pane's `ssh` argv.
        public var tunnelArguments: [String] {
            SSHCommand.reverseTunnelArguments(remotePort: remotePort, localPort: localPort)
        }
    }

    public enum Outcome: Equatable, Sendable {
        case established(Plan)
        /// No tunnel. The reason is one clause, written to be pasted into the pane's
        /// recorded limitation.
        case unavailable(reason: String)
    }

    /// Candidate remote listen ports, tried in order.
    ///
    /// Above the well-known range and below the ephemeral range Linux and macOS hand
    /// out by default, so a candidate is only ever busy because another Orchard agent
    /// (or a deliberate service) holds it. Eight is a bound, not a capacity limit: a
    /// ninth concurrent remote agent on one host falls through to dynamic allocation
    /// rather than making an unbounded number of round trips looking for a gap.
    public static let defaultCandidatePorts: [UInt16] = [
        47110, 47111, 47112, 47113, 47114, 47115, 47116, 47117,
    ]

    /// Ceiling on the *whole* claim, not just one attempt.
    ///
    /// Bounded twice, like the connectivity probe (design §3), because either bound
    /// alone can be defeated: the runner's own timeout bounds one round trip, and this
    /// bounds their sum. Without it a host that answers slowly turns an interactive
    /// `terminal create` into a multi-minute hang — and the thing being waited on is
    /// only *telemetry*, whose absence is already a supported outcome.
    public static let defaultDeadline: TimeInterval = 20

    /// Claim a remote port for `localPort`'s hook server.
    ///
    /// Each attempt is one bounded `ssh … -o ExitOnForwardFailure=yes -R <p>:… true`:
    /// `ExitOnForwardFailure` is what turns a refused forward into a status we can
    /// read, and `true` is what makes the attempt cost one round trip rather than
    /// holding a connection open. A transport failure stops the walk immediately —
    /// a host that cannot be reached will not become reachable on port 47111.
    public static func plan(runner: SSHRunner, localPort: UInt16,
                            candidates: [UInt16] = defaultCandidatePorts,
                            deadline: TimeInterval = defaultDeadline) async -> Outcome {
        guard localPort != 0 else {
            return .unavailable(reason: "the local hook server is not listening")
        }
        let startedAt = Date()
        var sawBusyPort = false
        for candidate in candidates {
            guard Date().timeIntervalSince(startedAt) < deadline else {
                return .unavailable(reason: "no forward port could be claimed on "
                                        + "\(runner.hostName) within \(Int(deadline))s")
            }
            let result = await claim(runner: runner, remotePort: candidate, localPort: localPort)
            switch result {
            case .claimed(let port):
                return .established(Plan(remotePort: port, localPort: localPort,
                                         mode: .fixedRange))
            case .portBusy:
                sawBusyPort = true
                continue
            case .refused(let reason):
                return .unavailable(reason: reason)
            }
        }
        guard Date().timeIntervalSince(startedAt) < deadline else {
            return .unavailable(reason: "no forward port could be claimed on "
                                    + "\(runner.hostName) within \(Int(deadline))s")
        }
        // Every candidate was taken (or the list was empty). Let sshd choose.
        switch await claim(runner: runner, remotePort: 0, localPort: localPort) {
        case .claimed(let port):
            return .established(Plan(remotePort: port, localPort: localPort, mode: .dynamic))
        case .portBusy:
            return .unavailable(reason: "\(runner.hostName) refused every candidate "
                                    + "port and would not allocate one")
        case .refused(let reason):
            return .unavailable(reason: sawBusyPort
                                ? "\(reason) (after every candidate port was in use)"
                                : reason)
        }
    }

    private enum ClaimResult {
        case claimed(UInt16)
        /// sshd would not bind that specific port — a *reachable* host saying no.
        case portBusy
        case refused(reason: String)
    }

    private static func claim(runner: SSHRunner, remotePort: UInt16,
                              localPort: UInt16) async -> ClaimResult {
        let options = ["-o", "ExitOnForwardFailure=yes"]
            + SSHCommand.reverseTunnelArguments(remotePort: remotePort, localPort: localPort)
        let result = await runner.runRaw("true", options: options)
        let text = result.stderr + "\n" + result.stdout
        // Checked before the status: with ExitOnForwardFailure the refusal is fatal, so
        // it arrives as 255 — the same status a dead transport uses. The message is the
        // only thing that separates "port taken" from "host gone".
        if isForwardFailure(text) { return .portBusy }
        guard result.exitCode == 0 else {
            switch SSHRunner.classify(result, host: runner.host) {
            case .unverifiable(let reason):
                return .refused(reason: reason)
            case .answered(let code, _, let stderr):
                let detail = SSHRunner.firstLine(stderr) ?? "exit \(code)"
                return .refused(reason: detail)
            }
        }
        if remotePort != 0 { return .claimed(remotePort) }
        guard let allocated = parseAllocatedPort(text) else {
            return .refused(reason: "\(runner.hostName) allocated a forward port but "
                                + "OpenSSH did not report which one")
        }
        return .claimed(allocated)
    }

    /// OpenSSH's own words for a refused remote forward:
    /// `Warning: remote port forwarding failed for listen port 47110` (or `Error:` when
    /// `ExitOnForwardFailure` makes it fatal). Matched on the shared clause so both
    /// spellings — and any future prefix — land here.
    public static func isForwardFailure(_ text: String) -> Bool {
        text.lowercased().contains("remote port forwarding failed")
    }

    /// The port from `Allocated port 39735 for remote forward to 127.0.0.1:8080`, which
    /// OpenSSH logs when a `-R 0:` forward is granted. nil when the line is absent —
    /// never a guess, because a guessed port is a hook config that silently POSTs into
    /// nothing.
    public static func parseAllocatedPort(_ text: String) -> UInt16? {
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "Allocated port ") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            guard !digits.isEmpty, let port = UInt16(digits), port != 0 else { continue }
            // The message names *which* forward, and a client can have several.
            guard line[range.upperBound...].contains("remote forward") else { continue }
            return port
        }
        return nil
    }
}
