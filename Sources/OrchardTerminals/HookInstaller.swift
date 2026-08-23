import Foundation

/// Writes a per-worktree hook config so a freshly-spawned agent CLI POSTs its
/// lifecycle events to Orchard's loopback `HookServer` (Tier-1 turn detection).
///
/// Scoped by path: Claude Code auto-loads `.claude/settings.local.json` from the cwd
/// (the worktree) it starts in, and that file is conventionally git-ignored — so the
/// config applies to exactly this one agent and never leaks into the user's global
/// setup or the committed repo. Each event registers a `command` hook that curls the
/// server, forwarding the hook's stdin JSON as the body and tagging the request with
/// this agent's unguessable per-run `token`.
public enum HookInstaller {
    /// Where the config goes, relative to the worktree root. The remote installer
    /// (T39) writes the same path on the far side, so the two cannot drift.
    public static let settingsRelativePath = ".claude/settings.local.json"

    /// Install hooks for `events` into `worktree/.claude/settings.local.json`.
    /// Returns true on success; a failure just means the agent runs without Tier-1 hooks.
    @discardableResult
    public static func install(
        worktree: URL,
        port: UInt16,
        token: String,
        events: [String]
    ) -> Bool {
        let dir = worktree.appendingPathComponent(".claude", isDirectory: true)
        let file = dir.appendingPathComponent("settings.local.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Merge into any settings the file already has, so we don't clobber a repo's
            // own local settings; we only own the `hooks` object.
            let existing = try? Data(contentsOf: file)
            let out = try settingsJSON(port: port, token: token, events: events,
                                       mergingInto: existing)
            try out.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The file's full contents: whatever settings were already there, with our `hooks`
    /// object replacing theirs.
    ///
    /// Factored out of `install` because the remote installer cannot use `Data(contentsOf:)`
    /// or `write(to:)` at all — its file lives on another machine and arrives as the
    /// stdout of a `cat` — but it must produce a byte-identical config, or a remote
    /// agent's hooks would differ from a local one's for no reason anybody could see.
    /// Unparseable existing content is replaced rather than merged: a settings file we
    /// cannot read is not one we can safely preserve half of.
    public static func settingsJSON(port: UInt16, token: String, events: [String],
                                    mergingInto existing: Data? = nil) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = obj
        }
        root["hooks"] = hooksObject(port: port, token: token, events: events)
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// Build the `hooks` object: each event → a single command hook curling the server.
    ///
    /// The endpoint is always `127.0.0.1:<port>`. For a remote agent that loopback is
    /// the *remote* machine's, and `port` is the listening end of an SSH reverse tunnel
    /// back to this one — which is the whole point: the hook command is identical on
    /// both sides, so nothing in the agent's config reveals (or depends on) which
    /// machine it is running on.
    public static func hooksObject(port: UInt16, token: String, events: [String]) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            let url = "http://127.0.0.1:\(port)/hook?agent=\(token)&event=\(event)"
            // `--data-binary @-` forwards Claude's stdin JSON as the POST body; short
            // timeout + `|| true` guarantee the hook never stalls or fails the agent.
            let command = "curl -sS -m 2 -X POST '\(url)' --data-binary @- >/dev/null 2>&1 || true"
            hooks[event] = [
                ["matcher": "", "hooks": [["type": "command", "command": command]]]
            ]
        }
        return hooks
    }
}
