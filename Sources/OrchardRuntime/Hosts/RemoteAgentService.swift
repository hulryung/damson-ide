import Foundation
import OrchardTerminals

/// Everything the terminal layer needs to open one remote agent pane.
public struct RemoteAgentPlan: Sendable {
    /// The local PTY's argv (`/usr/bin/ssh -tt …`). This is what the pane records and
    /// what a respawn re-runs, so the §4 rule — a remote pane keeps its launch command
    /// — is held by the field that actually launches it.
    public let argv: [String]
    /// What the far side execs (`argv`'s last element), kept named so a receipt or a
    /// log can show the remote half on its own.
    public let remoteCommand: String
    /// The hook token written into the remote config, minted before the pane exists.
    public let hookToken: String
    /// What this pane's status can be read from, and what it therefore cannot say.
    public let detection: TerminalStatusDetection
    /// The far-side identity token this launch records its pid under (T89), or nil
    /// when the caller did not ask for one.
    public let identityToken: String?
}

/// Stage 3 of docs/design/remote-hosts.md: an agent CLI running in a worktree on
/// another machine, watched from this one.
///
/// The composition, in the order it has to happen:
///
/// 1. The engine must know how to launch remotely at all (`RemoteEngineLaunch`), or the
///    request is refused typed. There is no approximation — the failure mode this
///    prevents is launching the agent on *this* machine under a remote host's name.
/// 2. Claim a remote port for the reverse tunnel (`RemoteHookTunnel`).
/// 3. Write the hook config *on the far side*, pointing at that port, before the agent
///    starts — Claude Code reads it at startup, so later is never.
/// 4. Build the `ssh` argv that both opens the tunnel and execs the agent.
///
/// Steps 2 and 3 are allowed to fail. Neither one failing stops the launch: the pane
/// opens with `fingerprint-only` detection and carries the limitation in words, because
/// an agent Orchard can see less of beats no agent at all. What is *not* allowed is
/// pretending: a pane with no hook channel never reports itself as hook-attested.
///
/// Whether the resulting pane can also be a *supervised worker* is a separate question,
/// and no longer this type's to assume. It was, once: the far side had no `orchard` CLI
/// and no Orchard identity, so a remote agent could not send `worker_done`, heartbeat or
/// answer a question, and `worker-start` refused every remote placement typed. T78 gave
/// the pane its identity, T80 replaced the assumption with a precondition the host
/// itself answers, and T83 drove a real `claude-code` worker to settlement across this
/// launch path. So a pane built here may be handoff-style *or* supervised; what decides
/// is `RemoteDispatchProbe`, not this file.
public struct RemoteAgentService: Sendable {
    public let runner: SSHRunner
    /// Candidate remote ports for the tunnel; overridable so tests can pin the walk.
    public let candidatePorts: [UInt16]

    /// Ceiling on one preflight round trip.
    ///
    /// Much tighter than `SSHRunner.defaultTimeout` (120 s), which is sized for a
    /// `git worktree add` on a large repo. Everything here is `true`, `cat` and
    /// `printf` — a host that cannot answer those quickly is a host whose telemetry we
    /// do without, and `terminal create` must not sit on a spinner while we find that
    /// out.
    public static let preflightTimeout: TimeInterval = 10

    public init(runner: SSHRunner,
                candidatePorts: [UInt16] = RemoteHookTunnel.defaultCandidatePorts) {
        self.runner = runner
        self.candidatePorts = candidatePorts
    }

    public init(host: HostRecord, runner: HostCommandRunner = ProcessHostCommandRunner(),
                timeout: TimeInterval = RemoteAgentService.preflightTimeout,
                candidatePorts: [UInt16] = RemoteHookTunnel.defaultCandidatePorts) {
        self.init(runner: SSHRunner(host: host, runner: runner, timeout: timeout),
                  candidatePorts: candidatePorts)
    }

    public var host: HostRecord { runner.host }
    public var hostName: String { runner.hostName }

    /// Resolve the engine's remote launch, or refuse typed.
    ///
    /// The refusal names the engine rather than the host: it is Orchard that does not
    /// know how to start this tool remotely, and saying so keeps the user from
    /// debugging their SSH config over a gap that is on our side.
    public static func requireRemoteLaunch(_ engine: AgentEngine,
                                           hostName: String) throws -> RemoteEngineLaunch {
        guard let launch = engine.remoteLaunch else {
            throw RemoteHostError.unsupported(
                "Orchard does not know how to launch '\(engine.id)' on \(hostName); "
                    + "open a remote shell in the worktree instead")
        }
        return launch
    }

    /// Plan one remote agent pane.
    ///
    /// `localHookPort` is this machine's `HookServer` port (0 when it never bound).
    /// `hookToken` is minted by the caller so the pane's `AgentSession` can be created
    /// with the same token the remote config already carries.
    public func plan(engine: AgentEngine, worktreePath: String, hookToken: String,
                     localHookPort: UInt16,
                     identityToken: String? = nil,
                     generation: String? = nil) async throws -> RemoteAgentPlan {
        let launch = try Self.requireRemoteLaunch(engine, hostName: hostName)
        let path = worktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            throw RemoteHostError.invalidArgument(
                "a remote worktree needs an absolute path on \(hostName) (got '\(worktreePath)')")
        }
        let remoteCommand = RemoteAgentLaunch.remoteCommand(directory: path, launch: launch,
                                                            identityToken: identityToken,
                                                            generation: generation)

        let (tunnel, detection) = await resolveHookChannel(
            engine: engine, worktreePath: path, hookToken: hookToken,
            localHookPort: localHookPort)

        return RemoteAgentPlan(
            argv: RemoteAgentLaunch.argv(for: host, remoteCommand: remoteCommand,
                                         tunnel: tunnel),
            remoteCommand: remoteCommand,
            hookToken: hookToken,
            detection: detection,
            identityToken: identityToken)
    }

    /// Claim a port, write the config, and say what the pane ended up with.
    private func resolveHookChannel(
        engine: AgentEngine, worktreePath: String, hookToken: String, localHookPort: UInt16
    ) async -> (RemoteHookTunnel.Plan?, TerminalStatusDetection) {
        guard let events = engine.hookEvents, !events.isEmpty else {
            return (nil, .fingerprintOnly(
                "\(engine.displayName) has no lifecycle-hook mechanism, so this pane's "
                    + "status comes from screen fingerprints only."))
        }
        guard localHookPort != 0 else {
            return (nil, .fingerprintOnly(
                "Orchard's local hook server is not listening, so no hook channel could "
                    + "be tunnelled to \(hostName); this pane's status comes from screen "
                    + "fingerprints only."))
        }
        let tunnel: RemoteHookTunnel.Plan
        switch await RemoteHookTunnel.plan(runner: runner, localPort: localHookPort,
                                           candidates: candidatePorts) {
        case .established(let established):
            tunnel = established
        case .unavailable(let reason):
            return (nil, .fingerprintOnly(
                "No hook tunnel to \(hostName) — \(reason). This pane's status comes from "
                    + "screen fingerprints only, so an idle reading is a guess from the "
                    + "screen, not the agent's own report."))
        }
        do {
            try await RemoteHookConfig(runner: runner).install(
                worktreePath: worktreePath, port: tunnel.remotePort,
                token: hookToken, events: events)
        } catch let error as RemoteHostError {
            // The tunnel would work; the config that uses it does not exist. Reporting
            // hooks here would be the worst answer available: a pane that claims an
            // authoritative channel nothing will ever POST to.
            return (nil, .fingerprintOnly(
                "The agent hook config could not be written on \(hostName) "
                    + "(\(error.code)) — \(error.message) This pane's status comes from "
                    + "screen fingerprints only."))
        } catch {
            return (nil, .fingerprintOnly(
                "The agent hook config could not be written on \(hostName): \(error). "
                    + "This pane's status comes from screen fingerprints only."))
        }
        return (tunnel, .hooks(tunnelPort: Int(tunnel.remotePort)))
    }
}
