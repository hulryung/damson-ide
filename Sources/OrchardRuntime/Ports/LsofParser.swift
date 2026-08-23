import Foundation

/// Parses `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` (NUL-free field mode) into listening
/// TCP sockets. Unknown field tags and malformed address lines are skipped; the
/// parser never throws.
public enum LsofParser {
    public static let maxPorts = 200

    public static func parse(_ output: String) -> [RawListeningPort] {
        var ports: [RawListeningPort] = []
        var currentPid: Int32?
        var currentProcessName: String?

        output.enumerateLines { line, _ in
            guard let tag = line.first else { return }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                currentPid = Int32(value)
                currentProcessName = nil
            case "c":
                currentProcessName = value.isEmpty ? nil : value
            case "n":
                guard let parsed = parseAddress(value) else { return }
                ports.append(RawListeningPort(
                    host: parsed.host, port: parsed.port,
                    pid: currentPid, processName: currentProcessName))
            default:
                break
            }
        }

        return dedupe(ports)
    }

    /// `host:port`, `[ipv6]:port`, optional trailing ` (LISTEN)`.
    public static func parseAddress(_ raw: String) -> (host: String, port: Int)? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let listen = trimmed.range(of: " (LISTEN)", options: .caseInsensitive) {
            trimmed = String(trimmed[..<listen.lowerBound])
        }
        guard !trimmed.isEmpty else { return nil }

        let host: String
        let portText: String
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.first == ":" else { return nil }
            portText = String(rest.dropFirst())
        } else if let colon = trimmed.lastIndex(of: ":") {
            host = String(trimmed[..<colon])
            portText = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil
        }

        guard let port = Int(portText), (1...65535).contains(port), !host.isEmpty else {
            return nil
        }
        return (host, port)
    }

    public static func connectHost(forBindHost host: String) -> String {
        switch host {
        case "*", "0.0.0.0", "::", "[::]":
            return "localhost"
        default:
            return host
        }
    }

    static func dedupe(_ ports: [RawListeningPort]) -> [RawListeningPort] {
        var seen = Set<String>()
        var result: [RawListeningPort] = []
        result.reserveCapacity(min(ports.count, maxPorts))
        for port in ports {
            let host = connectHost(forBindHost: port.host)
            let key = "\(host):\(port.port):\(port.pid.map(String.init) ?? "unknown")"
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(port)
            if result.count >= maxPorts { break }
        }
        return result
    }
}
