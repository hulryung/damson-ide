import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

@MainActor
final class PortHandlerTests: XCTestCase {
    private func makeHandler(ports: PortService) -> (InMemoryRuntimeServer, WorkspaceService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspaces = WorkspaceService(dataURL: root.appendingPathComponent("orchard-data.json"))
        let terminals = TerminalService(factory: { _, _ in ScriptedTerminalSession() })
        var registry = CommandRegistry()
        registry.register(PortCommandHandler(ports: ports, workspaces: workspaces, terminals: terminals))
        return (InMemoryRuntimeServer(registry: registry, runtimeId: "rt_ports"), workspaces, root)
    }

    func testWorkspacePortsReturnsAttributedSnapshot() async throws {
        let probe = FixturePortProbe("p9\ncnode\nn127.0.0.1:5173\n")
        let ports = PortService(
            workspaces: {
                [PortWorkspaceProbe(id: "r::/repo/wt", repoId: "r",
                                    displayName: "feature", path: "/repo/wt")]
            },
            probe: probe,
            cwdLookup: { _ in "/repo/wt" },
            interval: 60)
        _ = await ports.sweep()
        let (server, _, root) = makeHandler(ports: ports)
        defer { try? FileManager.default.removeItem(at: root) }

        let response = await server.perform(RPCRequest(id: "1", method: "workspace-ports"))
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        let list = response.result?.objectValue?["ports"]?.arrayValue ?? []
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.objectValue?["port"]?.intValue, 5173)
        XCTAssertEqual(list.first?.objectValue?["worktreeId"]?.stringValue, "r::/repo/wt")
        XCTAssertEqual(list.first?.objectValue?["kind"]?.stringValue, "workspace")
    }

    func testWorktreePsIncludesProcessesAndPorts() async throws {
        let probe = FixturePortProbe("p9\ncnode\nn127.0.0.1:5173\n")
        let ports = PortService(
            workspaces: { [] },
            probe: probe,
            cwdLookup: { _ in "/repo/wt" },
            interval: 60)
        let (server, _, root) = makeHandler(ports: ports)
        defer { try? FileManager.default.removeItem(at: root) }

        let response = await server.perform(RPCRequest(id: "1", method: "worktree-ps"))
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        let object = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(object["worktrees"]?.arrayValue?.count, 0)
        XCTAssertEqual(object["totalCount"]?.intValue, 0)
        XCTAssertEqual(object["truncated"]?.boolValue, false)
        XCTAssertEqual(object["platform"]?.stringValue, "darwin")
    }
}
