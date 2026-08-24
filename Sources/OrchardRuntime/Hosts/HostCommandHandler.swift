import Foundation
import OrchardProtocol

/// RPC surface for the host registry: `host-list | host-add | host-check`.
///
/// `host-check` is the only verb that touches the network, and it is bounded twice
/// (`ConnectTimeout=5` plus the runner's own deadline) because an agent-facing verb
/// that can hang is worse than one that answers "unreachable" — a coordinator blocked
/// on a probe is indistinguishable from a crashed one.
///
/// `host-list` is a read of the registry plus the in-memory liveness snapshot (T45).
/// A missing or stale status is not a claim about the host record, and listing never
/// probes.
public struct HostCommandHandler: CommandHandler, @unchecked Sendable {
    private let registry: HostRegistry
    private let runner: HostCommandRunner
    private let probeTimeout: TimeInterval
    private let liveness: HostLivenessService?

    public init(registry: HostRegistry,
                runner: HostCommandRunner = ProcessHostCommandRunner(),
                probeTimeout: TimeInterval = HostProbe.defaultTimeout,
                liveness: HostLivenessService? = nil) {
        self.registry = registry
        self.runner = runner
        self.probeTimeout = probeTimeout
        self.liveness = liveness
    }

    public var verbs: [String] { ["host-list", "host-add", "host-check"] }

    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            return .success(id: request.id, result: try await route(request))
        } catch let error as HostRegistryError {
            return .failure(id: request.id,
                            error: RPCError(code: error.code, message: error.message))
        } catch {
            return .failure(id: request.id,
                            error: RPCError(code: "internal_error", message: String(describing: error)))
        }
    }

    private func route(_ request: RPCRequest) async throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]
        switch request.method {
        case "host-list":
            let hosts = registry.list()
            return .object([
                "hosts": try encodeHosts(hosts),
                "totalCount": .number(Double(hosts.count)),
            ])

        case "host-add":
            let name = params["name"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            let wantsImport = params["import"]?.boolValue == true
            if wantsImport {
                // No name with `--import` is a *listing*, not a prompt: a dispatched
                // worker must never be parked on an interactive picker, so the offer
                // comes back as data the caller re-invokes with.
                guard let name, !name.isEmpty else {
                    let offered = registry.importable()
                    return .object([
                        "imported": .null,
                        "available": .array(offered.map { entry in
                            .object([
                                "name": .string(entry.alias),
                                "hostname": entry.hostname.map { JSONValue.string($0) } ?? .null,
                                "user": entry.user.map { JSONValue.string($0) } ?? .null,
                                "port": entry.port.map { JSONValue.number(Double($0)) } ?? .null,
                            ])
                        }),
                        "source": .string("ssh-config"),
                    ])
                }
                let record = try registry.importFromSSHConfig(name: name)
                return .object(["imported": try JSONBridge.value(record), "available": .array([])])
            }
            guard let name, !name.isEmpty else {
                throw HostRegistryError.invalidArgument(
                    "host add needs a name (or --import to list ~/.ssh/config hosts)")
            }
            let record = try registry.add(
                name: name,
                hostname: params["hostname"]?.stringValue,
                user: params["user"]?.stringValue,
                port: params["port"]?.intValue,
                source: .manual)
            return .object(["imported": try JSONBridge.value(record), "available": .array([])])

        case "host-check":
            guard let name = params["name"]?.stringValue, !name.isEmpty else {
                throw HostRegistryError.invalidArgument("host check needs a host name")
            }
            let record = try registry.require(name: name)
            let result = await HostProbe.check(host: record, runner: runner, timeout: probeTimeout)
            // A user-initiated check publishes into the same snapshot the periodic
            // producer uses. It does not mutate the host record or any workspace.
            liveness?.publish(result)
            return try JSONBridge.value(result)

        default:
            throw HostRegistryError.invalidArgument("unrouted verb '\(request.method)'")
        }
    }

    private func encodeHosts(_ hosts: [HostRecord]) throws -> JSONValue {
        let snapshot = liveness?.snapshot()
        let now = Date()
        return .array(try hosts.map { host in
            var object = try JSONBridge.value(host).objectValue ?? [:]
            object["executionHostId"] = .string(host.executionHostId?.rawValue ?? "ssh:\(host.name)")
            object["target"] = .string(SSHCommand.destination(for: host))
            if let live = snapshot?.status(for: host.name) {
                object["status"] = .string(live.status.rawValue)
                object["lastCheckedAt"] = .number(live.lastCheckedAt.timeIntervalSince1970)
                object["ageSeconds"] = .number(live.ageSeconds(now: now))
                if let latency = live.latencyMs {
                    object["latencyMs"] = .number(latency)
                }
                if !live.detail.isEmpty {
                    object["detail"] = .string(live.detail)
                }
                if let note = live.note, !note.isEmpty {
                    object["note"] = .string(note)
                }
            }
            return .object(object)
        })
    }
}
