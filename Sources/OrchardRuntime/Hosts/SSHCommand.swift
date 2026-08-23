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

    /// `ssh -tt <dest> [command]` — the remote shell PTY.
    ///
    /// `-tt` forces a remote TTY even though `ssh`'s own stdin is already a PTY the
    /// local pane owns; without it the far side runs without a controlling terminal and
    /// no interactive shell or agent TUI can draw. With no command, this is a remote
    /// login shell.
    public static func remoteShellArgv(for host: HostRecord, command: String? = nil) -> [String] {
        var argv = [binary, "-tt"] + portArguments(for: host) + [destination(for: host)]
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            argv.append(command)
        }
        return argv
    }

    /// The remote-shell argv as one shell command line, for the launch paths that take
    /// a command string (the `shell` engine's prompt-as-command-line contract).
    public static func remoteShellCommandLine(for host: HostRecord, command: String? = nil) -> String {
        remoteShellArgv(for: host, command: command).map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ value: String) -> String {
        if !value.isEmpty,
           value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@".contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
