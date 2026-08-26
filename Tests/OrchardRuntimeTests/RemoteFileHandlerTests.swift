import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// T85: file RPC against a remote workspace through a scripted ssh runner.
@MainActor
final class RemoteFileHandlerTests: XCTestCase {
    private var tmp: URL!
    private var store: OrchardDataStore!
    private var service: WorkspaceService!
    private var runner: ScriptedSSHRunner!
    private var server: InMemoryRuntimeServer!
    private var workspaceId: String = ""

    private static let latin1 = Data([
        0x63, 0x61, 0x66, 0xE9, 0x20, 0x64, 0xE9, 0x6A, 0xE0, 0x20, 0x76, 0x75, 0x0A,
    ])

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-remote-file-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
        runner = ScriptedSSHRunner()
        let hosts = HostRegistry(store: store, sshConfig: { [] })
        try hosts.add(name: "loop", hostname: "127.0.0.1", user: "ci", port: 2222)

        service = WorkspaceService(store: store, worktreesRoot: tmp.appendingPathComponent("wt"))
        service.hostCommandRunner = runner
        service.remoteCommandTimeout = 1

        runner.on("test -d /home/ci/proj/.git", HostCommandResult(exitCode: 0))
        runner.on("for-each-ref '--format=%(refname)' refs/remotes",
                  HostCommandResult(exitCode: 0, stdout: "refs/remotes/origin/main\n"))
        runner.on("worktree list --porcelain", HostCommandResult(exitCode: 0, stdout: """
            worktree /home/ci/proj
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main
            """))

        var registry = CommandRegistry()
        registry.register(RepoRegistryHandler(service: service))
        registry.register(WorkspaceCommandHandler(service: service))
        registry.register(FileCommandHandler(workspaces: service, hostRunner: runner, remoteTimeout: 1))
        server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_rfiles")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func registerRepo() async throws {
        let added = await server.perform(RPCRequest(method: "repo-add", params: .object([
            "path": .string("/home/ci/proj"),
            "host": .string("ssh:loop"),
            "displayName": .string("proj"),
        ])))
        XCTAssertTrue(added.ok, String(describing: added.error))
        let listed = await server.perform(RPCRequest(method: "worktree-list", params: .object([
            "repo": .string(added.result?.objectValue?["id"]?.stringValue ?? ""),
        ])))
        workspaceId = try XCTUnwrap(
            listed.result?.objectValue?["worktrees"]?.arrayValue?.first?
                .objectValue?["id"]?.stringValue)
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        var merged = params
        if merged["worktree"] == nil { merged["worktree"] = .string(workspaceId) }
        return await server.perform(RPCRequest(method: method, params: .object(merged)))
    }

    private func protocolOK(_ body: String) -> HostCommandResult {
        HostCommandResult(exitCode: 0, stdout: "ORCHARD-FILE/1\nok\nnone\n" + body)
    }

    func testPreviewOfRemoteLatin1IsTypedNotUTF8() async throws {
        try await registerRepo()
        let b64 = Self.latin1.base64EncodedString()
        runner.on("ORCHARD_FILE_OP=read ORCHARD_FILE_REL=", protocolOK("""
            STAT\t\(Self.latin1.count)\t0\t0\t1
            BODY\t\(Self.latin1.count)\t\(b64)
            """))
        let preview = await call("file-preview", ["path": .string("notes.txt")])
        XCTAssertTrue(preview.ok, String(describing: preview.error))
        XCTAssertEqual(preview.result?.objectValue?["content"]?.stringValue, "")
        XCTAssertEqual(preview.result?.objectValue?["isBinary"]?.boolValue, true)
        XCTAssertEqual(preview.result?.objectValue?["notTextReason"]?.stringValue, "not_utf8")
        XCTAssertEqual(preview.result?.objectValue?["byteLength"]?.intValue
                       ?? preview.result?.objectValue?["byteLength"]?.numberValue.map { Int($0) },
                       Self.latin1.count)
        XCTAssertFalse((preview.result?.objectValue?["content"]?.stringValue ?? "").contains("\u{FFFD}"))
    }

    func testPreviewOfRemoteUTF8IsContent() async throws {
        try await registerRepo()
        let data = Data("hello\n".utf8)
        runner.on("ORCHARD_FILE_OP=read ORCHARD_FILE_REL=", protocolOK("""
            STAT\t\(data.count)\t0\t0\t1
            BODY\t\(data.count)\t\(data.base64EncodedString())
            """))
        let preview = await call("file-preview", ["path": .string("README.md")])
        XCTAssertTrue(preview.ok, String(describing: preview.error))
        XCTAssertEqual(preview.result?.objectValue?["content"]?.stringValue, "hello\n")
        XCTAssertEqual(preview.result?.objectValue?["isBinary"]?.boolValue, false)
        XCTAssertNil(preview.result?.objectValue?["notTextReason"])
    }

    func testSearchAndListGoOverSSH() async throws {
        try await registerRepo()
        runner.on("ORCHARD_FILE_OP=search", protocolOK("""
            HIT\t\(Data("src/app.swift".utf8).base64EncodedString())\t1\t\(Data("hello".utf8).base64EncodedString())
            TOTAL\t1
            """))
        let search = await call("file-search", ["query": .string("hello")])
        XCTAssertTrue(search.ok, String(describing: search.error))
        XCTAssertEqual(
            search.result?.objectValue?["matches"]?.arrayValue?.first?.objectValue?["path"]?.stringValue,
            "src/app.swift")

        runner.on("ORCHARD_FILE_OP=list", protocolOK("""
            TOTAL\t1
            LIST\t\(Data("README.md".utf8).base64EncodedString())
            """))
        let list = await call("file-list", ["query": .string("md")])
        XCTAssertEqual(list.result?.objectValue?["files"]?.arrayValue?.compactMap(\.stringValue),
                       ["README.md"])
    }

    func testPathEscapeDoesNotSSH() async throws {
        try await registerRepo()
        let before = runner.commandLines
        let response = await call("file-preview", ["path": .string("../secret")])
        XCTAssertEqual(response.error?.code, "path_escape")
        XCTAssertEqual(runner.commandLines, before)
    }

    func testOpenRevealAndDiffStayTypedRemoteUnsupported() async throws {
        try await registerRepo()
        let opened = await call("file-open", ["path": .string("README.md")])
        XCTAssertEqual(opened.error?.code, "remote_unsupported")
        XCTAssertTrue(opened.error?.message.contains("local GUI") ?? false, opened.error?.message ?? "")

        let changed = await call("file-open-changed", ["mode": .string("diff")])
        XCTAssertEqual(changed.error?.code, "remote_unsupported")
        XCTAssertTrue(changed.error?.message.contains("local GUI") ?? false, changed.error?.message ?? "")

        let diff = await call("file-diff", ["path": .string("README.md")])
        XCTAssertEqual(diff.error?.code, "remote_unsupported")
        XCTAssertTrue(diff.error?.message.contains("local git") ?? false, diff.error?.message ?? "")
    }

    func testUnverifiableIsHostUnverifiableNotAMissingFile() async throws {
        try await registerRepo()
        runner.on("ORCHARD_FILE_OP=stat", HostCommandResult(
            exitCode: 255, stderr: "ssh: connect to host 127.0.0.1 port 2222: Connection refused\n"))
        let stat = await call("file-stat", ["path": .string("README.md")])
        XCTAssertEqual(stat.error?.code, "host_unverifiable")
        XCTAssertTrue(stat.error?.message.contains("Loss of contact") ?? false,
                      stat.error?.message ?? "")
    }
}
