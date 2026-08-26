import Foundation
import OrchardTerminals

/// Installs an agent's Tier-1 hook config in a worktree that lives on another machine.
///
/// The local `HookInstaller` writes a file. This cannot: its file is on the far side, so
/// every step is a bounded `ssh` round trip — read what is there, merge, write it back,
/// and make git ignore it. The *contents* still come from `HookInstaller.settingsJSON`,
/// so a remote agent's config is byte-for-byte what a local one would get with the same
/// port and token. Nothing in it says "remote": the endpoint is `127.0.0.1:<port>` on
/// the agent's own loopback, which the reverse tunnel makes true.
///
/// Failure is never fatal here. A host that will not take the config leaves the agent
/// running with fingerprint-only status, which the caller records on the pane — an agent
/// Orchard can see less of is strictly better than no agent.
public struct RemoteHookConfig: Sendable {
    public let runner: SSHRunner

    public init(runner: SSHRunner) {
        self.runner = runner
    }

    public var hostName: String { runner.hostName }

    /// Write `<worktree>/.claude/settings.local.json` on the host, merged onto whatever
    /// is already there, and keep it out of the agent's own `git status`.
    ///
    /// Throws `RemoteHostError` rather than returning a flag so the two failure shapes
    /// stay distinguishable at the call site: `host_unverifiable` (we could not reach
    /// the host) and `remote_hook_install_failed` (the host answered, and said no).
    public func install(worktreePath: String, port: UInt16, token: String,
                        events: [String]) async throws {
        let file = Self.settingsPath(worktreePath: worktreePath)
        let existing = await readExisting(file)
        let payload: Data
        do {
            payload = try HookInstaller.settingsJSON(port: port, token: token,
                                                     events: events, mergingInto: existing)
        } catch {
            throw RemoteHostError("remote_hook_install_failed",
                                  "could not build the hook config: \(error)")
        }
        guard let json = String(data: payload, encoding: .utf8) else {
            throw RemoteHostError("remote_hook_install_failed",
                                  "the hook config was not valid UTF-8")
        }
        let directory = Self.settingsDirectory(worktreePath: worktreePath)
        // The worktree must already be there. `mkdir -p` would happily create the whole
        // chain, and a hook install is the *first* thing that touches the far side —
        // so on a host where the worktree is gone (removed out from under the registry,
        // a stale row, a path that never existed) this step used to conjure the
        // directory, and the pane's `cd` then succeeded into an empty one. An agent
        // running in an empty directory that is wearing the workspace's name is the
        // same class of mistake as a local pane in a remote path: the work happens
        // somewhere that is not the workspace (T83, docs/design/remote-hosts.md §1).
        // Failing here is safe — the caller degrades the pane to fingerprint-only —
        // and the launch that follows now fails honestly, with the far side's own
        // `cd: no such file or directory` in the readiness receipt.
        //
        // `printf %s` rather than a heredoc: the JSON travels as one quoted *argument*,
        // so the far side's shell never scans it for `$`, backticks or a terminator that
        // happens to appear inside a hook command.
        let command = "[ -d \(SSHCommand.shellQuote(worktreePath)) ] || "
            + "{ printf '%s\\n' \(SSHCommand.shellQuote(Self.missingWorktreeMarker)) >&2; exit 66; }; "
            + "mkdir -p \(SSHCommand.shellQuote(directory)) && "
            + "printf %s \(SSHCommand.shellQuote(json)) > \(SSHCommand.shellQuote(file))"
        let outcome = await runner.run(command)
        switch outcome {
        case .unverifiable(let reason):
            throw RemoteHostError.unverifiable(host: hostName,
                                               doing: "installing the agent hook config",
                                               reason: reason)
        case .answered(let code, _, let stderr):
            guard code == 0 else {
                if code == 66 || (SSHRunner.firstLine(stderr) ?? "")
                    .contains(Self.missingWorktreeMarker) {
                    throw RemoteHostError(
                        "remote_worktree_missing",
                        "\(worktreePath) does not exist on \(hostName), so nothing was "
                            + "created there and no hook config was written.")
                }
                let detail = SSHRunner.firstLine(stderr) ?? "exit \(code)"
                throw RemoteHostError("remote_hook_install_failed",
                                      "writing \(file) on \(hostName) failed: \(detail)")
            }
        }
        await ensureExcluded(worktreePath: worktreePath)
    }

    /// Best-effort mirror of `WorktreeManager.ensureExcluded`: append the settings path
    /// to the worktree's `info/exclude` so the agent never sees Orchard's own config in
    /// its diff.
    ///
    /// Deliberately not throwing. A config the agent's `git status` shows is untidy; a
    /// refused launch because we could not tidy it is worse. `--git-path` is asked for
    /// rather than assumed because a linked worktree's `.git` is a file, and its
    /// `info/exclude` lives in the parent repo's admin directory.
    public func ensureExcluded(worktreePath: String) async {
        let pattern = HookInstaller.settingsRelativePath
        let quotedPattern = SSHCommand.shellQuote(pattern)
        let quotedWorktree = SSHCommand.shellQuote(worktreePath)
        // One command so it costs one round trip: resolve, create, check, append.
        let command = "p=$(git -C \(quotedWorktree) rev-parse --git-path info/exclude) && "
            + "cd \(quotedWorktree) && mkdir -p \"$(dirname \"$p\")\" && "
            + "{ grep -qxF \(quotedPattern) \"$p\" 2>/dev/null || "
            + "printf '%s\\n' \(quotedPattern) >> \"$p\"; }"
        _ = await runner.run(command)
    }

    /// What the far side prints when the worktree is not there. Matched as well as the
    /// exit status because a login shell is allowed to overwrite `$?` on its way out.
    static let missingWorktreeMarker = "orchard-remote-worktree-missing"

    public static func settingsDirectory(worktreePath: String) -> String {
        joined(worktreePath, ".claude")
    }

    public static func settingsPath(worktreePath: String) -> String {
        joined(worktreePath, HookInstaller.settingsRelativePath)
    }

    private static func joined(_ base: String, _ suffix: String) -> String {
        base.hasSuffix("/") ? base + suffix : base + "/" + suffix
    }

    /// The current file, or nil when there isn't one (or we could not read it).
    ///
    /// `|| true` so a missing file is an empty answer rather than a nonzero status:
    /// "no settings yet" is the common case, not an error. A host that does not answer
    /// at all also lands here as nil — the write that follows is the step that reports
    /// loss of contact, and it reports it once.
    private func readExisting(_ file: String) async -> Data? {
        let outcome = await runner.run("cat \(SSHCommand.shellQuote(file)) 2>/dev/null || true")
        guard case .answered(let code, let stdout, _) = outcome, code == 0,
              !stdout.isEmpty else { return nil }
        return Data(stdout.utf8)
    }
}
