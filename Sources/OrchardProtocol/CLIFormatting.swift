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

    /// Compact receipt for `orchard worktree show|current` without `--json`.
    public static func worktreeShow(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let wt = object["worktree"]?.objectValue ?? object
        let name = wt["displayName"]?.stringValue ?? wt["name"]?.stringValue ?? "?"
        let branch = wt["branch"]?.stringValue ?? ""
        let host = wt["hostId"]?.stringValue ?? "local"
        let path = wt["path"]?.stringValue ?? ""
        let id = wt["id"]?.stringValue ?? ""
        var lines = ["\(name)  \(branch)  \(host)"]
        if !path.isEmpty { lines.append(path) }
        if !id.isEmpty { lines.append("id  \(id)") }
        if let status = wt["workspaceStatus"]?.stringValue, !status.isEmpty {
            lines.append("status  \(status)")
        }
        if let comment = wt["comment"]?.stringValue, !comment.isEmpty {
            lines.append("comment  \(comment)")
        }
        return lines.joined(separator: "\n")
    }

    /// Compact receipt for `orchard worktree create` without `--json`.
    public static func worktreeCreate(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let wt = object["worktree"]?.objectValue ?? [:]
        let name = wt["displayName"]?.stringValue ?? wt["name"]?.stringValue ?? "worktree"
        let branch = wt["branch"]?.stringValue ?? ""
        let path = wt["path"]?.stringValue ?? ""
        var line = "Created worktree '\(name)'"
        if !branch.isEmpty { line += " on \(branch)" }
        if !path.isEmpty { line += " at \(path)" }
        line += "."
        if let handle = object["agentTerminalHandle"]?.stringValue, !handle.isEmpty {
            line += " Agent terminal \(handle)."
        }
        if let warning = object["warning"]?.stringValue, !warning.isEmpty {
            line += "\nWarning: \(warning)"
        }
        return line
    }

    /// Compact receipt for `orchard project list` without `--json`.
    public static func projectList(_ result: JSONValue?) -> String {
        let rows = result?.objectValue?["projects"]?.arrayValue ?? []
        if rows.isEmpty { return "No projects registered." }
        let headings = ["NAME", "HOST", "KIND", "WORKTREES", "PATH"]
        let values = rows.map { value -> [String] in
            let row = value.objectValue ?? [:]
            let count = row["worktreeCount"]?.numberValue.map { String(Int($0)) } ?? "0"
            return [
                row["displayName"]?.stringValue ?? "?",
                row["hostId"]?.stringValue ?? "local",
                row["kind"]?.stringValue ?? "git",
                count,
                row["path"]?.stringValue ?? "",
            ]
        }
        let widths = headings.indices.map { index in
            ([headings[index]] + values.map { $0[index] }).map(\.count).max() ?? 0
        }
        return ([headings] + values).map { row in
            row.indices.map { index in
                index == row.count - 1 ? row[index] : row[index].padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// Compact receipt for `orchard project show|current` without `--json`.
    public static func projectShow(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let project = object["project"]?.objectValue ?? object
        let name = project["displayName"]?.stringValue ?? "?"
        let host = project["hostId"]?.stringValue ?? "local"
        let kind = project["kind"]?.stringValue ?? "git"
        let path = project["path"]?.stringValue ?? ""
        let id = project["id"]?.stringValue ?? ""
        var lines = ["\(name)  \(kind)  \(host)"]
        if !path.isEmpty { lines.append(path) }
        if !id.isEmpty { lines.append("id  \(id)") }
        if let base = project["baseRef"]?.stringValue, !base.isEmpty {
            lines.append("base  \(base)")
        }
        let worktrees = object["worktrees"]?.arrayValue ?? []
        if worktrees.isEmpty {
            lines.append("No worktrees.")
        } else {
            lines.append("worktrees  \(worktrees.count)")
            for item in worktrees {
                let wt = item.objectValue ?? [:]
                let wtName = wt["displayName"]?.stringValue ?? "?"
                let branch = wt["branch"]?.stringValue ?? "-"
                lines.append("  \(wtName)  \(branch)")
            }
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

    // MARK: - checks (T88)

    /// How old a reading is, in words. Printed on every checks line: the contract
    /// is that a cached answer is never shown as if it had just been taken.
    public static func checksAge(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "age unknown" }
        if seconds < 2 { return "just now" }
        if seconds < 90 { return "\(Int(seconds))s ago" }
        if seconds < 5400 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }

    public static func checksList(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let age = checksAge(object["ageSeconds"]?.numberValue)
        let branch = object["branch"]?.stringValue ?? "(no branch)"
        var lines: [String] = []

        if object["status"]?.stringValue != "available" {
            let reason = object["unavailable"]?.objectValue ?? [:]
            let code = reason["code"]?.stringValue ?? "unknown"
            lines.append("\(reason["headline"]?.stringValue ?? "Checks unavailable") "
                + "[\(code)]  \(branch) · checked \(age)")
            if let detail = reason["detail"]?.stringValue, !detail.isEmpty {
                lines.append("  \(detail)")
            }
            if let remedy = reason["remedy"]?.stringValue, !remedy.isEmpty {
                lines.append("  \(remedy)")
            }
            return lines.joined(separator: "\n")
        }

        let pr = object["pullRequest"]?.objectValue ?? [:]
        let number = pr["number"]?.numberValue.map(Int.init) ?? 0
        let draft = pr["isDraft"]?.boolValue == true ? " (draft)" : ""
        lines.append("#\(number) \(pr["title"]?.stringValue ?? "")\(draft)")
        lines.append("  \(pr["state"]?.stringValue ?? "?") · \(branch) · "
            + "\(object["rollupLabel"]?.stringValue ?? "") · checked \(age)")
        if let url = pr["url"]?.stringValue, !url.isEmpty { lines.append("  \(url)") }

        let checks = object["checks"]?.arrayValue ?? []
        if checks.isEmpty {
            lines.append("  (no checks reported on this pull request)")
        }
        for check in checks {
            let row = check.objectValue ?? [:]
            let bucket = (row["bucket"]?.stringValue ?? "unknown")
                .padding(toLength: 9, withPad: " ", startingAt: 0)
            let name = row["name"]?.stringValue ?? "?"
            let workflow = row["workflow"]?.stringValue
            let suffix = (workflow?.isEmpty == false) ? "  (\(workflow!))" : ""
            lines.append("  \(bucket) \(name)\(suffix)")
        }
        let links = object["links"]?.arrayValue ?? []
        if !links.isEmpty {
            let rendered = links.map { link -> String in
                let row = link.objectValue ?? [:]
                return "\(row["kind"]?.stringValue ?? "?"):\(row["raw"]?.stringValue ?? "")"
            }
            lines.append("  links: " + rendered.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func checksShow(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let check = object["check"]?.objectValue ?? [:]
        let name = check["name"]?.stringValue ?? "?"
        let bucket = check["bucketLabel"]?.stringValue ?? check["bucket"]?.stringValue ?? "?"
        var lines = ["\(name) — \(bucket)"]
        if let conclusion = check["conclusion"]?.stringValue, !conclusion.isEmpty {
            let status = check["status"]?.stringValue ?? ""
            lines.append("  github: \(status.isEmpty ? conclusion : "\(status)/\(conclusion)")")
        }
        if let url = check["detailsUrl"]?.stringValue, !url.isEmpty { lines.append("  \(url)") }

        if object["status"]?.stringValue != "available" {
            lines.append("  \(object["headline"]?.stringValue ?? "No log") "
                + "[\(object["reason"]?.stringValue ?? "unknown")]")
            if let detail = object["detail"]?.stringValue, !detail.isEmpty {
                lines.append("  \(detail)")
            }
            if let remedy = object["remedy"]?.stringValue, !remedy.isEmpty {
                lines.append("  \(remedy)")
            }
            return lines.joined(separator: "\n")
        }
        if object["truncated"]?.boolValue == true {
            lines.append("  log: last \(object["returnedLines"]?.numberValue.map(Int.init) ?? 0) of "
                + "\(object["totalLines"]?.numberValue.map(Int.init) ?? 0) lines")
        } else {
            lines.append("  log: \(object["totalLines"]?.numberValue.map(Int.init) ?? 0) lines")
        }
        lines.append("")
        lines.append(object["log"]?.stringValue ?? "")
        return lines.joined(separator: "\n")
    }

    public static func conflictsList(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let headline = object["headline"]?.stringValue ?? "No conflicts"
        var lines = [headline]
        let files = object["files"]?.arrayValue ?? []
        for file in files {
            let row = file.objectValue ?? [:]
            let code = row["kindCode"]?.stringValue ?? "??"
            let path = row["path"]?.stringValue ?? "?"
            let label = row["kindLabel"]?.stringValue ?? ""
            lines.append("  \(code)  \(path)  \(label)")
        }
        if let hint = object["nextStepHint"]?.stringValue, !hint.isEmpty {
            lines.append(hint)
        }
        return lines.joined(separator: "\n")
    }

    public static func conflictsShow(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let path = object["path"]?.stringValue ?? "?"
        let kind = object["kindLabel"]?.stringValue ?? object["kind"]?.stringValue ?? ""
        let code = object["kindCode"]?.stringValue ?? ""
        var header = path
        if !kind.isEmpty {
            header += "  \(kind)"
            if !code.isEmpty { header += " (\(code))" }
        }
        var lines = [header]
        let hunks = object["hunks"]?.arrayValue ?? []
        if hunks.isEmpty {
            if object["readable"]?.boolValue == false {
                lines.append("  not readable as text; use conflicts take --side ours|theirs")
            } else {
                lines.append("  no inline hunks; use conflicts take --side ours|theirs")
            }
            if let ours = object["actionOurs"]?.stringValue { lines.append("  ours: \(ours)") }
            if let theirs = object["actionTheirs"]?.stringValue { lines.append("  theirs: \(theirs)") }
        } else {
            for hunk in hunks {
                let row = hunk.objectValue ?? [:]
                let index = row["index"]?.numberValue.map { Int($0) } ?? 0
                let start = row["startLine"]?.numberValue.map { Int($0) } ?? 0
                lines.append("  hunk \(index)  line \(start)")
                let oursLabel = row["oursLabel"]?.stringValue ?? "ours"
                lines.append("    ours (\(oursLabel)):")
                for line in row["ours"]?.arrayValue ?? [] {
                    lines.append("      \(line.stringValue ?? "")")
                }
                if let base = row["base"]?.arrayValue {
                    let baseLabel = row["baseLabel"]?.stringValue ?? "base"
                    lines.append("    base (\(baseLabel)):")
                    for line in base { lines.append("      \(line.stringValue ?? "")") }
                }
                let theirsLabel = row["theirsLabel"]?.stringValue ?? "theirs"
                lines.append("    theirs (\(theirsLabel)):")
                for line in row["theirs"]?.arrayValue ?? [] {
                    lines.append("      \(line.stringValue ?? "")")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func conflictsTake(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let path = object["path"]?.stringValue ?? "?"
        let side = object["side"]?.stringValue ?? "side"
        if object["deleted"]?.boolValue == true {
            return "Took \(side) for \(path) (deleted, staged)."
        }
        return "Took \(side) for \(path) (staged)."
    }

    public static func conflictsResolve(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let path = object["path"]?.stringValue ?? "?"
        let hunk = object["hunk"]?.numberValue.map { Int($0) } ?? 0
        let choice = object["choice"]?.stringValue ?? "choice"
        if object["staged"]?.boolValue == true {
            return "Resolved hunk \(hunk) of \(path) as \(choice) (staged)."
        }
        let remaining = object["remainingHunks"]?.numberValue.map { Int($0) } ?? 0
        let noun = remaining == 1 ? "hunk" : "hunks"
        return "Resolved hunk \(hunk) of \(path) as \(choice) (\(remaining) \(noun) remaining, not staged)."
    }

    public static func conflictsStage(_ result: JSONValue?) -> String {
        let path = result?.objectValue?["path"]?.stringValue ?? "?"
        return "Staged \(path)."
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
        if object["forgotten"]?.boolValue == true {
            return "Forgot repo '\(name)' (registry only; host untouched)."
        }
        if object["removed"]?.boolValue == true {
            return "Removed repo '\(name)'."
        }
        return "Repo '\(name)' was not removed."
    }

    /// T94. What `orchard pr <verb>` prints when something actually landed.
    ///
    /// Only the success path reaches here: a refusal, a pending mergeability and
    /// an unconfirmed destructive verb all come back `ok: false`, and the CLI
    /// prints those on stderr with their code. So this formatter has exactly one
    /// job — say what happened, past tense, naming the pull request — and it
    /// never has to hedge.
    public static func pullRequestAction(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        var lines: [String] = []
        lines.append(object["summary"]?.stringValue ?? "Done.")
        if let detail = object["detail"]?.stringValue, !detail.isEmpty {
            lines.append("  \(detail)")
        }
        if let url = object["url"]?.stringValue, !url.isEmpty {
            lines.append("  \(url)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Process exit for a runtime RPC envelope. Typed errors (`ok: false`) are a
/// failed process even when `--json` printed the envelope — dogfood-3/4 found
/// that path used to fall through to status 0.
// MARK: - pull requests (T92)

public extension OrchardHumanFormatter {

    /// `orchard pr eligibility`. A refusal is printed the way `orchard checks`
    /// prints an unavailable reading — headline, code, gh's own words, the one
    /// thing to do — because it is the same kind of answer.
    static func pullRequestEligibility(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let head = object["head"]?.stringValue ?? "(no branch)"
        let base = object["base"]?.stringValue
        var lines: [String] = []

        if let refusal = object["refusal"]?.objectValue {
            let code = refusal["code"]?.stringValue ?? "unknown"
            let route = base.map { "\(head) → \($0)" } ?? head
            lines.append("\(refusal["headline"]?.stringValue ?? "Cannot open a pull request") "
                + "[\(code)]  \(route)")
            if let detail = refusal["detail"]?.stringValue, !detail.isEmpty {
                lines.append("  \(detail)")
            }
            if let remedy = refusal["remedy"]?.stringValue, !remedy.isEmpty {
                lines.append("  \(remedy)")
            }
        } else {
            lines.append("Ready to open a pull request")
            lines.append("  \(head) → \(base ?? "?")\(commitsSuffix(object))")
        }

        if object["needsPush"]?.boolValue == true {
            lines.append("  push required — nothing has been pushed for you")
        }
        lines.append("  " + existingLine(object))
        if object["hasTemplate"]?.boolValue == true {
            lines.append("  a pull-request template was found and is offered as the body")
        }
        return lines.joined(separator: "\n")
    }

    /// The lookup's three states, spelled out. `unavailable` is never printed as
    /// "no pull request": the whole point of the third state is that it reads
    /// differently from the second.
    private static func existingLine(_ object: [String: JSONValue]) -> String {
        switch object["existingLookup"]?.stringValue {
        case "found":
            guard let existing = object["existing"]?.objectValue else {
                return "an existing pull request was found"
            }
            let number = existing["number"]?.numberValue.map { Int($0) } ?? 0
            return "existing pull request #\(number) \(existing["url"]?.stringValue ?? "")"
        case "notFound":
            return "GitHub reports no pull request for this branch"
        default:
            return "existing pull request: could not ask — this is not the same as none"
        }
    }

    private static func commitsSuffix(_ object: [String: JSONValue]) -> String {
        guard let count = object["commitsAhead"]?.numberValue.map({ Int($0) }) else {
            return " · commits not counted"
        }
        return " · \(count) commit\(count == 1 ? "" : "s") ahead"
    }

    static func pullRequestCreate(_ result: JSONValue?) -> String {
        let object = result?.objectValue ?? [:]
        let number = object["number"]?.numberValue.map { Int($0) } ?? 0
        let draft = object["isDraft"]?.boolValue == true ? " (draft)" : ""
        var lines = ["Opened #\(number)\(draft) \(object["title"]?.stringValue ?? "")"]
        lines.append("  \(object["head"]?.stringValue ?? "?") → "
            + "\(object["base"]?.stringValue ?? "?") on \(object["repository"]?.stringValue ?? "?")")
        if let url = object["url"]?.stringValue, !url.isEmpty { lines.append("  \(url)") }
        return lines.joined(separator: "\n")
    }
}

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
