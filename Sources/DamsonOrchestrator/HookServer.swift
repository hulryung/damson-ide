import Foundation
import Network

/// One lifecycle event delivered by an agent CLI's own hook system to the
/// loopback server. `token` routes it to the owning `AgentSession`; `event` is the
/// engine-specific hook name (e.g. Claude Code's "Stop"/"Notification"); `body` is
/// the raw JSON payload the CLI passed on the hook's stdin (may be empty).
public struct HookEvent: Sendable {
    public let token: String
    public let event: String
    public let body: Data
}

/// A tiny loopback HTTP server that agent CLIs POST lifecycle hooks to. This is the
/// primary, most-reliable turn-completion signal (Tier 1): structured events
/// straight from the agent instead of screen-scraping. One server serves every
/// agent in a run; each agent is handed a unique `token` (embedded in the hook
/// command it POSTs) so events route to the right session.
///
/// Hooks POST to `http://127.0.0.1:<port>/hook?agent=<token>&event=<name>` with the
/// CLI's stdin JSON as the request body. Loopback-only, so no auth beyond the
/// unguessable per-run token; binds to 127.0.0.1 exclusively.
public final class HookServer {
    /// Called on a background queue for every received hook. Route by `event.token`.
    public var onEvent: ((HookEvent) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.damson.orchard.hookserver")
    public private(set) var port: UInt16 = 0

    public init() {}

    /// Start listening on a kernel-assigned loopback port. Returns the port, or nil
    /// on failure (the caller then simply runs without Tier-1 hooks).
    @discardableResult
    public func start() -> UInt16? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let p = self?.listener?.port?.rawValue { self?.port = p }
                ready.signal()
            } else if case .failed = state {
                ready.signal()
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        return port != 0 ? port : nil
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate until we have headers + the full Content-Length body, then dispatch.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let req = Self.parseRequest(buf) {
                if let event = Self.hookEvent(from: req) { self.onEvent?(event) }
                let resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            if isComplete || error != nil { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    // MARK: - Minimal HTTP parse

    private struct Request { let target: String; let body: Data }

    /// Parse just enough HTTP/1.1 to extract the request target + body. Returns nil
    /// until the full body (per Content-Length) has arrived.
    private static func parseRequest(_ buf: Data) -> Request? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = sep.upperBound
        let have = buf.distance(from: bodyStart, to: buf.endIndex)
        guard have >= contentLength else { return nil }   // wait for the rest
        let body = Data(buf[bodyStart..<buf.index(bodyStart, offsetBy: contentLength)])
        return Request(target: target, body: body)
    }

    private static func hookEvent(from req: Request) -> HookEvent? {
        guard let q = req.target.firstIndex(of: "?") else { return nil }
        let query = req.target[req.target.index(after: q)...]
        var token = "", event = ""
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let value = kv[1].removingPercentEncoding ?? String(kv[1])
            switch kv[0] {
            case "agent": token = value
            case "event": event = value
            default: break
            }
        }
        guard !token.isEmpty, !event.isEmpty else { return nil }
        return HookEvent(token: token, event: event, body: req.body)
    }
}
