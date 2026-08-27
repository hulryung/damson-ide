import Foundation
import OrchardTerminals

/// Opens a pane whose work happens on another machine.
///
/// Two doors need one and they must not drift: `terminal create --worktree <remote id>`
/// (T29/T32/T39) and, since T80, `worker-start`'s `terminal_create` stage when the
/// dispatch's workspace is remote. Before this existed the worker path called
/// `TerminalService.create` with the default `executionHostId: "local"`, which would
/// have opened a *local* PTY sitting in a path that only exists on the far side — rule
/// 1's forbidden downgrade (docs/design/remote-hosts.md §1), and the exact mistake that
/// runs work on the wrong machine.
///
/// The pane is still a local PTY whose child is `ssh`; what this type owns is the
/// difference between a shell pane (`cd <remote path> && exec login shell`) and an
/// agent pane (`RemoteAgentService` — remote launch plus the hook reverse tunnel).
public struct RemotePaneLauncher: Sendable {
    private let service: TerminalService
    private let hosts: HostRegistry
    /// The local end of the hook channel, so an agent pane's reverse forward has a port
    /// to point at. nil means "no channel" — the agent pane still opens and says it is
    /// fingerprint-only rather than claiming a status nothing will confirm.
    private let localHookPort: @Sendable () -> UInt16
    /// Injected so tests can drive the remote agent path with a scripted `ssh`.
    private let hostRunner: HostCommandRunner

    public init(service: TerminalService,
                hosts: HostRegistry,
                localHookPort: @escaping @Sendable () -> UInt16 = { 0 },
                hostRunner: HostCommandRunner = ProcessHostCommandRunner()) {
        self.service = service
        self.hosts = hosts
        self.localHookPort = localHookPort
        self.hostRunner = hostRunner
    }

    /// Which host a pane in this workspace belongs to, given what the caller asked for.
    ///
    /// Returns nil when the pane is local. An unparseable workspace stamp is refused,
    /// never read as local: that downgrade is exactly how a pane ends up local while
    /// claiming remote files (docs/design/remote-hosts.md §1, rule 1).
    public static func resolveHost(workspaceID: String, workspaceStamp: String?,
                                   requested: ExecutionHostId) throws -> ExecutionHostId? {
        guard let stamp = workspaceStamp, !stamp.isEmpty,
              stamp != ExecutionHostId.local.rawValue else {
            return requested.isLocal ? nil : requested
        }
        guard let workspaceHost = ExecutionHostId(rawValue: stamp) else {
            throw TerminalServiceError.invalidArgument(
                "worktree \(workspaceID) has an unusable execution host '\(stamp)'")
        }
        if requested.isLocal { return workspaceHost }
        guard requested == workspaceHost else {
            throw TerminalServiceError.invalidArgument(
                "worktree \(workspaceID) lives on \(workspaceHost.rawValue), "
                    + "not \(requested.rawValue)")
        }
        return workspaceHost
    }

    /// Open the pane. `path` is the directory **on the far side**; the local PTY's own
    /// cwd is deliberately left alone, because a remote path handed to a local `chdir`
    /// either fails or — worse — finds a same-named local directory.
    public func create(engineID: String, host: ExecutionHostId, workspaceID: String,
                       path: String, title: String?,
                       prompt: String = "") async throws -> TerminalSummary {
        let record = try hosts.require(host: host)
        let paneTitle = title
            ?? (path.split(separator: "/").last.map(String.init) ?? record.name)
        // The pane's own identity on the far side, and the name of the connection it is
        // about to open. Both are minted here, before anything runs, because both have
        // to be inside the remote command line the pane launches with.
        let identityToken = RemotePaneIdentity.mintToken()
        let generation = RemotePaneGeneration.mint(executionHostId: host.rawValue,
                                                   incarnation: 1)
        guard engineID == "shell" else {
            return try await createAgent(engineID: engineID, hostRecord: record,
                                         host: host, workspaceID: workspaceID,
                                         path: path, title: paneTitle,
                                         identityToken: identityToken,
                                         generation: generation)
        }
        let remoteCommand = prompt.isEmpty
            ? SSHCommand.cdAndLoginShellCommand(directory: path, identityToken: identityToken,
                                                generation: generation)
            : SSHCommand.prelude(identityToken, generation)
                + "cd \(SSHCommand.shellQuote(path)) && \(prompt)"
        return try await service.create(
            worktreeId: workspaceID,
            cwd: nil,
            engineID: "shell",
            prompt: SSHCommand.remoteShellCommandLine(for: record, command: remoteCommand),
            title: paneTitle,
            executionHostId: host.rawValue,
            // Where the work is, recorded separately from the local `cwd` the pane
            // deliberately does not have: a restored or reconnected pane has to be able
            // to say which directory on which machine it is.
            remoteCwd: path,
            remoteIdentityToken: identityToken,
            remoteGeneration: generation)
    }

    /// An agent pane whose agent runs on `hostRecord`, in the remote worktree at `path`
    /// (docs/design/remote-hosts.md stage 3).
    ///
    /// The hook token is minted here, before the PTY exists, because the remote config
    /// has to carry it and Claude Code reads that config at startup.
    private func createAgent(engineID: String, hostRecord: HostRecord,
                             host: ExecutionHostId, workspaceID: String,
                             path: String, title: String,
                             identityToken: String?,
                             generation: String?) async throws -> TerminalSummary {
        guard let engine = AgentEngineRegistry.engine(id: engineID) else {
            throw TerminalServiceError.unknownEngine(engineID)
        }
        let remote = RemoteAgentService(host: hostRecord, runner: hostRunner)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let plan = try await remote.plan(
            engine: engine, worktreePath: path, hookToken: token,
            localHookPort: localHookPort(),
            identityToken: identityToken,
            generation: generation)
        return try await service.create(
            worktreeId: workspaceID,
            cwd: nil,
            engineID: engine.id,
            // Empty, and it must be: for a `.typeWhenIdle` engine the prompt is what
            // gets *typed into the agent* on its first idle, and typing an `ssh`
            // command line into Claude Code is not a launch, it is a message. The
            // invocation lives in `launchArgv` instead, which a respawn carries.
            prompt: "",
            title: title,
            executionHostId: host.rawValue,
            launchArgv: plan.argv,
            hookToken: plan.hookToken,
            statusDetection: plan.detection,
            remoteCwd: path,
            remoteIdentityToken: plan.identityToken,
            remoteGeneration: generation)
    }
}

