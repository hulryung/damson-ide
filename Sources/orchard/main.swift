import Darwin
import Foundation
import OrchardProtocol

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

let orchestrationGuide = """
# Orchard orchestration

Create or bind a run, create tasks, dispatch workers, then use `orchard check --wait --types worker_done,escalation,question --timeout-ms 900000 --json`.
Workers report `worker_done` exactly once with both task and dispatch IDs, use `orchard ask` for blocking questions, and send five-minute heartbeats while active.
Acknowledge a delivery only after every message is processed. Gates never auto-resolve and stale heartbeats only warn.
Use `orchard agent-context --json` for the authoritative command table.
"""

func printUsage() { print("usage: orchard <command> [options]\n"); OrchardCommands.all.forEach { print("  \($0.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \($0.summary)") } }

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.first == "help" || args.first == "--help" { printUsage(); exit(0) }
    let parsed = try parse(args)
    switch parsed.spec.name {
    case "agent-context":
        let data = try JSONEncoder.pretty.encode(AgentContextDocument(commands: OrchardCommands.all)); FileHandle.standardOutput.write(data + Data("\n".utf8))
    case "version": print(parsed.json ? "{\"version\":\"\(toolVersion)\"}" : "orchard \(toolVersion)")
    case "guide":
        guard case let .array(values)? = parsed.params["_args"], values.count == 2, values[0].stringValue == "get", values[1].stringValue == "orchestration" else { throw CLIError.usage("usage: orchard guide get orchestration [--json]") }
        if parsed.json { let data = try JSONEncoder.pretty.encode(["topic": "orchestration", "content": orchestrationGuide]); FileHandle.standardOutput.write(data + Data("\n".utf8)) } else { print(orchestrationGuide) }
    default:
        var method = parsed.spec.name, params = parsed.params; params.removeValue(forKey: "json")
        if method == "repo" || method == "browser", case let .array(values)? = params.removeValue(forKey: "_args"), let subcommand = values.first?.stringValue {
            method = "\(method)-\(subcommand)"
            let rest = Array(values.dropFirst())
            if !rest.isEmpty { params["_args"] = .array(rest) }
        }
        let response = try callRuntime(method: method, params: .object(params))
        if parsed.json { let data = try JSONEncoder.pretty.encode(response); FileHandle.standardOutput.write(data + Data("\n".utf8)) }
        else if response.ok { print(response.result.map(String.init(describing:)) ?? "ok") }
        else { throw CLIError.runtime("\(response.error?.code ?? "error"): \(response.error?.message ?? "unknown error")") }
    }
} catch { FileHandle.standardError.write(Data("orchard: \(error)\n".utf8)); exit(64) }

extension JSONEncoder { static var pretty: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value } }
