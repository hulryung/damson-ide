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
    /// The exact set of values this flag accepts, when it is closed. A `valueHint`
    /// like "agent" tells a reader the shape but not the vocabulary — dogfood-1
    /// spent a failed `worker-start` discovering that `--agent claude` was not an
    /// accepted spelling — so closed flags enumerate here and agents read the list
    /// out of `agent-context` instead of guessing. nil means "open value".
    public let allowedValues: [String]?
    /// Alternate spellings accepted by the parser and stored under `name`.
    /// Dogfood-4: `dispatch-show` takes `--id` while worker verbs take `--dispatch`.
    public let aliases: [String]

    public init(name: String, summary: String, valueHint: String? = nil, required: Bool = false,
                allowedValues: [String]? = nil, aliases: [String] = []) {
        self.name = name
        self.summary = summary
        self.valueHint = valueHint
        self.required = required
        self.allowedValues = allowedValues
        self.aliases = aliases
    }

    /// True when `token` is this flag's canonical name or one of its aliases.
    public func matches(_ token: String) -> Bool {
        name == token || aliases.contains(token)
    }

    private enum CodingKeys: String, CodingKey {
        case name, summary, valueHint, required, allowedValues, aliases
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decode(String.self, forKey: .summary)
        valueHint = try values.decodeIfPresent(String.self, forKey: .valueHint)
        required = try values.decodeIfPresent(Bool.self, forKey: .required) ?? false
        allowedValues = try values.decodeIfPresent([String].self, forKey: .allowedValues)
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

/// The engine spellings `worker-start --agent` and `terminal create --engine` accept.
///
/// OrchardProtocol has no dependencies by design, so this list is a literal rather
/// than a projection of `AgentEngineRegistry`; `EngineIdentifierDriftTests` fails the
/// build's test run if the two ever disagree, which is what keeps the vocabulary an
/// agent reads and the vocabulary the runtime accepts the same vocabulary.
public enum OrchardAgentEngines {
    /// Canonical engine ids first, then the accepted aliases.
    public static let acceptedIdentifiers = [
        "claude-code", "codex", "cursor-agent", "grok", "shell",
        "claude", "cursor",
    ]
}

/// Default `--limit` for `worker-read` when the flag is omitted. Live and
/// archived terminal windows share this bound; `--cursor` pages older lines.
public enum WorkerReadPaging {
    public static let defaultLimit = 200

    /// True when lines exist before this window that the caller can still request.
    /// Distinct from `truncated`, which means the requested cursor was below the
    /// retained ring (those older lines are gone).
    public static func hasOlder(startCursor: Int, oldestCursor: Int) -> Bool {
        startCursor > oldestCursor
    }
}

/// Documented `worktree` subverbs (inventory §7). `ps` is served by the ports
/// handler; the rest live on the workspace handler. `remove`/`delete` map to `rm`.
public enum WorktreeSubcommands {
    public static let all = ["list", "show", "current", "create", "set", "rm", "ps"]
    public static let rmAliases = ["remove", "delete"]
}

/// Documented `project` subverbs. Host-setup verbs from Orca (`setups`,
/// `setup-clone`, …) are not part of this surface.
public enum ProjectSubcommands {
    public static let all = ["list", "show", "current"]
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

extension CommandSpec {
    /// Canonical flag for a `--token`, including aliases (`--dispatch` → `--id`).
    public func flag(named token: String) -> FlagSpec? {
        flags.first { $0.matches(token) }
    }
}

/// The complete command vocabulary shared by parsing, help, and agent discovery.
public enum OrchardCommands {
    private static func flag(_ name: String, _ summary: String, _ value: String? = nil,
                             required: Bool = false, aliases: [String] = []) -> FlagSpec {
        FlagSpec(name: name, summary: summary, valueHint: value, required: required,
                 aliases: aliases)
    }

    public static let all: [CommandSpec] = {
        let json = flag("json", "Emit machine-readable JSON")
        func enumerated(_ name: String, _ summary: String, _ value: String,
                        _ allowed: [String]) -> FlagSpec {
            FlagSpec(name: name, summary: summary, valueHint: value, allowedValues: allowed)
        }
        let retry = flag("retry-request", "Idempotency request identifier", "id")
        // Sender identity + proof, exactly as the dispatch preamble teaches workers
        // (`send --from <handle> --dispatch-capability <secret> …`).
        let from = flag("from", "Sender terminal handle", "handle")
        let capability = flag("dispatch-capability", "Dispatch capability secret", "secret")
        let run = flag("run", "Run identifier", "id")
        func command(_ name: String, _ summary: String, _ flags: [FlagSpec] = [],
                     positionals: [String] = [], notes: [String] = []) -> CommandSpec {
            CommandSpec(name: name, summary: summary, usage: "orchard \(name) [options]",
                        flags: flags + [json], positionalArgs: positionals, notes: notes)
        }
        return [
            command("status", "Show runtime status"),
            command("serve", "Run the Orchard runtime without the app", [
                flag("data-dir", "Runtime data directory", "path")
            ]),
            command("agent-context", "Serialize the complete command table"),
            CommandSpec(name: "guide", summary: "Read an embedded version-matched guide",
                        usage: "orchard guide [list | get <topic>] [--json]",
                        flags: [json], positionalArgs: ["list | get <topic>"],
                        examples: ["orchard guide", "orchard guide get orchestration",
                                   "orchard guide get conflicts",
                                   "orchard guide get worktree",
                                   "orchard guide get project"],
                        notes: ["With no arguments, lists the available topics."]),
            command("version", "Print the CLI version"),
            command("run-create", "Create an orchestration run", [flag("objective", "Run objective", "text", required: true), from, retry]),
            command("run-use", "Bind this terminal as run coordinator", [flag("id", "Run identifier", "id", required: true), flag("takeover-legacy", "Take over a legacy binding"), from, retry]),
            command("run-current", "Show the current run", [from]), command("run-list", "List runs"),
            command("run-show", "Show a run", [flag("id", "Run identifier", "id", required: true)]),
            command("send", "Send an orchestration message", [flag("subject", "Subject", "text", required: true), flag("to", "Recipient", "address"), flag("body", "Body", "text"), flag("type", "Message type", "type"), flag("priority", "Priority", "priority"), flag("thread-id", "Thread identifier", "id"), flag("payload", "JSON payload", "json"), flag("task-id", "Task identifier", "id"), flag("dispatch-id", "Dispatch identifier", "id"), flag("outcome", "Worker outcome", "succeeded|failed"), flag("files-modified", "Comma-separated paths", "csv"), flag("report-path", "Report path", "path"), flag("phase", "Heartbeat phase", "phase"), flag("verbose", "Print the full JSON result instead of the compact receipt"), from, capability, run, retry]),
            command("check", "Read or wait for coordinator delivery", [flag("terminal", "Terminal handle", "handle"), run, flag("ack", "Acknowledge delivery", "id"), flag("unread", "Unread only"), flag("peek", "Do not mark read"), flag("all", "All messages"), flag("types", "Wake message types", "csv"), flag("format", "Human format", "name"), flag("wait", "Long-poll"), flag("timeout-ms", "Timeout", "ms"), flag("limit", "Maximum results", "n"), retry]),
            command("reply", "Reply to a message", [flag("id", "Message identifier", "id", required: true), flag("body", "Reply body", "text", required: true), from, retry]),
            command("ask", "Ask or resume a blocking question", [flag("question", "Question", "text"), flag("resume", "Question message id", "id"), flag("options", "Comma-separated options", "csv"), flag("timeout-ms", "Timeout", "ms"), from, capability, retry]),
            command("inbox", "List inbox messages", [flag("limit", "Maximum results", "n"), flag("full", "Include full bodies"), flag("terminal", "Terminal handle", "handle"), from, run]),
            command("task-create", "Create a task", [flag("spec", "Task specification", "text", required: true), flag("task-title", "Task title", "text"), flag("display-name", "Display name", "text"), flag("deps", "Dependency JSON", "json"), flag("parent", "Parent task", "id"), from, run, retry]),
            command("task-list", "List tasks", [flag("status", "Filter status", "status"), flag("ready", "Ready tasks only"), flag("brief", "Brief output"), from, run]),
            command("task-update", "Update a task", [flag("id", "Task identifier", "id", required: true), flag("status", "New status", "status", required: true), flag("result", "Result JSON", "json"), retry]),
            command("dispatch", "Dispatch a task", [flag("task", "Task identifier", "id", required: true), flag("to", "Terminal handle", "handle", required: true), flag("inject", "Inject preamble"), flag("dry-run", "Preview only"), flag("return-preamble", "Return preamble"), from, retry]),
            command("dispatch-show", "Show a dispatch", [
                flag("id", "Dispatch identifier", "id", required: true, aliases: ["dispatch"])
            ]),
            command("gate-create", "Create a decision gate", [flag("task", "Task identifier", "id", required: true), flag("question", "Question", "text", required: true), flag("options", "Options JSON", "json"), from, retry]),
            command("gate-resolve", "Resolve a decision gate", [flag("id", "Gate identifier", "id", required: true), flag("resolution", "Resolution", "text", required: true), retry]),
            command("gate-list", "List decision gates", [flag("task", "Task identifier", "id"), flag("status", "Gate status", "status")]),
            command("worker-start", "Start a supervised worker", [flag("task", "Task identifier", "id", required: true), flag("on", "Environment", "environment"), flag("worktree", "Workspace placement", "selector"), enumerated("agent", "Agent engine id or alias", "agent", OrchardAgentEngines.acceptedIdentifiers), flag("terminal", "Existing terminal", "handle"), flag("model", "Model", "id"), flag("effort", "Reasoning effort", "level"), flag("name", "Worktree name", "name"), flag("repo", "Repository", "selector"), flag("base-branch", "Git base", "ref"), flag("setup", "Setup policy", "run|skip|inherit"), flag("retry-of", "Prior dispatch", "id"), flag("timeout-ms", "Agent readiness timeout", "ms"), retry]),
            command("worker-show", "Show a supervised worker", [flag("dispatch", "Dispatch identifier", "id", required: true)]),
            command("worker-read", "Read archived or live worker output", [
                flag("dispatch", "Dispatch identifier", "id", required: true),
                enumerated("source", "Output source; transcript fails typed rather than falling back", "auto|transcript|terminal", ["auto", "transcript", "terminal"]),
                flag("raw", "Serve the untouched capture instead of the chrome-stripped text"),
                flag("cursor", "Paging cursor; combine with --limit to walk older lines", "cursor"),
                flag("limit", "Maximum lines to return (default \(WorkerReadPaging.defaultLimit))", "n"),
            ], notes: [
                "Without --limit, worker-read returns the newest \(WorkerReadPaging.defaultLimit) lines.",
                "hasOlder is true when lines exist before this window; page them with --cursor <startCursor> or --cursor <oldestCursor>.",
                "truncated means the requested cursor was below the retained ring (those older lines are gone), not that hasOlder is true.",
            ]),
            command("worker-stop", "Stop a worker", [flag("dispatch", "Dispatch identifier", "id", required: true), retry]),
            command("worker-abandon", "Abandon uncertain worker resources", [flag("dispatch", "Dispatch identifier", "id", required: true), retry]),
            command("worker-release", "Archive and release worker resources", [flag("dispatch", "Dispatch identifier", "id", required: true), retry]),
            command("worker-retain", "Retain worker resources", [flag("dispatch", "Dispatch identifier", "id", required: true), retry]),
            command("worker-list", "List supervised workers", [flag("terminal-state", "Terminal state filter", "state"), run]),
            // T32: `repo add --host ssh:<name>` registers a checkout that lives on a
            // registered host. The remote path is probed over a bounded ssh run before
            // the record exists, so a repo record is never a claim nobody checked.
            command("repo", "Manage registered repositories", [
                flag("path", "Repository path", "path"),
                flag("repo", "Repository selector", "selector"),
                flag("display-name", "Display name", "text"),
                flag("base-ref", "Default base ref for new worktrees", "ref"),
                flag("host", "Execution host: local (default) or ssh:<name>", "id"),
            ], positionals: ["list|add|show|remove"], notes: [
                "repo remove drops the registry row and orchard-data owned by the repo.",
                "It refuses while extra worktrees or automations still reference the repo (typed repo_in_use, naming them). There is no --force.",
                "A successful remove also rmdirs the empty ~/Orchard/worktrees/<repo>/ container (never recursively).",
            ]),
            CommandSpec(
                name: "worktree",
                summary: "List, inspect, create, update, or remove worktrees; ps shows live processes and ports",
                usage: "orchard worktree list|show|current|create|set|rm|ps [options]",
                flags: [
                    flag("repo", "Repository selector", "selector"),
                    flag("worktree", "Worktree selector", "selector"),
                    flag("limit", "Maximum results", "n"),
                    flag("name", "Worktree name", "name"),
                    flag("display-name", "Display name", "text"),
                    flag("base-branch", "Git base", "ref"),
                    flag("comment", "Comment", "text"),
                    flag("issue", "Linked issue", "text"),
                    flag("pr", "Linked pull request", "text"),
                    // T64: `worktree set --status` is the board column (cardStatus).
                    // `--workspace-status` is the Orca-shaped alias; both store as `status`.
                    flag("status",
                         "Board column: todo|in-progress|in-review|completed or a custom id",
                         "status",
                         aliases: ["workspace-status"]),
                    flag("parent-worktree", "Parent worktree", "selector"),
                    flag("no-parent", "Do not nest under a parent"),
                    flag("force", "Force remove a dirty worktree"),
                    flag("delete-branch", "After a successful removal, delete the worktree's branch (git branch -d)"),
                    flag("force-branch", "Force-delete an unmerged branch (git branch -D); implies --delete-branch"),
                    flag("cwd", "Working directory for resolution", "path"),
                    flag("pinned", "Pinned"),
                    flag("unread", "Unread"),
                    flag("archived", "Archived"),
                    enumerated("agent", "Launch this agent in the new worktree's first terminal", "agent",
                               OrchardAgentEngines.acceptedIdentifiers),
                    flag("prompt", "Initial prompt sent to --agent", "text"),
                    flag("run-hooks", "Run the repo's orchard.yaml setup script after create"),
                    json,
                ],
                positionalArgs: ["list|show|current|create|set|rm|ps"],
                examples: [
                    "orchard worktree list [--repo <selector>]",
                    "orchard worktree show --worktree <selector>",
                    "orchard worktree current",
                    "orchard worktree create --repo <selector> --name <name>",
                    "orchard worktree set --worktree <selector> --status in-review",
                    "orchard worktree rm --worktree <selector> [--force] [--delete-branch]",
                    "orchard worktree ps [--limit <n>]",
                ],
                notes: [
                    "Subverbs: list, show, current, create, set, rm (aliases: remove, delete), ps.",
                    "worktree current resolves the current directory to the enclosing managed workspace.",
                    "create infers --repo from the current worktree when omitted.",
                    "worktree set --status <id> writes the user-authored board column (todo, in-progress, in-review, completed, or a custom vocabulary id).",
                    "Board column is distinct from derived live status (active|working|permission|done|inactive).",
                    "worktree rm rmdirs ~/Orchard/worktrees/<repo>/ when that container is empty; it never deletes recursively.",
                    "worktree ps is the compact process+ports listing; workspace-ports is the ports-only view.",
                ]),
            CommandSpec(
                name: "project",
                summary: "List and show registered projects (repos) and their worktrees",
                usage: "orchard project list|show|current [options]",
                flags: [
                    flag("project", "Project selector (repo id, name, or path)", "selector",
                         aliases: ["repo"]),
                    flag("cwd", "Working directory for project current", "path"),
                    json,
                ],
                positionalArgs: ["list|show|current"],
                examples: [
                    "orchard project list",
                    "orchard project show --project <selector>",
                    "orchard project current",
                ],
                notes: [
                    "A project is a registered repo. project list is the grouping view; repo add|remove is how checkouts join or leave the registry.",
                    "project show --project <selector> returns the repo record plus its worktrees.",
                    "project current resolves the current directory to the enclosing project's repo.",
                    "Host-setup verbs (setups, setup-clone, setup-create, …) are not implemented: register a checkout with repo add, including --host ssh:<name> for a remote.",
                ]),
            command("workspace-ports", "List listening TCP ports attributed to workspaces", [
                flag("repo", "Repository selector", "selector"),
                flag("worktree", "Worktree selector", "selector"),
            ]),
            command("file", "Open, diff, search, or reveal git-changed workspace files", [
                flag("path", "File path relative to the worktree (or absolute inside it)", "path"),
                flag("worktree", "Worktree selector", "selector"),
                flag("staged", "Accepted for parity; diffs are always vs the fork point"),
                flag("mode", "open-changed mode: edit, diff, or both (default diff)", "edit|diff|both"),
                flag("include", "Content-search include glob (e.g. *.swift)", "glob"),
                flag("exclude", "Content-search exclude glob", "glob"),
                flag("limit", "Maximum content-search matches", "n"),
            ], positionals: ["open|diff|open-changed|search", "path|query"]),
            CommandSpec(
                name: "conflicts",
                summary: "List, inspect, and resolve git merge conflicts in a worktree",
                usage: "orchard conflicts list|show|take|resolve|stage [options]",
                flags: [
                    flag("worktree", "Worktree selector", "selector"),
                    flag("path", "Repo-relative conflicted path", "path"),
                    enumerated("side", "Whole-file side for take", "ours|theirs",
                               ["ours", "theirs"]),
                    flag("hunk", "Hunk index as reported by conflicts show (0-based)", "n"),
                    enumerated("choice", "Per-hunk choice for resolve", "ours|theirs|both",
                               ["ours", "theirs", "both"]),
                    flag("cwd", "Working directory for worktree resolution", "path"),
                    json,
                ],
                positionalArgs: ["list|show|take|resolve|stage"],
                examples: [
                    "orchard conflicts list --worktree <selector>",
                    "orchard conflicts show --path src/a.swift --worktree <selector>",
                    "orchard conflicts take --path src/a.swift --side ours --worktree <selector>",
                    "orchard conflicts resolve --path src/a.swift --hunk 0 --choice theirs --worktree <selector>",
                    "orchard conflicts stage --path src/a.swift --worktree <selector>",
                ],
                notes: [
                    "Typed errors: invalid_argument, not_conflicted, hunk_not_found, cannot_read, conflict_markers_remain, remote_unsupported, git_error.",
                    "conflicts stage refuses while conflict markers remain — it never stages a lie.",
                    "This surface resolves files only. Finish the merge/rebase with git commit or git rebase --continue in a terminal.",
                    "On a rebase, ours is the upstream and theirs is the replayed commit.",
                    "Hunk indexes are 0-based as printed by conflicts show; after a partial resolve they are re-indexed from 0.",
                    "Binary files and kinds without inline markers have no hunks — use conflicts take.",
                ]),
            command("terminal", "List, create, inspect, and control runtime terminals", [
                flag("worktree", "Worktree selector for list or create", "selector"),
                flag("terminal", "Terminal handle", "handle"),
                flag("title", "Terminal title", "text"),
                enumerated("engine", "Terminal engine id or alias (default shell)", "engine",
                           OrchardAgentEngines.acceptedIdentifiers),
                flag("prompt", "Initial agent prompt", "text"),
                flag("cwd", "Initial working directory", "path"),
                flag("cursor", "Stream cursor for incremental reads", "n"),
                flag("screen", "Read the rendered terminal screen"),
                flag("limit", "Maximum lines to read", "n"),
                flag("text", "Text to send", "text"),
                flag("enter", "Send Enter after text"),
                flag("interrupt", "Send an interrupt"),
                flag("for", "Wait condition", "tui-idle|exit"),
                flag("timeout-ms", "Wait timeout in milliseconds", "ms"),
                // T29/T32: a pane on a registered host. Opening one in a remote worktree
                // needs no flag — the pane inherits the workspace's stamped host.
                flag("host", "Execution host: local (default) or ssh:<name>", "id"),
                // T43: `reconnect` addresses a pane whose connection ended, and after a
                // restart the handle a caller remembers belongs to a previous app run —
                // the paneKey is the identity that survived.
                flag("pane", "Durable pane key (terminal reconnect)", "paneKey"),
            ], positionals: ["list|create|read|send|wait|split|close|rename|reconnect"]),
            // T10 embedded browser. Refs (@eN) come from the latest `snapshot` of a
            // page and are invalidated by any navigation (top-level or subframe) —
            // re-snapshot, don't guess. T21 session profiles: `tab profile
            // list|create|set|show` partitions cookies/storage per profile.
            command("browser", "Drive a workspace's embedded browser", [flag("worktree", "Workspace selector", "selector", required: true), flag("page", "Browser tab id", "id"), flag("url", "Destination URL", "url"), flag("ref", "Snapshot element ref (@eN)", "ref"), flag("text", "Text for fill/type", "text"), flag("js", "JavaScript expression for eval", "expr"), flag("limit", "Maximum console entries", "n"), flag("label", "Profile label for `tab profile create`", "text"), flag("profile", "Profile id or label for `tab profile set`", "id")], positionals: ["goto|back|forward|reload|snapshot|click|fill|type|screenshot|eval|console|tab", "tab: list|create|close|switch|profile", "profile: list|create|set|show"]),
            command("automations", "Manage scheduled prompts", [
                flag("id", "Automation identifier", "id"),
                flag("name", "Unique display name", "text"),
                flag("trigger", "Schedule kind", "once|hourly|daily|weekdays|weekly|five-field-cron"),
                flag("time", "ISO date, HH:mm, `now` (once), or quoted five-field cron expression", "schedule"),
                flag("day", "Weekly weekday (Sunday 0 through Saturday 6)", "n"),
                flag("provider", "Agent provider identifier", "agent"),
                flag("prompt", "Prompt delivered when fired", "text"),
                flag("repo", "Repository selector; creates a fresh top-level worktree", "selector"),
                flag("workspace", "Workspace selector; reuses its agent terminal", "selector"),
                flag("precheck", "Bounded shell command; nonzero skips the run", "command"),
                flag("timeout", "Precheck timeout seconds (1...300)", "n"),
                flag("enabled", "Enable the automation (default on create)"),
                flag("disabled", "Disable the automation"),
            ], positionals: ["list|show|create|edit|remove|run|runs|due|fire-due"], notes: [
                "Typed errors: automation_not_found, automation_invalid_input, automation_disabled, automation_fire_in_flight.",
                "run --id on a disabled automation (including a consumed once schedule) is refused as automation_disabled.",
            ]),
            // T29 remote hosts. `host check` is bounded: it reports
            // reachable|auth-required|unreachable and never waits on a human, because
            // BatchMode makes OpenSSH fail instead of prompting. Unreachable is loss of
            // contact, never evidence that anything on the host stopped.
            // T45: `host list` also shows the last periodic probe and its age when a
            // remote repo or remote pane has kept the producer awake.
            command("host", "Register and probe remote SSH hosts", [
                flag("name", "Host name (an ~/.ssh/config alias, or your own label)", "name"),
                flag("hostname", "Hostname or address to connect to", "host"),
                flag("user", "Login user", "user"),
                flag("port", "Port (default 22)", "n"),
                flag("import", "With no name, list importable ~/.ssh/config hosts; with a name, import it"),
            ], positionals: ["list|add|check", "name"],
               notes: [
                   "host list shows live status (reachable|auth-required|unreachable) and how long ago it was checked, when a remote repo or remote pane exists.",
                   "Unreachable is loss of contact, never evidence that anything on the host stopped. A status change updates host presentation only.",
               ]),
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
    case worktree     // worktree list/show/current/create/set/rm/ps
    case project      // project list/show/current
    case repo         // repo list/add/show/remove
    case file         // file open/diff/open-changed/search
    case conflicts    // conflicts list/show/take/resolve/stage
    case browser      // browser goto/…/tab (wave 2)
    case host         // host list/add/check (T29 remote hosts)
    case automations  // scheduled prompts
    case guide        // agent-context, guide get <topic>
}
