import Foundation
import OrchardProtocol
import OrchardTerminals

/// `terminal-liveness` — ask a remote pane's own host whether its process is running.
///
/// Every other liveness surface in Orchard answers from *this* side: a PTY that ended,
/// a probe that timed out, hooks that stopped arriving. For a remote pane all of those
/// describe an `ssh` client, which is why `HostLiveness.live` has never had a producer
/// and why a pane whose connection dropped has been permanently `unverifiable`. This
/// verb asks the machine that owns the process, about an identity that machine recorded
/// itself, and reports the answer in the same three words.
///
/// It is deliberately a question somebody asks, not something a loop publishes. A
/// background sweep that turned "the host has not answered lately" into pane state would
/// be manufacturing exactly the status rule 2 forbids.
public struct RemotePaneLivenessHandler: CommandHandler, @unchecked Sendable {
    private let service: TerminalService
    private let hosts: HostRegistry
    private let runner: HostCommandRunner
    private let connections: RemoteConnectionPool?
    private let timeout: TimeInterval

    public init(service: TerminalService,
                hosts: HostRegistry,
                runner: HostCommandRunner = ProcessHostCommandRunner(),
                connections: RemoteConnectionPool? = nil,
                timeout: TimeInterval = RemoteProcessLiveness.defaultTimeout) {
        self.service = service
        self.hosts = hosts
        self.runner = runner
        self.connections = connections
        self.timeout = timeout
    }

    public var verbs: [String] { ["terminal-liveness"] }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            return .success(id: request.id, result: try await liveness(request))
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

    private func liveness(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]
        let summary = try await resolve(params)
        guard let host = ExecutionHostId(rawValue: summary.executionHostId) else {
            throw TerminalServiceError.invalidArgument(
                "pane '\(summary.paneKey)' has an unusable execution host "
                    + "'\(summary.executionHostId)'")
        }
        guard !host.isLocal else {
            // A local pane's PTY *is* the process; `terminal list` already answers this,
            // and answering it here would invite the idea that the two are the same
            // question. They are not: one reads a process table, the other asks a
            // machine we cannot see.
            throw TerminalServiceError.invalidArgument(
                "terminal '\(summary.handle)' runs on this machine — its liveness is the "
                    + "PTY's own, which `terminal list` already reports")
        }
        // A host that left the registry keeps its panes inspectable (design §5, rule 3)
        // but is not a name Orchard dials again.
        let record = try hosts.require(host: host)
        guard let facts = await MainActor.run(body: { service.remoteFacts(paneKey: summary.paneKey) })
        else {
            throw TerminalServiceError.notFound(handle: summary.paneKey)
        }

        // `--generation` is how a caller pins the question to one span of contact. With
        // none, the pane's own current generation is used, which is the question almost
        // everybody means.
        let asked = params["generation"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? facts.generation
        let liveness = RemoteProcessLiveness(
            host: record, runner: runner,
            connection: connections?.connection(for: record), timeout: timeout)
        let report = await liveness.report(paneKey: facts.paneKey, token: facts.identityToken,
                                           paneGeneration: asked)

        var payload: [String: JSONValue] = [
            "paneKey": .string(facts.paneKey),
            "handle": .string(summary.handle),
            "incarnation": .number(Double(facts.incarnation)),
            "executionHostId": .string(host.rawValue),
            "connected": .bool(facts.connected),
            "status": .string(report.status),
            "answer": .string(Self.answerName(report.answer)),
            "note": .string(report.note),
        ]
        payload["generation"] = facts.generation.map { .string($0) } ?? .null
        payload["askedGeneration"] = asked.map { .string($0) } ?? .null
        payload["connectionGeneration"] = report.connectionGeneration.map { .string($0) } ?? .null
        payload["remoteCwd"] = facts.remoteCwd.map { .string($0) } ?? .null
        payload["pid"] = report.pid.map { .number(Double($0)) } ?? .null
        payload["reason"] = report.verdict.reason.map { .string($0) } ?? .null
        return .object(payload)
    }

    /// The host's own word, kept beside the verdict rather than folded into it: two
    /// different facts (`exited` and a reused pid) map to the same verdict, and a
    /// caller debugging one wants to know which it was.
    static func answerName(_ answer: RemoteProcessAnswer) -> String {
        switch answer {
        case .live: return "live"
        case .exited: return "exited"
        case .pidReused: return "pid-reused"
        case .noRecord: return "no-record"
        case .unverifiable: return "unverifiable"
        case .superseded: return "superseded"
        }
    }

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
            "terminal liveness requires --terminal <handle> or --pane <paneKey>")
    }
}
