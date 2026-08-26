import Foundation

/// Builds the `ssh` invocations Orchard runs: the bounded connectivity probe and the
/// remote-shell PTY command.
///
/// One rule decides the destination argument. An `ssh-config` host connects by its
/// alias, so OpenSSH resolves the user's own `~/.ssh/config` entry — ProxyJump,
/// IdentityFile, ControlMaster, everything Orchard deliberately does not model. A
/// `manual` host has no config entry to resolve, so it connects by `[user@]hostname`
/// with an explicit `-p`. Rewriting an alias into its hostname would silently drop the
/// rest of the user's config, which is how a working host starts failing to connect.
public enum SSHCommand {
    /// The `ssh` binary. Absolute so a managed PTY's PATH cannot pick a different one.
    public static let binary = "/usr/bin/ssh"

    public static func destination(for host: HostRecord) -> String {
        switch host.source {
        case .sshConfig:
            return host.name
        case .manual:
            let target = host.hostname.isEmpty ? host.name : host.hostname
            guard let user = host.user, !user.isEmpty else { return target }
            return "\(user)@\(target)"
        }
    }

    private static func portArguments(for host: HostRecord) -> [String] {
        // An ssh-config host's Port comes from the config OpenSSH is about to read.
        guard host.source == .manual, let port = host.port, port != 22 else { return [] }
        return ["-p", String(port)]
    }

    /// `ssh -o BatchMode=yes -o ConnectTimeout=5 <dest> true` — the probe.
    ///
    /// `BatchMode=yes` is what makes this safe to run unattended: OpenSSH fails instead
    /// of prompting for a password or a passphrase, so the probe can never block on a
    /// human who is not there. A host that only needs a passphrase therefore answers
    /// `auth-required`, not `unreachable`.
    public static func probeArgv(for host: HostRecord,
                                 connectTimeoutSeconds: Int = 5) -> [String] {
        [binary,
         "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=\(connectTimeoutSeconds)"]
            + portArguments(for: host)
            + [destination(for: host), "true"]
    }

    /// `ssh -tt [options] <dest> [command]` — the remote shell PTY.
    ///
    /// `-tt` forces a remote TTY even though `ssh`'s own stdin is already a PTY the
    /// local pane owns; without it the far side runs without a controlling terminal and
    /// no interactive shell or agent TUI can draw. With no command, this is a remote
    /// login shell.
    ///
    /// `options` is where a remote agent pane's reverse tunnel goes (T39). It carries
    /// no `ExitOnForwardFailure`: a pane whose tunnel loses its port race must keep
    /// running and degrade to fingerprint-only status, not die at spawn. Killing an
    /// agent because Orchard could not watch it is the wrong trade.
    public static func remoteShellArgv(for host: HostRecord, command: String? = nil,
                                       options: [String] = []) -> [String] {
        var argv = [binary, "-tt"] + options + portArguments(for: host)
            + [destination(for: host)]
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            argv.append(command)
        }
        return argv
    }

    /// `-R <remotePort>:127.0.0.1:<localPort>` — the reverse tunnel that carries a
    /// remote agent's hook POSTs back to this machine's `HookServer`.
    ///
    /// The remote end binds the *remote* loopback, so the hook command a remote agent
    /// runs is byte-identical to a local one's (`curl http://127.0.0.1:<port>/hook…`)
    /// and nothing on the far side is exposed to that host's network. `remotePort: 0`
    /// asks OpenSSH to let sshd choose, which it then reports on stderr — see
    /// `RemoteHookTunnel.parseAllocatedPort`.
    public static func reverseTunnelArguments(remotePort: UInt16, localPort: UInt16) -> [String] {
        ["-R", "\(remotePort):127.0.0.1:\(localPort)"]
    }

    /// `ssh -o BatchMode=yes -o ConnectTimeout=<n> [-p <port>] <dest> <command>` — one
    /// bounded, non-interactive remote command.
    ///
    /// Same `BatchMode` guarantee as the probe: OpenSSH fails instead of prompting, so a
    /// remote git read can never park on a passphrase nobody is there to type. No `-t`:
    /// this is a captured command, not a pane, and allocating a TTY would fold stderr
    /// into stdout and echo the output back at us.
    public static func commandArgv(for host: HostRecord, command: String,
                                   connectTimeoutSeconds: Int = 5,
                                   options: [String] = []) -> [String] {
        [binary,
         "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=\(connectTimeoutSeconds)"]
            + options
            + portArguments(for: host)
            + [destination(for: host), command]
    }

    /// The far side's own login shell, as a word its shell expands: `"${SHELL:-/bin/sh}"`.
    ///
    /// Deliberately unquoted by `shellQuote` — the expansion has to happen *there*. The
    /// `:-` default is for a host where `SHELL` is unset (some `sshd` setups), which
    /// would otherwise exec the empty string and kill the pane at spawn.
    public static let loginShell = "\"${SHELL:-/bin/sh}\""

    /// `cd '<dir>' && exec "${SHELL:-/bin/sh}" -l` — what a pane in a remote worktree
    /// runs.
    ///
    /// `exec` rather than a nested shell so the pane's PTY child *is* the login shell:
    /// an extra wrapper layer would swallow the exit status the liveness verdict reads.
    public static func cdAndLoginShellCommand(directory: String) -> String {
        "cd \(shellQuote(directory)) && exec \(loginShell) -l"
    }

    /// The remote-shell argv as one shell command line, for the launch paths that take
    /// a command string (the `shell` engine's prompt-as-command-line contract).
    public static func remoteShellCommandLine(for host: HostRecord, command: String? = nil,
                                              options: [String] = []) -> String {
        remoteShellArgv(for: host, command: command, options: options)
            .map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ value: String) -> String {
        if !value.isEmpty,
           value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@".contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
