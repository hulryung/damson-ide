import Foundation
import OrchardTerminals

/// Builds the two command lines a remote agent pane runs: what the far side executes,
/// and the local `ssh` invocation that gets it there.
///
/// Kept separate from `RemoteAgentService` (which decides *whether* a tunnel exists)
/// because these are pure string construction: they are the part a test can pin exactly,
/// and the part a human can paste into a terminal to check what Orchard would have run.
public enum RemoteAgentLaunch {
    /// `cd '<dir>' && unset <markers…> && exec <command> <args…>`
    ///
    /// Three deliberate pieces:
    ///
    /// - `cd` happens on the far side, never as the local PTY's cwd. A remote path
    ///   handed to a local `chdir` either fails or — worse — finds a same-named local
    ///   directory, which is how an agent ends up editing the wrong machine's files.
    /// - `unset` strips the inherited-session markers before the agent starts. They can
    ///   reach the far side through the user's own `SendEnv`/`AcceptEnv` pair or the
    ///   remote account's shell rc, and an agent that believes it is a subprocess of
    ///   another session quietly turns transcript saving off.
    /// - `exec` so the PTY's remote child *is* the agent: an extra shell layer would
    ///   swallow the exit status that `HostLiveness.verdictForPTYEnd` reads.
    public static func remoteCommand(directory: String, launch: RemoteEngineLaunch) -> String {
        var parts = ["cd \(SSHCommand.shellQuote(directory))"]
        if !launch.strippedEnvironment.isEmpty {
            // `unset` of a variable that is not set succeeds, so this never breaks the
            // chain on a host where none of the markers exist — the common case.
            parts.append("unset " + launch.strippedEnvironment
                .map(SSHCommand.shellQuote).joined(separator: " "))
        }
        let argv = ([launch.command] + launch.arguments).map(SSHCommand.shellQuote)
            .joined(separator: " ")
        parts.append("exec \(argv)")
        return parts.joined(separator: " && ")
    }

    /// The pane's local argv: `ssh -tt [-R …] [-p …] <dest> '<remote command>'`.
    ///
    /// `tunnel` is nil for a pane that degraded to fingerprint-only status — the agent
    /// launches identically, it just has no channel home.
    public static func argv(for host: HostRecord, remoteCommand: String,
                            tunnel: RemoteHookTunnel.Plan?) -> [String] {
        SSHCommand.remoteShellArgv(for: host, command: remoteCommand,
                                   options: tunnel?.tunnelArguments ?? [])
    }
}
