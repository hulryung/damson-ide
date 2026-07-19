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
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = obj
            }
            root["hooks"] = hooksObject(port: port, token: token, events: events)
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Build the `hooks` object: each event → a single command hook curling the server.
    private static func hooksObject(port: UInt16, token: String, events: [String]) -> [String: Any] {
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
