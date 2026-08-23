import Darwin
import Foundation
import OrchardProtocol
import OrchardOrchestration

let toolVersion = "2.0.0-dev"
struct ParsedCommand { let spec: CommandSpec; let params: [String: JSONValue]; let json: Bool }
enum CLIError: Error, CustomStringConvertible {
    case usage(String), runtime(String)
    var description: String { switch self { case .usage(let v), .runtime(let v): return v } }
}

func parse(_ arguments: [String]) throws -> ParsedCommand {
    guard let name = arguments.first, let spec = OrchardCommands.all.first(where: { $0.name == name || $0.aliases.contains(name) }) else { throw CLIError.usage("unknown or missing command") }
    var params: [String: JSONValue] = [:], positionals: [JSONValue] = []; var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument.hasPrefix("--") {
            let name = String(argument.dropFirst(2))
            guard let flag = spec.flags.first(where: { $0.name == name }) else { throw CLIError.usage("unknown flag --\(name) for \(spec.name)") }
            if flag.valueHint == nil { params[name] = .bool(true) }
            else { index += 1; guard index < arguments.count else { throw CLIError.usage("--\(name) requires a value") }; params[name] = jsonValue(arguments[index], hint: flag.valueHint) }
        } else { positionals.append(.string(argument)) }
        index += 1
    }
    for flag in spec.flags where flag.required && params[flag.name] == nil { throw CLIError.usage("missing required --\(flag.name)") }
    if !positionals.isEmpty { params["_args"] = .array(positionals) }
    return ParsedCommand(spec: spec, params: params, json: params["json"]?.boolValue == true)
}

func jsonValue(_ text: String, hint: String?) -> JSONValue {
    if hint == "json", let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) { return value }
    if hint == "ms" || hint == "n", let number = Double(text) { return .number(number) }
    return .string(text)
}

struct Metadata: Decodable { let socketPath: String; let authToken: String }
func metadataURL() -> URL { (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("Orchard/orchard-runtime.json") }

func callRuntime(method: String, params: JSONValue) throws -> RPCResponse {
    let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL()))
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw CLIError.runtime("runtime_unavailable") }; defer { Darwin.close(fd) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    guard metadata.socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CLIError.runtime("runtime socket path is too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in if let base = bytes.baseAddress { memset(base, 0, bytes.count) }; metadata.socketPath.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) } }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + metadata.socketPath.utf8.count + 1)
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) } }
    guard connected == 0 else { throw CLIError.runtime("runtime_unavailable: \(String(cString: strerror(errno)))") }
    var data = try JSONEncoder().encode(RPCRequest(method: method, params: params, authToken: metadata.authToken)); data.append(10)
    try data.withUnsafeBytes { guard let base = $0.baseAddress, Darwin.write(fd, base, $0.count) == $0.count else { throw CLIError.runtime("runtime_unavailable") } }
    var buffer = Data(), byte: UInt8 = 0
    while true {
        guard Darwin.read(fd, &byte, 1) > 0 else { throw CLIError.runtime("runtime_unavailable: connection closed") }
        if byte != 10 { buffer.append(byte); continue }
        if let object = try? JSONDecoder().decode([String: JSONValue].self, from: buffer), object["_keepalive"]?.boolValue == true { buffer.removeAll(keepingCapacity: true); continue }
        return try JSONDecoder().decode(RPCResponse.self, from: buffer)
    }
}

func printUsage() { print("usage: orchard <command> [options]\n"); OrchardCommands.all.forEach { print("  \($0.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \($0.summary)") } }

func formatHuman(method: String, result: JSONValue?) -> String {
    let object = result?.objectValue
    switch method {
    case "file-open":
        let path = object?["relativePath"]?.stringValue ?? "file"
        if object?["opened"]?.boolValue == true { return "Opened \(path)." }
        return "Did not open \(path): \(object?["reason"]?.stringValue ?? object?["kind"]?.stringValue ?? "not opened")."
    case "file-diff":
        let diff = object?["diff"]?.stringValue ?? ""
        return diff.isEmpty ? "No changes." : diff
    case "file-open-changed":
        let total = object?["totalChanged"]?.numberValue.map { Int($0) } ?? 0
        if total == 0 { return "No changed files." }
        let opened = object?["opened"]?.arrayValue?.count ?? 0
        var lines = ["Opened \(opened) changed file targets."]
        if let skipped = object?["skipped"]?.arrayValue, !skipped.isEmpty {
            lines.append("Skipped \(skipped.count) changed file targets:")
            for item in skipped {
                let path = item.objectValue?["path"]?.stringValue ?? "?"
                let reason = item.objectValue?["reason"]?.stringValue ?? "not opened"
                lines.append("- \(path): \(reason)")
            }
        }
        return lines.joined(separator: "\n")
    case "file-search":
        let matches = object?["matches"]?.arrayValue ?? []
        if matches.isEmpty { return "No matches." }
        var lines = matches.map { item -> String in
            let path = item.objectValue?["path"]?.stringValue ?? "?"
            let line = item.objectValue?["line"]?.numberValue.map { Int($0) } ?? 0
            let excerpt = item.objectValue?["excerpt"]?.stringValue ?? ""
            return "\(path):\(line):\(excerpt)"
        }
        if object?["truncated"]?.boolValue == true {
            lines.append("(truncated)")
        }
        return lines.joined(separator: "\n")
    case "host-list":
        return formatHostList(result)
    case "host-add":
        return formatHostAdd(result)
    case "host-check":
        return formatHostCheck(result)
    case "worktree-ps":
        return formatWorktreePs(result)
    case "workspace-ports":
        return formatWorkspacePorts(result)
    case "terminal-list":
        return formatTerminalList(result)
    case "terminal-read":
        return (object?["lines"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
    default:
        return result.map(String.init(describing:)) ?? "ok"
    }
}

func formatTerminalList(_ result: JSONValue?) -> String {
    let rows = result?.objectValue?["terminals"]?.arrayValue ?? []
    if rows.isEmpty { return "No terminals found." }
    let headings = ["TITLE", "HANDLE", "WORKTREE", "STATE"]
    let values = rows.map { value -> [String] in
        let row = value.objectValue ?? [:]
        let connected = row["connected"]?.boolValue == true
        return [
            row["title"]?.stringValue ?? row["engine"]?.stringValue ?? "",
            row["handle"]?.stringValue ?? "",
            row["worktreeId"]?.stringValue ?? "-",
            row["agentState"]?.stringValue ?? (connected ? "running" : "exited"),
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

func formatHostList(_ result: JSONValue?) -> String {
    let hosts = result?.objectValue?["hosts"]?.arrayValue ?? []
    if hosts.isEmpty { return "No hosts registered. Try: orchard host add --import" }
    return hosts.map { item -> String in
        let host = item.objectValue ?? [:]
        let name = host["name"]?.stringValue ?? "?"
        let target = host["target"]?.stringValue ?? ""
        let source = host["source"]?.stringValue ?? "manual"
        let id = host["executionHostId"]?.stringValue ?? "ssh:\(name)"
        return "\(name)  \(target)  \(source)  \(id)"
    }.joined(separator: "\n")
}

func formatHostAdd(_ result: JSONValue?) -> String {
    let object = result?.objectValue
    if let imported = object?["imported"]?.objectValue {
        let name = imported["name"]?.stringValue ?? "?"
        let source = imported["source"]?.stringValue ?? "manual"
        return "Registered \(name) (\(source)). Probe it with: orchard host check \(name)"
    }
    let available = object?["available"]?.arrayValue ?? []
    if available.isEmpty { return "No new ~/.ssh/config hosts to import." }
    var lines = ["Importable ~/.ssh/config hosts:"]
    for item in available {
        let entry = item.objectValue ?? [:]
        let name = entry["name"]?.stringValue ?? "?"
        let hostname = entry["hostname"]?.stringValue
        lines.append(hostname.map { "  \(name)  (\($0))" } ?? "  \(name)")
    }
    lines.append("Import one with: orchard host add --import <name>")
    return lines.joined(separator: "\n")
}

func formatHostCheck(_ result: JSONValue?) -> String {
    let object = result?.objectValue ?? [:]
    let name = object["name"]?.stringValue ?? "?"
    let status = object["status"]?.stringValue ?? "unreachable"
    let detail = object["detail"]?.stringValue ?? ""
    var lines = ["\(name): \(status)" + (detail.isEmpty ? "" : " — \(detail)")]
    if let command = object["command"]?.stringValue { lines.append("  probe: \(command)") }
    if let note = object["note"]?.stringValue, !note.isEmpty { lines.append("  \(note)") }
    return lines.joined(separator: "\n")
}

func formatWorktreePs(_ result: JSONValue?) -> String {
    let object = result?.objectValue
    let rows = object?["worktrees"]?.arrayValue ?? []
    if rows.isEmpty { return "No worktrees found." }
    var blocks: [String] = []
    for row in rows {
        let item = row.objectValue ?? [:]
        let name = item["displayName"]?.stringValue ?? "?"
        let branch = item["branch"]?.stringValue ?? ""
        let path = item["path"]?.stringValue ?? ""
        let processes = item["processes"]?.arrayValue ?? []
        let ports = item["ports"]?.arrayValue ?? []
        let portList = ports.compactMap { port -> String? in
            guard let number = port.objectValue?["port"]?.numberValue.map({ Int($0) }) else { return nil }
            if let process = port.objectValue?["processName"]?.stringValue, !process.isEmpty {
                return "\(number) (\(process))"
            }
            return String(number)
        }
        var lines = ["\(name)  \(branch)  live:\(processes.count)  ports:\(ports.count)"]
        if !path.isEmpty { lines.append(path) }
        for process in processes {
            let proc = process.objectValue ?? [:]
            let kind = proc["kind"]?.stringValue ?? "shell"
            let engine = proc["engine"]?.stringValue ?? ""
            let state = proc["agentState"]?.stringValue ?? ""
            let handle = proc["handle"]?.stringValue ?? ""
            var line = "  \(kind)  \(engine)"
            if !state.isEmpty { line += "  \(state)" }
            if !handle.isEmpty { line += "  \(handle)" }
            lines.append(line)
        }
        if !portList.isEmpty {
            lines.append("  ports  " + portList.joined(separator: "  "))
        }
        blocks.append(lines.joined(separator: "\n"))
    }
    var body = blocks.joined(separator: "\n\n")
    if object?["truncated"]?.boolValue == true {
        let shown = rows.count
        let total = object?["totalCount"]?.numberValue.map { Int($0) } ?? shown
        body += "\n\ntruncated: showing \(shown) of \(total)"
    }
    return body
}

func formatWorkspacePorts(_ result: JSONValue?) -> String {
    let ports = result?.objectValue?["ports"]?.arrayValue ?? []
    if ports.isEmpty { return "No workspace ports." }
    return ports.map { item -> String in
        let port = item.objectValue ?? [:]
        let number = port["port"]?.numberValue.map { Int($0) } ?? 0
        let host = port["connectHost"]?.stringValue ?? "localhost"
        let name = port["displayName"]?.stringValue ?? port["worktreeId"]?.stringValue ?? "?"
        let process = port["processName"]?.stringValue ?? ""
        let pid = port["pid"]?.numberValue.map { Int($0) }
        var line = "\(host):\(number)  \(name)"
        if !process.isEmpty { line += "  \(process)" }
        if let pid { line += "  pid:\(pid)" }
        return line
    }.joined(separator: "\n")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.first == "help" || args.first == "--help" { printUsage(); exit(0) }
    let parsed = try parse(args)
    switch parsed.spec.name {
    case "serve":
        let path = parsed.params["data-dir"]?.stringValue
        serve(dataDirectory: path.map { URL(fileURLWithPath: $0).standardizedFileURL })
    case "agent-context":
        let data = try JSONEncoder.pretty.encode(AgentContextDocument(commands: OrchardCommands.all)); FileHandle.standardOutput.write(data + Data("\n".utf8))
    case "version": print(parsed.json ? "{\"version\":\"\(toolVersion)\"}" : "orchard \(toolVersion)")
    case "guide":
        guard case let .array(values)? = parsed.params["_args"], let verb = values.first?.stringValue else { throw CLIError.usage("usage: orchard guide list | orchard guide get orchestration [--json]") }
        if verb == "list", values.count == 1 {
            if parsed.json { let data = try JSONEncoder.pretty.encode(["topics": OrchestrationContract.topics]); FileHandle.standardOutput.write(data + Data("\n".utf8)) }
            else { OrchestrationContract.topics.forEach { print($0) } }
        } else if verb == "get", values.count == 2, values[1].stringValue == "orchestration" {
            if parsed.json { let data = try JSONEncoder.pretty.encode(["topic": "orchestration", "content": OrchestrationContract.coordinatorGuide]); FileHandle.standardOutput.write(data + Data("\n".utf8)) } else { print(OrchestrationContract.coordinatorGuide) }
        } else { throw CLIError.usage("usage: orchard guide list | orchard guide get orchestration [--json]") }
    default:
        var method = parsed.spec.name, params = parsed.params; params.removeValue(forKey: "json")
        if method == "repo" || method == "browser" || method == "automations" || method == "worktree" || method == "terminal" || method == "host", case let .array(values)? = params.removeValue(forKey: "_args"), let subcommand = values.first?.stringValue {
            method = "\(method)-\(subcommand)"
            let rest = Array(values.dropFirst())
            if method.hasPrefix("host-") {
                // `host add <name>` / `host check <name>`: the positional is the name.
                if !rest.isEmpty, params["name"] == nil { params["name"] = rest[0] }
            } else if method.hasPrefix("automations-") && !rest.isEmpty && params["id"] == nil {
                params["id"] = rest[0]
            } else if method.hasPrefix("worktree-") {
                if params["cwd"] == nil {
                    params["cwd"] = .string(FileManager.default.currentDirectoryPath)
                }
                if !rest.isEmpty, params["worktree"] == nil,
                   ["worktree-show", "worktree-set", "worktree-rm"].contains(method) {
                    params["worktree"] = rest[0]
                } else if !rest.isEmpty {
                    params["_args"] = .array(rest)
                }
            } else if method.hasPrefix("terminal-") {
                guard rest.isEmpty else { throw CLIError.usage("usage: orchard terminal list|create|read|send|wait|split|close|rename [options]") }
                let verb = String(method.dropFirst("terminal-".count))
                let known = ["list", "create", "read", "send", "wait", "split", "close", "rename"]
                guard known.contains(verb) else { throw CLIError.usage("usage: orchard terminal list|create|read|send|wait|split|close|rename [options]") }
                if ["read", "send", "wait", "split", "close", "rename"].contains(verb), params["terminal"] == nil {
                    throw CLIError.usage("terminal \(verb) requires --terminal <handle>")
                }
                if verb == "wait", params["for"] == nil { throw CLIError.usage("terminal wait requires --for tui-idle|exit") }
                if verb == "rename", params["title"] == nil { throw CLIError.usage("terminal rename requires --title <text>") }
                if let timeout = params.removeValue(forKey: "timeout-ms") { params["timeoutMs"] = timeout }
                if (verb == "list" || verb == "create"), params["cwd"] == nil {
                    params["cwd"] = .string(FileManager.default.currentDirectoryPath)
                }
            } else if !rest.isEmpty { params["_args"] = .array(rest) }
        } else if method == "worktree" {
            throw CLIError.usage("usage: orchard worktree list|show|current|create|set|rm|ps [options]")
        } else if method == "terminal" {
            throw CLIError.usage("usage: orchard terminal list|create|read|send|wait|split|close|rename [options]")
        } else if method == "host" {
            throw CLIError.usage("usage: orchard host list | orchard host add <name> [--hostname <h>] [--user <u>] [--port <n>] | orchard host add --import [<name>] | orchard host check <name>")
        }
        if method == "file" {
            guard case let .array(values)? = params.removeValue(forKey: "_args"), let subcommand = values.first?.stringValue else {
                throw CLIError.usage("usage: orchard file open|diff|open-changed|search [path|query] [--worktree <selector>]")
            }
            method = "file-\(subcommand)"
            if subcommand == "search" {
                if values.count > 1, params["query"] == nil { params["query"] = values[1] }
            } else if values.count > 1, params["path"] == nil {
                params["path"] = values[1]
            }
            if params["cwd"] == nil { params["cwd"] = .string(FileManager.default.currentDirectoryPath) }
        }
        let response = try callRuntime(method: method, params: .object(params))
        if parsed.json { let data = try JSONEncoder.pretty.encode(response); FileHandle.standardOutput.write(data + Data("\n".utf8)) }
        else if response.ok { print(formatHuman(method: method, result: response.result)) }
        else { throw CLIError.runtime("\(response.error?.code ?? "error"): \(response.error?.message ?? "unknown error")") }
    }
} catch { FileHandle.standardError.write(Data("orchard: \(error)\n".utf8)); exit(64) }

extension JSONEncoder { static var pretty: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value } }
