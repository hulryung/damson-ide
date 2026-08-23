import XCTest
@testable import OrchardRuntime
import OrchardProtocol
import OrchardTerminals

/// RPC contract for the browser verbs against the in-memory server seam — the
/// same envelope the unix socket carries, so what passes here is proven for the
/// `orchard browser …` CLI.
final class BrowserHandlerTests: XCTestCase {
    private var host: FakeBrowserHost!
    private var service: BrowserService!
    private var server: InMemoryRuntimeServer!
    private let ws = "/tmp/ws-rpc"

    override func setUp() {
        super.setUp()
        host = FakeBrowserHost()
        service = BrowserService()
        var registry = CommandRegistry()
        registry.register(BrowserCommandHandler(service: service))
        server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_test")
    }

    private func call(_ method: String, _ params: [String: JSONValue]) async -> RPCResponse {
        var params = params
        params["worktree"] = params["worktree"] ?? .string(ws)
        return await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    private func attachHost() async {
        await service.attach(host: host)
    }

    func testAllBrowserVerbsAreRegistered() {
        var registry = CommandRegistry()
        registry.register(BrowserCommandHandler(service: service))
        for verb in ["browser-goto", "browser-back", "browser-forward", "browser-reload",
                     "browser-snapshot", "browser-click", "browser-fill", "browser-type",
                     "browser-screenshot", "browser-eval", "browser-console", "browser-tab"] {
            XCTAssertNotNil(registry.handler(for: verb), "missing \(verb)")
        }
    }

    func testMissingArgumentsFailTyped() async {
        await attachHost()
        let noWorktree = await server.perform(RPCRequest(method: "browser-goto",
                                                         params: .object(["url": .string("https://x.test")])))
        XCTAssertEqual(noWorktree.error?.code, "invalid_argument")

        let noURL = await call("browser-goto", [:])
        XCTAssertEqual(noURL.error?.code, "invalid_argument")

        let noRef = await call("browser-click", [:])
        XCTAssertEqual(noRef.error?.code, "invalid_argument")

        let noText = await call("browser-fill", ["ref": .string("@e1")])
        XCTAssertEqual(noText.error?.code, "invalid_argument")
    }

    func testNoHostSurfacesBrowserUnavailable() async {
        let response = await call("browser-goto", ["url": .string("https://x.test")])
        XCTAssertEqual(response.error?.code, "browser_unavailable")
    }

    func testGotoSnapshotClickRoundTrip() async throws {
        await attachHost()
        let goto = await call("browser-goto", ["url": .string("https://fake.test/")])
        XCTAssertTrue(goto.ok)
        let pageId = goto.result?.objectValue?["page"]?.objectValue?["id"]?.stringValue
        XCTAssertNotNil(pageId)

        let snap = await call("browser-snapshot", [:])
        XCTAssertTrue(snap.ok)
        let outline = snap.result?.objectValue?["outline"]?.stringValue ?? ""
        XCTAssertTrue(outline.contains("[@e1]"))
        XCTAssertEqual(snap.result?.objectValue?["refCount"]?.numberValue, 3)

        let click = await call("browser-click", ["ref": .string("@e1")])
        XCTAssertTrue(click.ok)
        XCTAssertEqual(click.result?.objectValue?["done"]?.boolValue, true)
    }

    func testStaleRefSurfacesOverRPC() async throws {
        await attachHost()
        _ = await call("browser-goto", ["url": .string("https://fake.test/")])
        _ = await call("browser-snapshot", [:])
        _ = await call("browser-goto", ["url": .string("https://fake.test/away")])

        let click = await call("browser-click", ["ref": .string("@e1")])
        XCTAssertFalse(click.ok)
        XCTAssertEqual(click.error?.code, "browser_stale_ref")
        XCTAssertTrue(click.error?.message.contains("snapshot") ?? false,
                      "error tells the agent to re-snapshot")
    }

    func testEvalReturnsJSONEncodedValue() async {
        await attachHost()
        _ = await call("browser-goto", ["url": .string("https://fake.test/")])
        host.evalResult = #"{"ok":true,"value":"the page title"}"#
        let response = await call("browser-eval", ["js": .string("document.title")])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.objectValue?["value"]?.stringValue, "the page title")
    }

    func testScreenshotReturnsTempFilePath() async {
        await attachHost()
        _ = await call("browser-goto", ["url": .string("https://fake.test/")])
        let response = await call("browser-screenshot", [:])
        XCTAssertTrue(response.ok)
        let path = response.result?.objectValue?["path"]?.stringValue ?? ""
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(response.result?.objectValue?["byteCount"]?.numberValue,
                       Double(host.screenshotData.count))
    }

    func testConsoleEntriesFlowThrough() async {
        await attachHost()
        let goto = await call("browser-goto", ["url": .string("https://fake.test/")])
        let pageId = goto.result?.objectValue?["page"]?.objectValue?["id"]?.stringValue ?? ""
        host.consoleLog[pageId] = [BrowserConsoleEntry(sequence: 1, level: "error", text: "boom")]

        let response = await call("browser-console", [:])
        XCTAssertTrue(response.ok)
        let entries = response.result?.objectValue?["entries"]?.arrayValue
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?.objectValue?["level"]?.stringValue, "error")
    }

    func testRuntimeAssemblyRegistersBrowserVerbs() async throws {
        // The real assembly (not a hand-built registry): browser verbs must be
        // routable, and with no app attached they fail typed, not unknown.
        let root = URL(fileURLWithPath: "/tmp/o-brw-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scoped = ScopedFileManager(root: root)
        let runtime = try await MainActor.run {
            try OrchardRuntimeHost(fileManager: scoped,
                                   terminalFactory: { _, _ in ScriptedTerminalSession() })
        }
        XCTAssertNotNil(runtime.registry.handler(for: "browser-goto"))
        XCTAssertNotNil(runtime.registry.handler(for: "browser-tab"))

        let response = await runtime.inMemory.perform(RPCRequest(
            method: "browser-snapshot",
            params: .object(["worktree": .string("/tmp/nowhere")])))
        XCTAssertEqual(response.error?.code, "browser_unavailable")
    }

    func testTabVerbActions() async {
        await attachHost()
        _ = await call("browser-goto", ["url": .string("https://one.test")])

        // Positional form the CLI produces: `browser tab create` → _args ["create"].
        let created = await call("browser-tab", ["_args": .array([.string("create")]),
                                                 "url": .string("https://two.test")])
        XCTAssertTrue(created.ok)
        let newId = created.result?.objectValue?["page"]?.objectValue?["id"]?.stringValue ?? ""

        let list = await call("browser-tab", ["_args": .array([.string("list")])])
        XCTAssertEqual(list.result?.objectValue?["tabs"]?.arrayValue?.count, 2)
        XCTAssertEqual(list.result?.objectValue?["activePageId"]?.stringValue, newId)

        let switched = await call("browser-tab", ["action": .string("switch"),
                                                  "page": .string(newId)])
        XCTAssertTrue(switched.ok)

        let closed = await call("browser-tab", ["_args": .array([.string("close")]),
                                                "page": .string(newId)])
        XCTAssertTrue(closed.ok)
        let after = await call("browser-tab", [:])  // defaults to list
        XCTAssertEqual(after.result?.objectValue?["tabs"]?.arrayValue?.count, 1)

        let bogus = await call("browser-tab", ["_args": .array([.string("teleport")])])
        XCTAssertEqual(bogus.error?.code, "invalid_argument")
    }
}
