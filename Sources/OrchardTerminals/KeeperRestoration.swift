import Foundation

/// One pane's restoration record, persisted at clean-quit handoff and read back on the
/// next boot to adopt the surviving PTY into the terminal registry under the SAME
/// `paneKey` (with `incarnation` bumped by the adopter).
///
/// Everything here is data the next app instance cannot re-derive from a bare fd:
/// registry identity, engine, spawn geometry, the state-restoration preamble captured
/// from the live parser, and the hook facts that let agent status detection
/// re-establish (same token routes the surviving CLI's hook POSTs; same port keeps its
/// already-installed hook config valid).
public struct KeeperPaneRecord: Codable, Equatable, Sendable {
    /// The keeper-side hold identity (`KeeperHold.uuid`) this pane's fd travels under.
    public var keeperUUID: String
    public var paneKey: String
    /// The pane's incarnation AT handoff; adoption registers `incarnation + 1`.
    public var incarnation: Int
    public var worktreeId: String?
    public var engineID: String
    public var title: String?
    public var cwd: String?
    /// The spawn argv with Claude session-identity flags stripped
    /// (`KeeperRestartArgv`). Recorded for a future cold path; Orchard's documented
    /// limit is that a child that died while held closes its pane — no respawn.
    public var argv: [String]
    /// Base64 of `stateRestorationPreamble()` — replayed into the adopting parser
    /// before any buffered/live output so modes set before the restart survive it.
    public var preambleBase64: String
    /// Grid geometry at handoff, so the adopted session's grid starts at the size the
    /// child already has instead of a default it would immediately reflow away from.
    public var cols: Int
    public var rows: Int
    /// The agent's hook-routing token. Reusing it on adoption is what lets the
    /// surviving CLI's lifecycle hooks route back to the restored session.
    public var hookToken: String?
    /// The loopback hook-server port this pane's worktree hook config points at.
    /// Boot tries to rebind it so those installed configs keep landing.
    public var hookPort: UInt16?
    /// The owning project's base repo path (agent panes), for rejoining the pane to
    /// its `ProjectSession`/`AgentSupervisor` on boot.
    public var repoPath: String?
    /// The worktree directory the agent ran in (agent panes).
    public var worktreePath: String?

    public init(keeperUUID: String, paneKey: String, incarnation: Int,
                worktreeId: String?, engineID: String, title: String?, cwd: String?,
                argv: [String], preambleBase64: String, cols: Int, rows: Int,
                hookToken: String? = nil, hookPort: UInt16? = nil,
                repoPath: String? = nil, worktreePath: String? = nil) {
        self.keeperUUID = keeperUUID
        self.paneKey = paneKey
        self.incarnation = incarnation
        self.worktreeId = worktreeId
        self.engineID = engineID
        self.title = title
        self.cwd = cwd
        self.argv = argv
        self.preambleBase64 = preambleBase64
        self.cols = cols
        self.rows = rows
        self.hookToken = hookToken
        self.hookPort = hookPort
        self.repoPath = repoPath
        self.worktreePath = worktreePath
    }

    public var preamble: Data { Data(base64Encoded: preambleBase64) ?? Data() }
}

/// Everything a boot needs to reclaim one handoff generation: which keeper to ask
/// (`generation` names its claim socket) and the per-pane records to adopt under.
public struct KeeperRestorationState: Codable, Equatable, Sendable {
    public var generation: String
    public var savedAt: Date
    public var panes: [KeeperPaneRecord]

    public init(generation: String, savedAt: Date = Date(), panes: [KeeperPaneRecord]) {
        self.generation = generation
        self.savedAt = savedAt
        self.panes = panes
    }
}

/// One pane released for handoff: the restoration record to persist plus the live
/// master fd (and friends) to pass to the keeper. `paneRecord` is mutable so the app
/// layer can fill in facts the terminal service doesn't know (the hook-server port).
public struct KeeperReleasedPane {
    public var paneRecord: KeeperPaneRecord
    public let handoff: KeeperPTYHandoff

    public init(paneRecord: KeeperPaneRecord, handoff: KeeperPTYHandoff) {
        self.paneRecord = paneRecord
        self.handoff = handoff
    }
}

/// Persistence for `KeeperRestorationState`. One-shot by design: boot consumes the
/// file (`loadAndDelete`) before doing anything with it, so a crash mid-restore can
/// never re-adopt the same generation twice, and a crash-quit (nothing written)
/// degrades to today's fresh-boot behavior automatically.
public enum KeeperRestorationStore {
    public static func defaultURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("keeper-restoration.json")
    }

    public static func save(_ state: KeeperRestorationState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    /// Read the state and remove the file in the same step. Returns nil (and removes
    /// nothing extra) when the file is absent or undecodable — either way the caller
    /// proceeds as a fresh boot.
    public static func loadAndDelete(at url: URL) -> KeeperRestorationState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KeeperRestorationState.self, from: data)
    }
}

/// Strips Claude Code's session-identity flags from a saved argv, mirroring damson's
/// measured retreat (docs/CLAUDE-ORCHESTRATION.md §3): re-running `--resume <id>` can
/// exit on startup ("No conversation found" / "No deferred tool marker found…"), and a
/// process that exits on startup closes its pane — strictly worse than a clean
/// restart. Re-running `--session-id <id>` conflicts with the id's existing
/// conversation. So a restart argv comes back clean and `/resume` stays a human
/// decision made inside the pane.
public enum KeeperRestartArgv {
    /// `argv` as spawned by Orchard is usually the login-shell wrap
    /// `[shell, "-l", "-c", "exec <engine> …"]`; the flags to strip live inside the
    /// `-c` payload, so both the direct and the wrapped shape are handled.
    public static func stripped(_ argv: [String]) -> [String] {
        if isClaude(argv.first) { return strippedTokens(argv) }
        // Login-shell wrap: rewrite only the `-c` payload, and only when it actually
        // invokes Claude. Whitespace tokenization is safe for the flags stripped here —
        // their values are bare session ids, never quoted strings.
        guard let cIndex = argv.firstIndex(of: "-c"), argv.indices.contains(cIndex + 1) else {
            return argv
        }
        let payload = argv[cIndex + 1]
        let tokens = payload.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard tokens.contains(where: { isClaude($0) }) else { return argv }
        var out = argv
        out[cIndex + 1] = strippedTokens(tokens).joined(separator: " ")
        return out
    }

    /// Drop `--session-id` / `--resume` / `-r` and their values (a bare trailing flag
    /// just disappears; `=`-joined forms are dropped as one token).
    static func strippedTokens(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--session-id" || t == "--resume" || t == "-r" {
                i += 2
                continue
            }
            if t.hasPrefix("--session-id=") || t.hasPrefix("--resume=") {
                i += 1
                continue
            }
            out.append(t)
            i += 1
        }
        return out
    }

    /// Matched on the executable's NAME (never a path substring), so it holds for any
    /// install location and a pane running `/Users/claude/bin/vim` is not Claude Code.
    static func isClaude(_ executable: String?) -> Bool {
        guard let executable, !executable.isEmpty else { return false }
        return (executable as NSString).lastPathComponent == "claude"
    }
}
