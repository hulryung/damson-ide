import Foundation
import OrchardProtocol

// orchard — the agent-facing CLI (v2). Replaces v1's `orchard-cli`.
//
// T0 ships the offline surface only: `agent-context` and `version` work with no runtime
// running (that property is a hard requirement — see docs/REBUILD-PLAN.md). T2 adds the
// declarative-spec arg parser, the unix-socket client transport with keepalive-aware
// timeouts, `guide get <topic>`, and the full verb set.

let toolVersion = "2.0.0-dev"

/// The T0 command table: only what the binary can honestly serve today. T2 replaces this
/// with the full spec table that `agent-context` and the arg parser share.
let commandTable: [CommandSpec] = [
    CommandSpec(
        name: "agent-context",
        summary: "Serialize the full command table as JSON (works with no runtime)",
        usage: "orchard agent-context --json",
        flags: [FlagSpec(name: "json", summary: "Emit machine-readable JSON")]),
    CommandSpec(
        name: "version",
        summary: "Print the orchard CLI version",
        usage: "orchard version"),
]

func printUsage(to handle: FileHandle) {
    var out = "usage: orchard <command>\n\ncommands:\n"
    for spec in commandTable {
        out += "  \(spec.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(spec.summary)\n"
    }
    out += "\nThe full v2 verb surface (run/task/dispatch/worker/terminal/worktree/…) lands in wave 1.\n"
    handle.write(Data(out.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "agent-context":
    let document = AgentContextDocument(commands: commandTable)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(document)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
case "version", "--version":
    print("orchard \(toolVersion)")
case nil, "help", "--help":
    printUsage(to: FileHandle.standardOutput)
default:
    FileHandle.standardError.write(Data("orchard: unknown command '\(arguments[0])'\n".utf8))
    printUsage(to: FileHandle.standardError)
    exit(64) // EX_USAGE
}
