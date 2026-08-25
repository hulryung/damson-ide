import Foundation

public enum CommandHelpRenderer {
    public static func render(_ spec: CommandSpec) -> String {
        let usage = spec.usage ?? "orchard \(spec.name) [options]"
        var lines = [spec.summary, "", "Usage:", "  \(usage)"]

        if !spec.aliases.isEmpty {
            lines += ["", "Aliases:", "  " + spec.aliases.joined(separator: ", ")]
        }
        if !spec.positionalArgs.isEmpty {
            lines += ["", "Positionals:"]
            lines += spec.positionalArgs.map { "  \($0)" }
        }
        if !spec.flags.isEmpty {
            lines += ["", "Flags:"]
            let labels = spec.flags.map { flagLabel($0) }
            let width = labels.map(\.count).max() ?? 0
            for (flag, label) in zip(spec.flags, labels) {
                let required = flag.required ? " (required)" : ""
                let aliasNote: String
                if flag.aliases.isEmpty {
                    aliasNote = ""
                } else {
                    let listed = flag.aliases.map { "--\($0)" }.joined(separator: ", ")
                    aliasNote = flag.aliases.count == 1
                        ? "; alias: \(listed)"
                        : "; aliases: \(listed)"
                }
                let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("  \(padded)  \(flag.summary)\(required)\(aliasNote)")
            }
            let helpPadding = String(repeating: " ", count: max(1, width - 10))
            lines.append("  -h, --help\(helpPadding)  Show this help")
        }
        if !spec.examples.isEmpty {
            lines += ["", "Examples:"]
            lines += spec.examples.map { "  \($0)" }
        }
        if !spec.notes.isEmpty {
            lines += ["", "Notes:"]
            lines += spec.notes.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    private static func flagLabel(_ flag: FlagSpec) -> String {
        "--\(flag.name)" + (flag.valueHint.map { " <\($0)>" } ?? "")
    }
}

public enum OrchardHumanFormatter {
    /// Pretty JSON for verbs that have no dedicated human layout. The previous
    /// fallback was `String(describing:)` of `JSONValue`, which printed a Swift
    /// debug dump (`object(["type": OrchardProtocol.JSONValue.string(...)])`)
    /// into worker terminals (dogfood-2).
    public static func json(_ result: JSONValue?) -> String {
        guard let result else { return "ok" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result),
              let text = String(data: data, encoding: .utf8) else { return "ok" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compact receipt for `orchard send` without `--json`. `--verbose` prints the
    /// pretty JSON result instead — never `String(describing:)` of `JSONValue`,
    /// which is the dogfood-2 Swift-debug leak.
    public static func send(_ result: JSONValue?, verbose: Bool = false) -> String {
        if verbose { return json(result) }
        let object = result?.objectValue ?? [:]
        let type = object["type"]?.stringValue ?? "message"
        let count = object["count"]?.numberValue.map { Int($0) } ?? 0
        var parts: [String] = count <= 1 ? ["sent \(type)"] : ["sent \(type) ×\(count)"]
        if let run = object["runId"]?.stringValue { parts.append("run:\(run)") }
        if let lifecycle = object["lifecycle"]?.objectValue {
            if let status = lifecycle["status"]?.stringValue { parts.append(status) }
            if let outcome = lifecycle["outcome"]?.stringValue { parts.append(outcome) }
            if let task = lifecycle["taskId"]?.stringValue { parts.append("task:\(task)") }
            if let dispatch = lifecycle["dispatchId"]?.stringValue {
                parts.append("dispatch:\(dispatch)")
            }
            if let reason = lifecycle["reason"]?.stringValue, !reason.isEmpty {
                parts.append("reason:\(reason)")
            }
        }
        if let ids = object["messageIds"]?.arrayValue?.compactMap(\.stringValue),
           ids.count == 1 {
            parts.append("id:\(ids[0])")
        }
        return parts.joined(separator: "  ")
    }

    public static func worktreeList(_ result: JSONValue?) -> String {
        let object = result?.objectValue
        let rows = object?["worktrees"]?.arrayValue ?? []
        var lines: [String] = []
        if rows.isEmpty {
            lines.append("No worktrees found.")
        } else {
            let headings = ["NAME", "BRANCH", "HOST", "PATH"]
            let values = rows.map { value -> [String] in
                let row = value.objectValue ?? [:]
                return [
                    row["displayName"]?.stringValue ?? row["name"]?.stringValue ?? "?",
                    row["branch"]?.stringValue ?? "-",
                    row["hostId"]?.stringValue ?? "local",
                    row["path"]?.stringValue ?? "",
                ]
            }
            let widths = headings.indices.map { index in
                ([headings[index]] + values.map { $0[index] }).map(\.count).max() ?? 0
            }
            lines += ([headings] + values).map { row in
                row.indices.map { index in
                    index == row.count - 1 ? row[index] : row[index].padding(toLength: widths[index], withPad: " ", startingAt: 0)
                }.joined(separator: "  ")
            }
        }
        if let warning = object?["warning"]?.stringValue, !warning.isEmpty {
            // Remote `worktree-list`: an unreachable host returns the last-known set
            // plus this warning. JSON-only until T36/T53; keep it on the human face.
            let stale = warning.localizedCaseInsensitiveContains("last known")
            lines += ["", stale ? "Warning (stale): \(warning)" : "Warning: \(warning)"]
        }
        if object?["truncated"]?.boolValue == true {
            let total = object?["totalCount"]?.numberValue.map(Int.init) ?? rows.count
            lines += ["", "Truncated: showing \(rows.count) of \(total)."]
        }
        return lines.joined(separator: "\n")
    }

    /// Compact receipt for `orchard worktree rm` without `--json`.
    public static func worktreeRm(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let removed = object["removed"]?.boolValue == true
        let branch = object["branch"]?.stringValue ?? ""
        let branchDeleted = object["branchDeleted"]?.boolValue == true
        var line: String
        if !removed {
            line = "Worktree was not removed."
        } else if branchDeleted {
            line = "Removed worktree. Deleted branch '\(branch)'."
        } else if !branch.isEmpty {
            line = "Removed worktree. Branch '\(branch)' was kept."
        } else {
            line = "Removed worktree."
        }
        if let warning = object["warning"]?.stringValue, !warning.isEmpty {
            line += "\nWarning: \(warning)"
        }
        return line
    }

    /// `orchard host list` without `--json`. Live status + age when the periodic
    /// producer (or a `host check`) has published; otherwise the registry row only.
    public static func hostList(_ result: JSONValue?) -> String {
        let hosts = result?.objectValue?["hosts"]?.arrayValue ?? []
        if hosts.isEmpty { return "No hosts registered. Try: orchard host add --import" }
        return hosts.map { item -> String in
            let host = item.objectValue ?? [:]
            let name = host["name"]?.stringValue ?? "?"
            let target = host["target"]?.stringValue ?? ""
            let source = host["source"]?.stringValue ?? "manual"
            let id = host["executionHostId"]?.stringValue ?? "ssh:\(name)"
            var parts = ["\(name)  \(target)  \(source)  \(id)"]
            if let status = host["status"]?.stringValue {
                parts.append(status)
                if let age = host["ageSeconds"]?.numberValue {
                    parts.append(ageLabel(seconds: age))
                }
            }
            return parts.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    public static func ageLabel(seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// Compact receipt for `orchard repo remove` without `--json`.
    public static func repoRemove(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let nested = object["repo"]?.objectValue ?? [:]
        let name = object["displayName"]?.stringValue
            ?? nested["displayName"]?.stringValue
            ?? object["path"]?.stringValue
            ?? nested["path"]?.stringValue
            ?? "repo"
        if object["removed"]?.boolValue == true {
            return "Removed repo '\(name)'."
        }
        return "Repo '\(name)' was not removed."
    }
}

/// Process exit for a runtime RPC envelope. Typed errors (`ok: false`) are a
/// failed process even when `--json` printed the envelope — dogfood-3/4 found
/// that path used to fall through to status 0.
public enum CLIEnvelopeExit {
    public static let success: Int32 = 0
    public static let typedError: Int32 = 1
    public static let usage: Int32 = 64

    public static func status(for response: RPCResponse) -> Int32 {
        response.ok ? success : typedError
    }
}

public enum GuideTopicFormatter {
    public static func render(_ topics: [String]) -> String {
        topics.joined(separator: "\n")
    }
}
