import Foundation

/// Declarative description of one `orchard` CLI command. The single source the CLI's arg
/// parser, `--help` output, and `orchard agent-context --json` all render from — keeping
/// the docs an agent reads and the flags the binary accepts version-matched by
/// construction (the reason agents don't hallucinate flags).
public struct CommandSpec: Codable, Equatable, Sendable {
    public let name: String
    public let aliases: [String]
    /// One-line description shown in listings.
    public let summary: String
    /// Usage template, e.g. `orchard worktree create --name <n> [--base-branch <ref>]`.
    public let usage: String?
    public let flags: [FlagSpec]
    public let positionalArgs: [String]
    public let examples: [String]
    public let notes: [String]

    public init(name: String, aliases: [String] = [], summary: String, usage: String? = nil,
                flags: [FlagSpec] = [], positionalArgs: [String] = [],
                examples: [String] = [], notes: [String] = []) {
        self.name = name
        self.aliases = aliases
        self.summary = summary
        self.usage = usage
        self.flags = flags
        self.positionalArgs = positionalArgs
        self.examples = examples
        self.notes = notes
    }
}

public struct FlagSpec: Codable, Equatable, Sendable {
    /// Flag name without dashes, e.g. "task-id".
    public let name: String
    public let summary: String
    /// Placeholder for the flag's value in usage text (nil = boolean flag).
    public let valueHint: String?
    public let required: Bool

    public init(name: String, summary: String, valueHint: String? = nil, required: Bool = false) {
        self.name = name
        self.summary = summary
        self.valueHint = valueHint
        self.required = required
    }
}

/// The shape `orchard agent-context --json` serializes — a pure local read that works
/// with no runtime running.
public struct AgentContextDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let commands: [CommandSpec]

    public init(schemaVersion: Int = 1, commands: [CommandSpec]) {
        self.schemaVersion = schemaVersion
        self.commands = commands
    }
}

/// The complete command vocabulary shared by parsing, help, and agent discovery.
public enum OrchardCommands {
    private static func flag(_ name: String, _ summary: String, _ value: String? = nil,
                             required: Bool = false) -> FlagSpec {
        FlagSpec(name: name, summary: summary, valueHint: value, required: required)
    }

    public static let all: [CommandSpec] = {
        let json = flag("json", "Emit machine-readable JSON")
        let retry = flag("retry-request", "Idempotency request identifier", "id")
        // Sender identity + proof, exactly as the dispatch preamble teaches workers
        // (`send --from <handle> --dispatch-capability <secret> …`).
        let from = flag("from", "Sender terminal handle", "handle")
        let capability = flag("dispatch-capability", "Dispatch capability secret", "secret")
        let run = flag("run", "Run identifier", "id")
        func command(_ name: String, _ summary: String, _ flags: [FlagSpec] = [],
                     positionals: [String] = []) -> CommandSpec {
            CommandSpec(name: name, summary: summary, usage: "orchard \(name) [options]",
                        flags: flags + [json], positionalArgs: positionals)
        }
        return [
            command("status", "Show runtime status"),
            command("agent-context", "Serialize the complete command table"),
            command("guide", "Read an embedded version-matched guide", positionals: ["get", "topic"]),
            command("version", "Print the CLI version"),
            command("run-create", "Create an orchestration run", [flag("objective", "Run objective", "text", required: true), from, retry]),
            command("run-use", "Bind this terminal as run coordinator", [flag("id", "Run identifier", "id", required: true), flag("takeover-legacy", "Take over a legacy binding"), from, retry]),
            command("run-current", "Show the current run", [from]), command("run-list", "List runs"),
            command("run-show", "Show a run", [flag("id", "Run identifier", "id", required: true)]),
            command("send", "Send an orchestration message", [flag("subject", "Subject", "text", required: true), flag("to", "Recipient", "address"), flag("body", "Body", "text"), flag("type", "Message type", "type"), flag("priority", "Priority", "priority"), flag("thread-id", "Thread identifier", "id"), flag("payload", "JSON payload", "json"), flag("task-id", "Task identifier", "id"), flag("dispatch-id", "Dispatch identifier", "id"), flag("outcome", "Worker outcome", "succeeded|failed"), flag("files-modified", "Comma-separated paths", "csv"), flag("report-path", "Report path", "path"), flag("phase", "Heartbeat phase", "phase"), from, capability, run, retry]),
            command("check", "Read or wait for coordinator delivery", [flag("terminal", "Terminal handle", "handle"), run, flag("ack", "Acknowledge delivery", "id"), flag("unread", "Unread only"), flag("peek", "Do not mark read"), flag("all", "All messages"), flag("types", "Wake message types", "csv"), flag("format", "Human format", "name"), flag("wait", "Long-poll"), flag("timeout-ms", "Timeout", "ms"), flag("limit", "Maximum results", "n"), retry]),
            command("reply", "Reply to a message", [flag("id", "Message identifier", "id", required: true), flag("body", "Reply body", "text", required: true), from, retry]),
            command("ask", "Ask or resume a blocking question", [flag("question", "Question", "text"), flag("resume", "Question message id", "id"), flag("options", "Comma-separated options", "csv"), flag("timeout-ms", "Timeout", "ms"), from, capability, retry]),
            command("inbox", "List inbox messages", [flag("limit", "Maximum results", "n"), flag("full", "Include full bodies"), flag("terminal", "Terminal handle", "handle"), from, run]),
            command("task-create", "Create a task", [flag("spec", "Task specification", "text", required: true), flag("task-title", "Task title", "text"), flag("display-name", "Display name", "text"), flag("deps", "Dependency JSON", "json"), flag("parent", "Parent task", "id"), from, run, retry]),
            command("task-list", "List tasks", [flag("status", "Filter status", "status"), flag("ready", "Ready tasks only"), flag("brief", "Brief output"), from, run]),
            command("task-update", "Update a task", [flag("id", "Task identifier", "id", required: true), flag("status", "New status", "status", required: true), flag("result", "Result JSON", "json"), retry]),
            command("dispatch", "Dispatch a task", [flag("task", "Task identifier", "id", required: true), flag("to", "Terminal handle", "handle", required: true), flag("inject", "Inject preamble"), flag("dry-run", "Preview only"), flag("return-preamble", "Return preamble"), from, retry]),
            command("dispatch-show", "Show a dispatch", [flag("id", "Dispatch identifier", "id", required: true)]),
            command("gate-create", "Create a decision gate", [flag("task", "Task identifier", "id", required: true), flag("question", "Question", "text", required: true), flag("options", "Options JSON", "json"), from, retry]),
            command("gate-resolve", "Resolve a decision gate", [flag("id", "Gate identifier", "id", required: true), flag("resolution", "Resolution", "text", required: true), retry]),
            command("gate-list", "List decision gates", [flag("task", "Task identifier", "id"), flag("status", "Gate status", "status")]),
            command("worker-start", "Start a supervised worker", [flag("task", "Task identifier", "id", required: true), flag("on", "Environment", "environment"), flag("worktree", "Workspace placement", "selector"), flag("agent", "Agent type", "agent"), flag("terminal", "Existing terminal", "handle"), flag("model", "Model", "id"), flag("effort", "Reasoning effort", "level"), flag("name", "Worktree name", "name"), flag("repo", "Repository", "selector"), flag("base-branch", "Git base", "ref"), flag("setup", "Setup policy", "run|skip|inherit"), flag("retry-of", "Prior dispatch", "id"), retry]),
            command("worker-show", "Show a supervised worker", [flag("dispatch", "Dispatch identifier", "id", required: true)]),
            command("worker-read", "Read archived or live worker output", [flag("dispatch", "Dispatch identifier", "id", required: true), flag("source", "Output source", "auto|transcript|terminal"), flag("cursor", "Paging cursor", "cursor"), flag("limit", "Maximum entries", "n")]),
            command("worker-stop", "Stop a worker", [flag("dispatch", "Dispatch identifier", "id", required: true), retry]),
            command("worker-abandon", "Abandon uncertain worker resources", [flag("dispatch", "Dispatch identifier", "id", required: true), retry]),
            command("worker-release", "Archive and release worker resources", [flag("dispatch", "Dispatch identifier", "id", required: true), retry]),
            command("worker-retain", "Retain worker resources", [flag("dispatch", "Dispatch identifier", "id", required: true), retry]),
            command("worker-list", "List supervised workers", [flag("terminal-state", "Terminal state filter", "state")]),
            command("repo", "Manage registered repositories", [flag("path", "Repository path", "path"), flag("repo", "Repository selector", "selector"), flag("display-name", "Display name", "text")], positionals: ["list|add|show"]),
            command("file", "Open, diff, or reveal git-changed workspace files", [
                flag("path", "File path relative to the worktree (or absolute inside it)", "path"),
                flag("worktree", "Worktree selector", "selector"),
                flag("staged", "Accepted for parity; diffs are always vs the fork point"),
                flag("mode", "open-changed mode: edit, diff, or both (default diff)", "edit|diff|both"),
            ], positionals: ["open|diff|open-changed", "path"]),
            // T10 embedded browser. Refs (@eN) come from the latest `snapshot` of a
            // page and are invalidated by any navigation — re-snapshot, don't guess.
            command("browser", "Drive a workspace's embedded browser", [flag("worktree", "Workspace selector", "selector", required: true), flag("page", "Browser tab id", "id"), flag("url", "Destination URL", "url"), flag("ref", "Snapshot element ref (@eN)", "ref"), flag("text", "Text for fill/type", "text"), flag("js", "JavaScript expression for eval", "expr"), flag("limit", "Maximum console entries", "n")], positionals: ["goto|back|forward|reload|snapshot|click|fill|type|screenshot|eval|console|tab"]),
            command("reset", "Reset orchestration state", [flag("all", "Reset all"), flag("tasks", "Reset tasks"), flag("messages", "Reset messages")]),
        ]
    }()
}

/// Placeholder command-group vocabulary for the v2 verb surface (see
/// docs/research/orca-inventory.md §1.4/§7). Wave-1 tasks replace this with the real
/// per-verb `CommandSpec` tables; it exists now so seam code can name the groups.
public enum CommandGroup: String, Codable, CaseIterable, Sendable {
    case runtime      // status, serve (later)
    case run          // run-create/use/current/list/show
    case message      // send/check/reply/ask/inbox
    case task         // task-create/list/update
    case dispatch     // dispatch/dispatch-show
    case worker       // worker-start/show/read/stop/abandon/release/retain/list
    case gate         // gate-create/resolve/list
    case terminal     // terminal list/create/read/send/wait/split/close/rename
    case worktree     // worktree list/show/current/create/set/rm
    case repo         // repo list/add/show
    case file         // file open/diff/open-changed (wave 2)
    case browser      // browser goto/…/tab (wave 2)
    case guide        // agent-context, guide get <topic>
}
