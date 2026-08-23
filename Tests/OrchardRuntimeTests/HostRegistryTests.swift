import XCTest
@testable import OrchardRuntime

/// T29 host registry: `~/.ssh/config` name import, persistence in `orchard-data.json`,
/// and the execution-host id vocabulary those names turn into.
final class HostRegistryTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() -> OrchardDataStore {
        OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
    }

    // MARK: - ~/.ssh/config parsing

    func testParsesHostBlocksAndSkipsWildcards() {
        let hosts = SSHConfigParser.parse("""
        # comment
        Host *
          User nobody
          ForwardAgent yes

        Host build
          HostName build.internal
          User ci
          Port 2222

        Host laptop desk
          HostName 10.0.0.7

        Host !excluded gpu-?
          HostName never.example
        """)

        XCTAssertEqual(hosts.map(\.alias), ["build", "laptop", "desk"])
        XCTAssertEqual(hosts[0].hostname, "build.internal")
        XCTAssertEqual(hosts[0].user, "ci")
        XCTAssertEqual(hosts[0].port, 2222)
        // A `Host *` defaults block must not leak its User onto a later host.
        XCTAssertNil(hosts[1].user)
        XCTAssertEqual(hosts[1].hostname, "10.0.0.7")
        XCTAssertEqual(hosts[2].hostname, "10.0.0.7")
    }

    func testParsesEqualsSyntaxQuotesAndInlineComments() {
        let hosts = SSHConfigParser.parse("""
        Host box  # the box
        HostName=box.example.com
        User = "deploy"
        Port 22
        """)

        XCTAssertEqual(hosts.map(\.alias), ["box"])
        XCTAssertEqual(hosts[0].hostname, "box.example.com")
        XCTAssertEqual(hosts[0].user, "deploy")
        XCTAssertEqual(hosts[0].port, 22)
    }

    func testMatchBlockEndsTheCurrentHostBlock() {
        let hosts = SSHConfigParser.parse("""
        Host box
          HostName box.example.com

        Match host jump
          User conditional
        """)

        XCTAssertEqual(hosts.count, 1)
        // The Match body is conditional, so it must not be attributed to `box`.
        XCTAssertNil(hosts[0].user)
    }

    func testMissingConfigFileIsNoHostsNotAnError() {
        let hosts = SSHConfigParser.loadUserConfig(path: tmp.appendingPathComponent("absent").path)
        XCTAssertTrue(hosts.isEmpty)
    }

    // MARK: - Registry

    func testAddPersistsAndRejectsDuplicates() throws {
        let store = makeStore()
        let registry = HostRegistry(store: store, sshConfig: { [] })
        let added = try registry.add(name: "box", hostname: "10.0.0.5", user: "dk", port: 2200)

        XCTAssertEqual(added.source, .manual)
        XCTAssertEqual(added.executionHostId?.rawValue, "ssh:box")
        XCTAssertEqual(registry.list().map(\.name), ["box"])

        XCTAssertThrowsError(try registry.add(name: "box", hostname: "other", user: nil, port: nil)) {
            XCTAssertEqual($0 as? HostRegistryError, .duplicate("box"))
        }

        // Durable: a fresh store over the same file sees the record.
        let reopened = HostRegistry(store: makeStore(), sshConfig: { [] })
        XCTAssertEqual(reopened.find(name: "box")?.hostname, "10.0.0.5")
        XCTAssertEqual(reopened.find(name: "box")?.port, 2200)
    }

    func testAddRejectsUnusableNamesAndPorts() {
        let registry = HostRegistry(store: makeStore(), sshConfig: { [] })
        XCTAssertThrowsError(try registry.add(name: "two words", hostname: nil, user: nil, port: nil))
        XCTAssertThrowsError(try registry.add(name: "", hostname: nil, user: nil, port: nil))
        XCTAssertThrowsError(try registry.add(name: "ok", hostname: nil, user: nil, port: 0))
        XCTAssertThrowsError(try registry.add(name: "ok", hostname: nil, user: nil, port: 99_999))
    }

    func testImportOffersOnlyUnregisteredConfigNames() throws {
        let config = [SSHConfigHost(alias: "build", hostname: "build.internal", user: "ci", port: 2222),
                      SSHConfigHost(alias: "laptop", hostname: "10.0.0.7")]
        let registry = HostRegistry(store: makeStore(), sshConfig: { config })

        XCTAssertEqual(registry.importable().map(\.alias), ["build", "laptop"])
        let imported = try registry.importFromSSHConfig(name: "build")
        XCTAssertEqual(imported.source, .sshConfig)
        XCTAssertEqual(imported.user, "ci")
        XCTAssertEqual(registry.importable().map(\.alias), ["laptop"])

        XCTAssertThrowsError(try registry.importFromSSHConfig(name: "nope")) {
            XCTAssertEqual($0 as? HostRegistryError, .notInSSHConfig("nope"))
        }
    }

    func testRequireRejectsLocalAndUnknownHosts() throws {
        let registry = HostRegistry(store: makeStore(), sshConfig: { [] })
        XCTAssertThrowsError(try registry.require(host: .local))
        let ssh = try XCTUnwrap(ExecutionHostId.ssh("ghost"))
        XCTAssertThrowsError(try registry.require(host: ssh)) {
            XCTAssertEqual($0 as? HostRegistryError, .unknownHost("ghost"))
        }
    }

    // MARK: - ExecutionHostId

    func testExecutionHostIdVocabulary() {
        XCTAssertEqual(ExecutionHostId(rawValue: "local"), .local)
        XCTAssertEqual(ExecutionHostId(rawValue: "ssh:build")?.rawValue, "ssh:build")
        XCTAssertEqual(ExecutionHostId(rawValue: "ssh:build")?.name, "build")
        XCTAssertEqual(ExecutionHostId(rawValue: "ssh:build")?.label, "build")
        // An unknown or malformed kind must not resolve to local — silently
        // downgrading a remote id is how work runs on the wrong machine.
        XCTAssertNil(ExecutionHostId(rawValue: "runtime:vm-1"))
        XCTAssertNil(ExecutionHostId(rawValue: "ssh:"))
        XCTAssertNil(ExecutionHostId(rawValue: "ssh:two words"))
        XCTAssertNil(ExecutionHostId(rawValue: ""))
    }

    // MARK: - ssh invocation shape

    func testSSHConfigHostsConnectByAliasAndManualHostsByTarget() {
        let imported = HostRecord(name: "build", hostname: "build.internal", user: "ci",
                                  port: 2222, source: .sshConfig)
        // The alias is the destination: rewriting it to the hostname would drop the
        // user's ProxyJump/IdentityFile config for that host.
        XCTAssertEqual(SSHCommand.remoteShellArgv(for: imported), ["/usr/bin/ssh", "-tt", "build"])
        XCTAssertEqual(SSHCommand.probeArgv(for: imported),
                       ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "build", "true"])

        let manual = HostRecord(name: "box", hostname: "10.0.0.5", user: "dk", port: 2200)
        XCTAssertEqual(SSHCommand.remoteShellArgv(for: manual),
                       ["/usr/bin/ssh", "-tt", "-p", "2200", "dk@10.0.0.5"])
        XCTAssertEqual(SSHCommand.remoteShellArgv(for: manual, command: "uptime -p"),
                       ["/usr/bin/ssh", "-tt", "-p", "2200", "dk@10.0.0.5", "uptime -p"])
        XCTAssertEqual(SSHCommand.remoteShellCommandLine(for: manual, command: "uptime -p"),
                       "/usr/bin/ssh -tt -p 2200 dk@10.0.0.5 'uptime -p'")
    }
}
