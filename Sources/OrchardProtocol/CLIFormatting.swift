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
                let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("  \(padded)  \(flag.summary)\(required)")
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
            lines += ["", "Warning: \(warning)"]
        }
        if object?["truncated"]?.boolValue == true {
            let total = object?["totalCount"]?.numberValue.map(Int.init) ?? rows.count
            lines += ["", "Truncated: showing \(rows.count) of \(total)."]
        }
        return lines.joined(separator: "\n")
    }
}

public enum GuideTopicFormatter {
    public static func render(_ topics: [String]) -> String {
        topics.joined(separator: "\n")
    }
}
