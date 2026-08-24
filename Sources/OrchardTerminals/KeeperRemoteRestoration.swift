import Foundation

/// The decisions a boot has to make about a *remote* pane it is adopting back
/// (docs/design/remote-hosts.md stage 4).
///
/// A remote pane's PTY is local — its child is the `ssh` client — so the keeper keeps
/// it alive across a restart exactly like any other pane. What does not survive by
/// itself is everything the connection was wired to on *this* side:
///
/// - the pane's **identity** (`ssh:<name>`, the remote directory, the invocation that
///   would reopen the connection). Re-registering an adopted `ssh` pane without its
///   stamp reads as local, which is the one answer rule 1 forbids guessing;
/// - its **status channel**. The surviving `ssh` still forwards
///   `-R <remote>:127.0.0.1:<local>` to the port number the *previous* app instance's
///   hook server bound. Nothing can move that forward — the child is not ours to
///   reconfigure — so the only way to keep receiving this agent's hooks is to bind
///   that same local port again. When something else already holds it, the pane is not
///   broken and must not be closed: it degrades to fingerprint-only detection and says
///   so in words, exactly like a tunnel that never got claimed (T39).
///
/// Everything here is pure: it decides from the record and one number (the port the
/// hook server actually bound), so the whole rebind-vs-degrade fork is testable
/// without a socket, a keeper, or a host.
public enum KeeperRemoteRestoration {

    // MARK: - Hook channel: rebind or degrade

    /// What happened to the pane's hook channel across the restart.
    public enum HookChannel: Equatable, Sendable {
        /// A local pane — it never had a tunnel to lose.
        case notRemote
        /// A remote pane that already had no hook channel at handoff (no tunnel could
        /// be claimed, the config could not be written, or the engine has no hooks).
        case noneRecorded
        /// The surviving connection's local port was bound again: the far side's
        /// already-installed hook config keeps landing here.
        case rebound(localPort: UInt16)
        /// The port could not be bound again. The agent keeps running and the pane
        /// keeps working; only the telemetry is lost.
        case degraded(reason: String)
    }

    public struct Resolution: Equatable, Sendable {
        /// What the adopted pane's summary should carry. nil means "the default for
        /// this engine", which is what a local pane gets.
        public let detection: TerminalStatusDetection?
        public let channel: HookChannel

        public init(detection: TerminalStatusDetection?, channel: HookChannel) {
            self.detection = detection
            self.channel = channel
        }
    }

    /// Decide what an adopted pane can still read its status from.
    ///
    /// `boundLocalPort` is the port this app instance's hook server actually bound (0
    /// when it never bound one). It is compared against the *recorded* local port
    /// rather than merely being non-zero, because a hook server listening on a
    /// different port is not a channel for this pane: the surviving `ssh` forwards to
    /// the old number and nothing reaches the new one.
    public static func resolve(pane: KeeperPaneRecord, boundLocalPort: UInt16) -> Resolution {
        guard let remote = pane.remote else {
            return Resolution(detection: nil, channel: .notRemote)
        }
        guard let tunnel = remote.tunnel else {
            // Already fingerprint-only at handoff: keep the sentence it was created
            // with rather than inventing a restart-flavoured one for a limitation the
            // restart did not cause.
            return Resolution(detection: remote.statusDetection, channel: .noneRecorded)
        }
        guard boundLocalPort != 0 else {
            return degrade(remote: remote, tunnel: tunnel, reason:
                "Orchard's hook server is not listening after the restart, so the "
                    + "connection that is still open to \(hostLabel(remote.executionHostId)) "
                    + "has nowhere to deliver this agent's hook events")
        }
        guard boundLocalPort == tunnel.localPort else {
            return degrade(remote: remote, tunnel: tunnel, reason:
                "port \(tunnel.localPort) — which the still-open connection to "
                    + "\(hostLabel(remote.executionHostId)) forwards this agent's hook "
                    + "events to — was taken during the restart, so they now arrive "
                    + "nowhere (Orchard listens on \(boundLocalPort) instead)")
        }
        return Resolution(detection: .hooks(tunnelPort: Int(tunnel.remotePort)),
                          channel: .rebound(localPort: tunnel.localPort))
    }

    private static func degrade(remote: KeeperRemotePaneRecord, tunnel: KeeperTunnelRecord,
                                reason: String) -> Resolution {
        // Same shape as T39's launch-time degradation, and deliberately the same
        // consequence sentence: a pane with no channel must never present a
        // fingerprint guess with the confidence of a hook-attested fact.
        let limitation = "\(reason.prefix(1).uppercased() + reason.dropFirst()). This "
            + "pane's status comes from screen fingerprints only, so an idle reading is "
            + "a guess from the screen, not the agent's own report. Reconnect to give it "
            + "a fresh hook channel."
        return Resolution(detection: .fingerprintOnly(limitation),
                          channel: .degraded(reason: reason))
    }

    // MARK: - Reconnect

    /// How to reopen a remote pane's connection: what to run, and what the pane will
    /// be able to see once it is running.
    public struct ReconnectPlan: Equatable, Sendable {
        /// Verbatim argv for the new PTY (agent panes). nil for a pane whose launch
        /// lives in its prompt.
        public let launchArgv: [String]?
        /// The `shell` engine's command line (remote shell panes); empty otherwise.
        public let prompt: String
        public let detection: TerminalStatusDetection?
        /// Whether the reopened connection carries a hook tunnel at all.
        public let tunnelled: Bool

        public init(launchArgv: [String]?, prompt: String,
                    detection: TerminalStatusDetection?, tunnelled: Bool) {
            self.launchArgv = launchArgv
            self.prompt = prompt
            self.detection = detection
            self.tunnelled = tunnelled
        }
    }

    /// Build the reconnect from the pane's own recorded spec.
    ///
    /// Three fidelity rules, each of which is a bug if broken:
    ///
    /// 1. **The invocation is the recorded one.** Same host, same remote directory,
    ///    same agent argv. Rebuilding it from anything else is how a reconnect lands
    ///    on a different machine or in a different tree.
    /// 2. **The hook token is not reminted.** It is already written into a config file
    ///    on the far side; a fresh token would reopen the pane as a different,
    ///    statusless agent.
    /// 3. **The tunnel is re-pointed, not replayed.** The recorded `-R` names the port
    ///    the *old* app instance's hook server held. This app's port is a different
    ///    number as often as not, and forwarding to a port nothing listens on is a
    ///    channel that silently swallows every event. With no hook server at all the
    ///    forward is dropped entirely and the pane says it is fingerprint-only —
    ///    never an `-R` into nothing.
    public static func reconnectPlan(spec: TerminalCreateSpec,
                                     boundLocalPort: UInt16) -> ReconnectPlan {
        guard let argv = spec.launchArgv, !argv.isEmpty else {
            // A remote *shell* pane: its launch is the prompt (the `shell` engine's
            // prompt-as-command-line contract), and it has no hook channel to keep.
            return ReconnectPlan(launchArgv: nil, prompt: spec.prompt,
                                 detection: spec.statusDetection, tunnelled: false)
        }
        guard let ports = tunnelPorts(in: argv) else {
            return ReconnectPlan(launchArgv: argv, prompt: spec.prompt,
                                 detection: spec.statusDetection, tunnelled: false)
        }
        guard boundLocalPort != 0 else {
            return ReconnectPlan(
                launchArgv: withoutTunnel(argv), prompt: spec.prompt,
                detection: .fingerprintOnly(
                    "Orchard's hook server is not listening, so the reopened connection "
                        + "to \(hostLabel(spec.executionHostId)) carries no hook channel. "
                        + "This pane's status comes from screen fingerprints only, so an "
                        + "idle reading is a guess from the screen, not the agent's own "
                        + "report."),
                tunnelled: false)
        }
        return ReconnectPlan(
            launchArgv: retargetTunnel(argv: argv, localPort: boundLocalPort),
            prompt: spec.prompt,
            detection: .hooks(tunnelPort: Int(ports.remote)),
            tunnelled: true)
    }

    // MARK: - Reverse-tunnel argv surgery

    /// The `<remote>:127.0.0.1:<local>` forward Orchard itself put in an argv.
    ///
    /// Deliberately strict about the shape: only the loopback form
    /// `SSHCommand.reverseTunnelArguments` builds is recognised. A `-R` a user wrote
    /// into their own SSH config or a future caller added for another purpose is not
    /// ours to rewrite, and misreading one would silently re-point somebody else's
    /// forward at our hook server.
    public static func tunnelPorts(in argv: [String]) -> (remote: UInt16, local: UInt16)? {
        for (index, token) in argv.enumerated() where token == "-R" {
            guard argv.indices.contains(index + 1),
                  let parsed = parseForward(argv[index + 1]) else { continue }
            return parsed
        }
        return nil
    }

    /// Re-point the recorded forward at the port the hook server actually bound.
    public static func retargetTunnel(argv: [String], localPort: UInt16) -> [String] {
        var out = argv
        for (index, token) in argv.enumerated() where token == "-R" {
            guard out.indices.contains(index + 1),
                  let parsed = parseForward(out[index + 1]) else { continue }
            out[index + 1] = "\(parsed.remote):127.0.0.1:\(localPort)"
            return out
        }
        return out
    }

    /// Drop the forward (and its flag) entirely — the launch is otherwise identical,
    /// which is the point: no hook channel must never mean no agent.
    public static func withoutTunnel(_ argv: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < argv.count {
            if argv[index] == "-R", argv.indices.contains(index + 1),
               parseForward(argv[index + 1]) != nil {
                index += 2
                continue
            }
            out.append(argv[index])
            index += 1
        }
        return out
    }

    private static func parseForward(_ value: String) -> (remote: UInt16, local: UInt16)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "127.0.0.1",
              let remote = UInt16(parts[0]), let local = UInt16(parts[2]) else { return nil }
        return (remote, local)
    }

    // MARK: - Naming

    /// What a user-facing sentence calls the host behind a raw id. The registry lives
    /// in the runtime module, so this reads the id's own suffix rather than resolving
    /// a record — the copy needs a name, not a connection.
    public static func hostLabel(_ executionHostId: String) -> String {
        guard executionHostId.hasPrefix("ssh:") else { return executionHostId }
        let name = String(executionHostId.dropFirst("ssh:".count))
        return name.isEmpty ? executionHostId : name
    }
}
