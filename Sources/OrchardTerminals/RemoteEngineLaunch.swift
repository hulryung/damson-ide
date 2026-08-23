import Foundation

/// How one engine is launched on a host that is not this one (SSH stage 3,
/// docs/design/remote-hosts.md §6).
///
/// `launchArgv` cannot answer this question. It resolves an *absolute path on this
/// machine* (`~/.claude/local/claude`, `/opt/homebrew/bin/codex`) because a GUI launch
/// has a minimal PATH — and that path is meaningless on the far side. Sending it over
/// would fail with "no such file", or worse find a same-named binary that is not the
/// agent. A remote launch therefore names the *command* and lets the remote login shell
/// resolve it, exactly as the user would if they typed it there themselves.
///
/// `nil` on an engine means Orchard does not know how to run it remotely, and the
/// launch is refused typed rather than approximated (a refusal a coordinator can read
/// is better than an agent silently started on the wrong machine).
public struct RemoteEngineLaunch: Equatable, Sendable {
    /// The command to exec on the far side, PATH-resolved *there*.
    public let command: String
    /// Arguments following the command.
    public let arguments: [String]
    /// Environment variables the remote shell must drop before it execs the agent.
    ///
    /// The same reason the local spawn strips them (`AgentEngine.env`): a marker that
    /// says "you are a child of an existing session" changes how the CLI behaves, most
    /// visibly by turning transcript saving off. Locally the markers arrive by process
    /// inheritance; remotely they can still arrive — through a `SendEnv`/`AcceptEnv`
    /// pair in the user's own SSH config, or from the remote account's own shell rc —
    /// so the remote command line unsets them itself instead of assuming the boundary
    /// cleaned up after us.
    public let strippedEnvironment: [String]

    public init(command: String, arguments: [String] = [],
                strippedEnvironment: [String] = []) {
        self.command = command
        self.arguments = arguments
        self.strippedEnvironment = strippedEnvironment
    }
}
