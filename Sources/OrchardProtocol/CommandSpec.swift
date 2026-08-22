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
    case guide        // agent-context, guide get <topic>
}
