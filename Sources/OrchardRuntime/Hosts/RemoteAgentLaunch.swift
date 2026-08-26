import Foundation
import OrchardTerminals

/// Builds the two command lines a remote agent pane runs: what the far side executes,
/// and the local `ssh` invocation that gets it there.
///
/// Kept separate from `RemoteAgentService` (which decides *whether* a tunnel exists)
/// because these are pure string construction: they are the part a test can pin exactly,
/// and the part a human can paste into a terminal to check what Orchard would have run.
public enum RemoteAgentLaunch {
    /// `cd '<dir>' && exec "${SHELL:-/bin/sh}" -lc 'unset <markers…>; exec <command> <args…>'`
    ///
    /// Four deliberate pieces:
    ///
    /// - `cd` happens on the far side, never as the local PTY's cwd. A remote path
    ///   handed to a local `chdir` either fails or — worse — finds a same-named local
    ///   directory, which is how an agent ends up editing the wrong machine's files.
    /// - A **login shell** runs the agent, for the same reason `EngineLaunch.argv`
    ///   wraps every local agent spawn in one: the command name has to resolve. `ssh
    ///   host '<command>'` is not a login — sshd runs it through
    ///   `$SHELL -c`, which reads no `.zprofile` / `.zshrc` / `.bash_profile`, so PATH
    ///   is sshd's own default (`/usr/bin:/bin:/usr/sbin:/sbin`). `claude`, `codex` and
    ///   every other agent installed under `~/.local`, homebrew or a version manager is
    ///   invisible there, and the pane dies at spawn with `command not found` (T83,
    ///   found live against `orchard-loopback`). `RemoteEngineLaunch` sends a *command*
    ///   rather than a path precisely so the far side resolves it "as the user would if
    ///   they typed it there themselves" — and this is the shell in which that is true.
    /// - `unset` strips the inherited-session markers immediately before the agent
    ///   starts. They can reach the far side through the user's own `SendEnv`/`AcceptEnv`
    ///   pair or the remote account's shell rc, and an agent that believes it is a
    ///   subprocess of another session quietly turns transcript saving off. It runs
    ///   *inside* the login shell, after those rc files, so an rc that exports one has
    ///   no chance to win.
    /// - `exec` twice, so the PTY's remote child *is* the agent: neither the login shell
    ///   nor an extra wrapper layer survives to swallow the exit status that
    ///   `HostLiveness.verdictForPTYEnd` reads.
    public static func remoteCommand(directory: String, launch: RemoteEngineLaunch) -> String {
        var inner = ""
        if !launch.strippedEnvironment.isEmpty {
            // `unset` of a variable that is not set succeeds, so this never breaks the
            // chain on a host where none of the markers exist — the common case.
            inner += "unset " + launch.strippedEnvironment
                .map(SSHCommand.shellQuote).joined(separator: " ") + "; "
        }
        inner += "exec " + ([launch.command] + launch.arguments)
            .map(SSHCommand.shellQuote).joined(separator: " ")
        return "cd \(SSHCommand.shellQuote(directory)) && "
            + "exec \(SSHCommand.loginShell) -lc \(SSHCommand.shellQuote(inner))"
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
