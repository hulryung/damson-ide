import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

private struct StubRunner: HostCommandRunner {
    let result: HostCommandResult
    func run(_ argv: [String], timeout: TimeInterval) async -> HostCommandResult { result }
}

/// T29 over the RPC seam: `host list|add|check`, and `terminal create --host ssh:<name>`
/// spawning a local PTY whose child is `ssh` with the execution host stamped on the
/// summary.
@MainActor
final class HostHandlerTests: XCTestCase {
    private var tmp: URL!
    private var store: OrchardDataStore!
    private var registry: HostRegistry!
    private var liveness: HostLivenessService!
    private var server: InMemoryRuntimeServer!
    /// Every create spec the terminal factory saw, so tests can assert on launch argv.
    private var specs: [TerminalCreateSpec] = []

    private let configHosts = [SSHConfigHost(alias: "build", hostname: "build.internal",
                                             user: "ci", port: 2222)]

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-host-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
        let config = configHosts
        registry = HostRegistry(store: store, sshConfig: { config })
        specs = []
        let service = TerminalService(factory: { [weak self] spec, _ in
            self?.specs.append(spec)
            return ScriptedTerminalSession()
        })
        liveness = HostLivenessService(
            hosts: { [registry] in registry!.list() },
            surface: { HostLivenessSurface() },
            runner: StubRunner(result: HostCommandResult(exitCode: 0)),
            probeTimeout: 1,
            interval: 60)
        var commands = CommandRegistry()
        commands.register(HostCommandHandler(
            registry: registry,
            runner: StubRunner(result: HostCommandResult(exitCode: 0)),
            probeTimeout: 1,
            liveness: liveness))
        commands.register(TerminalCommandHandler(service: service, hosts: registry))
        server = InMemoryRuntimeServer(registry: commands, runtimeId: "rt_hosts")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    func testImportWithoutANameListsOffersInsteadOfPrompting() async {
        // A dispatched worker must never be parked on an interactive picker, so the
        // offer comes back as data the caller re-invokes with.
        let offered = await call("host-add", ["import": .bool(true)])
        XCTAssertTrue(offered.ok)
        XCTAssertEqual(offered.result?.objectValue?["imported"], .null)
        let available = offered.result?.objectValue?["available"]?.arrayValue ?? []
        XCTAssertEqual(available.first?.objectValue?["name"]?.stringValue, "build")

        let imported = await call("host-add", ["import": .bool(true), "name": .string("build")])
        XCTAssertTrue(imported.ok)
        XCTAssertEqual(imported.result?.objectValue?["imported"]?.objectValue?["source"]?.stringValue,
                       "ssh-config")

        let listed = await call("host-list")
        let hosts = listed.result?.objectValue?["hosts"]?.arrayValue ?? []
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].objectValue?["executionHostId"]?.stringValue, "ssh:build")
        XCTAssertEqual(hosts[0].objectValue?["target"]?.stringValue, "build")
    }

    func testAddRejectsDuplicatesAndCheckRejectsUnknownHosts() async {
        let added = await call("host-add", ["name": .string("box"),
                                            "hostname": .string("10.0.0.5")])
        XCTAssertTrue(added.ok)
        let duplicate = await call("host-add", ["name": .string("box")])
        XCTAssertEqual(duplicate.error?.code, "host_exists")

        let unknown = await call("host-check", ["name": .string("ghost")])
        XCTAssertEqual(unknown.error?.code, "unknown_host")
    }

    func testCheckReportsAProbeVerdict() async {
        _ = await call("host-add", ["name": .string("box"), "hostname": .string("10.0.0.5")])
        let checked = await call("host-check", ["name": .string("box")])
        XCTAssertTrue(checked.ok)
        XCTAssertEqual(checked.result?.objectValue?["status"]?.stringValue, "reachable")
        XCTAssertEqual(checked.result?.objectValue?["executionHostId"]?.stringValue, "ssh:box")
        XCTAssertNotNil(checked.result?.objectValue?["lastCheckedAt"])
        XCTAssertNotNil(checked.result?.objectValue?["latencyMs"])
    }

    func testListShowsLiveStatusAndAgeAfterACheck() async {
        _ = await call("host-add", ["name": .string("box"), "hostname": .string("10.0.0.5")])
        _ = await call("host-check", ["name": .string("box")])
        let listed = await call("host-list")
        let hosts = listed.result?.objectValue?["hosts"]?.arrayValue ?? []
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].objectValue?["status"]?.stringValue, "reachable")
        XCTAssertNotNil(hosts[0].objectValue?["lastCheckedAt"])
        XCTAssertNotNil(hosts[0].objectValue?["ageSeconds"])
        XCTAssertNotNil(hosts[0].objectValue?["latencyMs"])
        XCTAssertEqual(liveness.status(for: "box")?.status, .reachable)
    }

    func testCheckDoesNotMutateARemoteTerminal() async throws {
        _ = await call("host-add", ["import": .bool(true), "name": .string("build")])
        let created = await call("terminal-create", ["host": .string("ssh:build")])
        XCTAssertTrue(created.ok, "\(String(describing: created.error))")
        let before = await call("terminal-list")
        let beforeRows = before.result?.objectValue?["terminals"]?.arrayValue ?? []
        XCTAssertEqual(beforeRows.count, 1)
        let beforeHost = beforeRows[0].objectValue?["executionHostId"]?.stringValue
        let beforeHandle = beforeRows[0].objectValue?["handle"]?.stringValue
        let beforeConnected = beforeRows[0].objectValue?["connected"]?.boolValue
        let dataBefore = store.load()

        _ = await call("host-check", ["name": .string("build")])
        XCTAssertEqual(liveness.status(for: "build")?.status, .reachable)

        let after = await call("terminal-list")
        let afterRows = after.result?.objectValue?["terminals"]?.arrayValue ?? []
        XCTAssertEqual(afterRows.count, 1)
        XCTAssertEqual(afterRows[0].objectValue?["executionHostId"]?.stringValue, beforeHost)
        XCTAssertEqual(afterRows[0].objectValue?["handle"]?.stringValue, beforeHandle)
        XCTAssertEqual(afterRows[0].objectValue?["connected"]?.boolValue, beforeConnected)
        XCTAssertEqual(store.load(), dataBefore)
    }

    func testRemoteTerminalSpawnsSSHAndStampsTheHost() async throws {
        _ = await call("host-add", ["import": .bool(true), "name": .string("build")])
        let created = await call("terminal-create", ["host": .string("ssh:build")])
        XCTAssertTrue(created.ok, "\(String(describing: created.error))")

        let summary = try XCTUnwrap(created.result?.objectValue)
        XCTAssertEqual(summary["executionHostId"]?.stringValue, "ssh:build")
        XCTAssertEqual(summary["title"]?.stringValue, "build")
        XCTAssertEqual(summary["engine"]?.stringValue, "shell")

        // A local PTY whose child is `ssh -tt build`: the shell engine's prompt IS its
        // command line, and the alias is the destination.
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs.first?.prompt, "/usr/bin/ssh -tt build")
        XCTAssertEqual(specs.first?.executionHostId, "ssh:build")

        // read/send/wait are unchanged — it is an ordinary local PTY.
        let read = await call("terminal-read", ["terminal": summary["handle"]!])
        XCTAssertTrue(read.ok)
        XCTAssertEqual(read.result?.objectValue?["status"]?.stringValue, "running")

        // …and it lists with its host, so nothing downstream reads it as local.
        let listed = await call("terminal-list")
        let terminals = listed.result?.objectValue?["terminals"]?.arrayValue ?? []
        XCTAssertEqual(terminals.first?.objectValue?["executionHostId"]?.stringValue, "ssh:build")
    }

    func testRemoteTerminalCarriesACommandToTheFarSide() async {
        _ = await call("host-add", ["name": .string("box"), "hostname": .string("10.0.0.5"),
                                    "user": .string("dk"), "port": .number(2200)])
        let created = await call("terminal-create", ["host": .string("ssh:box"),
                                                     "prompt": .string("uptime -p")])
        XCTAssertTrue(created.ok)
        XCTAssertEqual(specs.first?.prompt, "/usr/bin/ssh -tt -p 2200 dk@10.0.0.5 'uptime -p'")
    }

    func testLocalCreateIsUnchangedAndStampsLocal() async {
        let created = await call("terminal-create", [:])
        XCTAssertTrue(created.ok)
        XCTAssertEqual(created.result?.objectValue?["executionHostId"]?.stringValue, "local")
        XCTAssertEqual(specs.first?.prompt, "")
    }

    func testUnknownAndMalformedHostsAreRefusedNotRunLocally() async {
        let unknown = await call("terminal-create", ["host": .string("ssh:ghost")])
        XCTAssertEqual(unknown.error?.code, "unknown_host")

        let malformed = await call("terminal-create", ["host": .string("runtime:vm-1")])
        XCTAssertEqual(malformed.error?.code, "invalid_argument")
        // Nothing was spawned: a host we cannot resolve never degrades to a local shell.
        XCTAssertTrue(specs.isEmpty)
    }

    /// A remote agent needs a remote *worktree* — that is where its hook config lives
    /// and what it works in. `--host ssh:<name>` alone names a connection, not a
    /// workspace, so it stays refused even after T39 (which implements the
    /// `--worktree <remote id> --engine <agent>` spelling).
    func testARemoteAgentWithNoRemoteWorktreeIsStillRefused() async {
        _ = await call("host-add", ["import": .bool(true), "name": .string("build")])
        let created = await call("terminal-create", ["host": .string("ssh:build"),
                                                     "engine": .string("claude-code")])
        XCTAssertEqual(created.error?.code, "not_implemented")
        XCTAssertTrue(created.error?.message.contains("--worktree") ?? false,
                      created.error?.message ?? "")
        XCTAssertTrue(specs.isEmpty)
    }
}
