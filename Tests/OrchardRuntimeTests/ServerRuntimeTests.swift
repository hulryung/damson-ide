import Darwin
import XCTest
import OrchardProtocol
@testable import OrchardRuntime

final class ServerRuntimeTests: XCTestCase {
    func testStatusIsStampedByRegistryServer() async {
        var registry = CommandRegistry(); registry.register(StatusHandler(runtimeId: "rt_test"))
        let response = await InMemoryRuntimeServer(registry: registry, runtimeId: "rt_test").perform(RPCRequest(method: "status"))
        XCTAssertTrue(response.ok); XCTAssertEqual(response.meta?.runtimeId, "rt_test")
    }

    func testSocketMetadataAndPermissions() throws {
        let root = URL(fileURLWithPath: "/tmp/o-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = CommandRegistry(); registry.register(StatusHandler(runtimeId: "rt_test"))
        let server = try UnixSocketServer(registry: registry, fileManager: ScopedFileManager(root: root), runtimeId: "rt_test", authToken: "secret")
        defer { server.stop(fileManager: ScopedFileManager(root: root)) }
        XCTAssertEqual(server.metadata.authToken, "secret")
        let mode = (try FileManager.default.attributesOfItem(atPath: server.metadata.socketPath)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
    }
}

// ScopedFileManager lives in EndToEndOrchestrationTests.swift (shared by both suites).
