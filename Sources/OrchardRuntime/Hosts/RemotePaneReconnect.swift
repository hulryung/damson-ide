import Foundation
import OrchardProtocol
import OrchardTerminals

/// Stage 4 of docs/design/remote-hosts.md, runtime half: what a remote pane says when
/// its connection ended, and the verb that reopens one.
///
/// The copy lives here rather than in `OrchardTerminals` because it is *liveness* copy,
/// and `HostLiveness` — the only place allowed to turn an ended PTY into a word — is a
/// runtime type. A pane that ended while the app was gone has no exit status at all,
/// which is the strongest form of `unverifiable`: nobody was watching, the keeper saw
/// only EOF on a fd, and EOF on the local end of an `ssh` says nothing whatsoever about
/// the far side.
public enum RemotePaneRestoration {
    /// What the pane says about itself after a restart it did not survive as a
    /// connection.
    ///
    /// Three claims, in this order, and none of them may be softened or hardened:
    /// the connection ended; nobody can say what happened to the work; reopening is a
    /// new connection, not a resumption of the old one.
    public static func describeEndedWhileHeld(host: ExecutionHostId) -> String {
        guard !host.isLocal else {
            return "The process ended while Orchard was not running."
        }
        return "The connection to \(host.name) ended while Orchard was not running. "
            + "Whether anything is still running there is unverifiable — "
            + "\(HostLiveness.connectionLostReason). Reconnecting opens a new connection; "
            + "it does not resume this one."
    }

    /// What the pane says when nobody could tell us how the connection fared.
    ///
    /// The keeper is the only process that could have observed this child ending, and
    /// it did not answer. So there is no ending to report — only the absence of one.
    /// Saying "the connection ended" here would be inventing the evidence rule 2 exists
    /// to require.
    public static func describeHoldUnverifiable(host: ExecutionHostId) -> String {
        guard !host.isLocal else {
            return "Whether this process survived the restart is unverifiable."
        }
        return "Whether this connection to \(host.name) survived the restart is "
            + "unverifiable: the process that was holding it could not be reached, so "
            + "nothing here observed an ending — and nothing on \(host.name) is known to "
            + "have stopped. Reconnecting opens a new connection; it does not resume "
            + "this one."
    }

    /// The label the affordance itself carries. Deliberately not "Resume" or
    /// "Reattach": both would claim continuity with a session nobody can prove is
    /// still there.
    public static let reconnectActionTitle = "Reconnect"

    /// What a reconnect just did, in one sentence.
    ///
    /// Since T89 it also names the two generations. That is not decoration: the far side
    /// now holds this pane's identity under the new label, so a question asked about the
    /// old one is refused *there* as well as here — and a reader who has both labels can
    /// see that the two spans are different rather than inferring it from the word
    /// "new".
    public static func describeReconnected(host: ExecutionHostId, incarnation: Int,
                                           tunnelled: Bool,
                                           previousGeneration: String? = nil,
                                           generation: String? = nil) -> String {
        let channel = tunnelled
            ? "Its hook channel was reopened with it."
            : "It has no hook channel, so its status comes from screen fingerprints only."
        var sentence = "Opened a new connection to \(host.name) (incarnation \(incarnation))"
        if let generation {
            sentence += " as generation \(generation)"
            if let previousGeneration {
                sentence += "; \(previousGeneration) has ended and is no longer answerable"
            }
        }
        sentence += ". \(channel) Any work the previous connection left behind is untouched "
            + "and unverified."
        return sentence
    }
}

/// `terminal-reconnect` — reopen the connection of a remote pane that lost one.
///
/// Split out of `TerminalCommandHandler` because it is the host layer's verb: it is
/// refused for a local pane, it is refused for a pane that is still connected, and it
/// is refused when the pane's host is no longer registered. That last one matters more
/// than it looks — a host record is the user's statement that a connection target
/// exists, and reconnecting to a name they removed would have Orchard reaching for a
/// machine nobody asked it to reach.
public struct RemotePaneReconnectHandler: CommandHandler, @unchecked Sendable {
    private let service: TerminalService
    private let hosts: HostRegistry?

    public init(service: TerminalService, hosts: HostRegistry? = nil) {
        self.service = service
        self.hosts = hosts
    }

    public var verbs: [String] { ["terminal-reconnect"] }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            return .success(id: request.id, result: try await reconnect(request))
        } catch let error as TerminalServiceError {
            return .failure(id: request.id,
                            error: RPCError(code: error.code, message: error.message))
        } catch let error as HostRegistryError {
            return .failure(id: request.id,
                            error: RPCError(code: error.code, message: error.message))
        } catch let error as RemoteHostError {
            return .failure(id: request.id,
                            error: RPCError(code: error.code, message: error.message))
        } catch {
            return .failure(id: request.id,
                            error: RPCError(code: "internal_error",
                                            message: String(describing: error)))
        }
    }

    private func reconnect(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]
        let summary = try await resolve(params)
        guard let host = ExecutionHostId(rawValue: summary.executionHostId) else {
            throw TerminalServiceError.invalidArgument(
                "pane '\(summary.paneKey)' has an unusable execution host "
                    + "'\(summary.executionHostId)'")
        }
        guard !host.isLocal else {
            throw TerminalServiceError.invalidArgument(
                "terminal '\(summary.handle)' runs on this machine — there is no "
                    + "connection to reopen")
        }
        // A host that is gone from the registry keeps its panes inspectable (design §5,
        // rule 3); what it does not keep is permission to dial out to that name again.
        if let hosts { _ = try hosts.require(host: host) }

        let previousGeneration = await service.remoteFacts(paneKey: summary.paneKey)?.generation
        let reconnected = try await service.reconnectRemote(paneKey: summary.paneKey)
        let generation = await service.remoteFacts(paneKey: summary.paneKey)?.generation
        let tunnelled = reconnected.statusDetection?.mode == .hooks
        return try .object([
            "terminal": encodeReconnectJSON(reconnected),
            "reconnect": .object([
                "host": .string(host.rawValue),
                "incarnation": .number(Double(reconnected.incarnation)),
                "tunnelled": .bool(tunnelled),
                // Both labels, always — the pair is the evidence that this is a second
                // span of contact and not a resumption of the first.
                "previousGeneration": previousGeneration.map { JSONValue.string($0) } ?? .null,
                "generation": generation.map { JSONValue.string($0) } ?? .null,
                "note": .string(RemotePaneRestoration.describeReconnected(
                    host: host, incarnation: reconnected.incarnation,
                    tunnelled: tunnelled, previousGeneration: previousGeneration,
                    generation: generation)),
            ]),
        ])
    }

    /// `--terminal <handle>` names a live handle; `--pane <paneKey>` is how a pane
    /// whose connection ended is addressed after a restart, when the handle a caller
    /// remembers belongs to a previous app run.
    private func resolve(_ params: [String: JSONValue]) async throws -> TerminalSummary {
        if let handle = params["terminal"]?.stringValue, !handle.isEmpty {
            return try await service.summary(handle: handle)
        }
        if let paneKey = params["pane"]?.stringValue, !paneKey.isEmpty {
            guard let match = await service.summary(paneKey: paneKey)
            else { throw TerminalServiceError.notFound(handle: paneKey) }
            return match
        }
        throw TerminalServiceError.invalidArgument(
            "reconnect requires --terminal <handle> or --pane <paneKey>")
    }
}

private func encodeReconnectJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
