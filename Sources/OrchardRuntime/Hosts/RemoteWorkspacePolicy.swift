import Foundation

/// Surfaces the runtime types as `remote_unsupported` (docs/design/remote-hosts.md
/// stage 2/3). The file service, local git diff, editor, and agent engines all
/// assume a filesystem on *this* machine; answering them for a remote workspace
/// would either fail confusingly or — worse — find a same-named local directory.
///
/// The browser pane is local-only for the same reason: its workspace key is a
/// local path, and a remote path handed to WKWebView is not a remote file tree.
public enum RemoteAffordance: String, CaseIterable, Sendable {
    case fileExplorer
    case diff
    case editor
    case agents
    case composer
    case browser

    /// The workbench tab this affordance corresponds to, when there is one.
    public var tabKind: String? {
        switch self {
        case .diff: return "diff"
        case .editor: return "editor"
        case .browser: return "browser"
        case .fileExplorer, .agents, .composer: return nil
        }
    }
}

/// UI-free wording and gating for remote workspaces (T37).
///
/// Probe failures use the host-check verdict vocabulary (`reachable` /
/// `auth-required` / `unreachable`). Loss of contact is never worded as the
/// host or the repo having been removed — a host we cannot reach still exists
/// (docs/design/remote-hosts.md §1 rule 2, §3).
public enum RemoteWorkspacePolicy: Sendable {
    /// Whether `hostId` names a remote execution host. Unparseable ids are treated
    /// as remote so they never silently fall through to a local filesystem.
    public static func isRemote(hostId: String?) -> Bool {
        guard let hostId, !hostId.isEmpty else { return false }
        guard let parsed = ExecutionHostId(rawValue: hostId) else { return true }
        return !parsed.isLocal
    }

    public static func isAvailable(_ affordance: RemoteAffordance, hostId: String?) -> Bool {
        !isRemote(hostId: hostId)
    }

    /// Short explanation shown on a disabled control. `nil` when the affordance
    /// is available (so a tooltip is not attached to a working button).
    public static func unsupportedExplanation(_ affordance: RemoteAffordance,
                                              hostId: String?) -> String? {
        guard isRemote(hostId: hostId) else { return nil }
        let host = hostLabel(hostId)
        switch affordance {
        case .fileExplorer:
            return "Files live on \(host); the file explorer cannot read remote workspaces yet (remote_unsupported)."
        case .diff:
            return "Diffs live on \(host); the review pane cannot read remote workspaces yet (remote_unsupported)."
        case .editor:
            return "Files live on \(host); the editor cannot open remote workspaces yet (remote_unsupported)."
        case .agents:
            // T39 made the agent itself possible on the far side, as a handoff-style
            // pane opened through the CLI. What is still impossible is the *supervised*
            // shape this control drives — the remote host has no orchard CLI, so a
            // worker there cannot report worker_done, heartbeat, or answer a question.
            return "Supervised agents cannot run on \(host): it has no orchard CLI, so a "
                + "worker there cannot report back (remote_unsupported). Open a remote "
                + "agent pane instead — it runs the agent there with live status only."
        case .composer:
            return "New worktrees with agents cannot start on \(host) yet (remote_unsupported)."
        case .browser:
            return "The browser tab is local-only; \(host) has no file tree this pane can open."
        }
    }

    /// One-line host-check status for the Open Remote picker. Never claims the
    /// host was removed: `unreachable` is loss of contact, `auth-required` is a
    /// host that answered and refused the offered credentials.
    public static func probeStatusLine(_ result: HostProbeResult) -> String {
        switch result.status {
        case .reachable:
            return "Reachable"
        case .authRequired:
            return "Auth required — \(result.detail)"
        case .unreachable:
            if let note = result.note, !note.isEmpty {
                return "Unreachable — \(note)"
            }
            return "Unreachable — loss of contact, not evidence that anything on "
                + "\(result.name) stopped."
        }
    }

    /// Compact chip next to a host in the picker (`reachable` / `auth-required` /
    /// `unreachable` / `checking`).
    public static func probeStatusChip(_ status: HostReachability?) -> String {
        guard let status else { return "checking" }
        return status.rawValue
    }

    /// Inline wording when `addRemoteRepo` fails. Probe failures stay in verdict
    /// language; the word "deleted" is never used.
    public static func registrationFailure(code: String, message: String,
                                           hostName: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case "host_unverifiable":
            if looksLikeAuthRequired(trimmed) {
                return "Auth required — \(trimmed)"
            }
            return unreachableRegistrationLine(detail: trimmed, hostName: hostName)
        case "remote_not_a_repo":
            return trimmed.isEmpty
                ? "That path on \(hostName) is not a git checkout."
                : trimmed
        case "unknown_host":
            return trimmed.isEmpty
                ? "No host named \(hostName) is registered."
                : trimmed
        case "invalid_argument":
            return trimmed.isEmpty ? "That remote path is not usable." : trimmed
        default:
            if looksLikeAuthRequired(trimmed) {
                return "Auth required — \(trimmed)"
            }
            if code.contains("unverifiable") || looksLikeUnreachable(trimmed) {
                return unreachableRegistrationLine(detail: trimmed, hostName: hostName)
            }
            return trimmed.isEmpty ? "Could not register the remote repo." : trimmed
        }
    }

    public static func hostLabel(_ hostId: String?) -> String {
        guard let hostId, !hostId.isEmpty else { return "the remote host" }
        if let parsed = ExecutionHostId(rawValue: hostId) {
            return parsed.label
        }
        if hostId.hasPrefix("ssh:") {
            let name = String(hostId.dropFirst("ssh:".count))
            return name.isEmpty ? "the remote host" : name
        }
        return hostId
    }

    private static func unreachableRegistrationLine(detail: String, hostName: String) -> String {
        let body = detail.isEmpty
            ? "the host did not answer"
            : detail
        return "Unreachable — \(body) Unreachable is loss of contact, not evidence that anything on \(hostName) stopped."
    }

    private static func looksLikeAuthRequired(_ text: String) -> Bool {
        let lower = text.lowercased()
        let fragments = [
            "permission denied", "publickey", "authentication failed",
            "no supported authentication methods", "too many authentication failures",
            "host key verification failed", "remote host identification has changed",
            "passphrase", "keyboard-interactive", "auth-required", "auth required"
        ]
        return fragments.contains { lower.contains($0) }
    }

    private static func looksLikeUnreachable(_ text: String) -> Bool {
        let lower = text.lowercased()
        let fragments = [
            "could not resolve", "connection refused", "connection timed out",
            "operation timed out", "no route to host", "network is unreachable",
            "unreachable", "loss of contact"
        ]
        return fragments.contains { lower.contains($0) }
    }
}
