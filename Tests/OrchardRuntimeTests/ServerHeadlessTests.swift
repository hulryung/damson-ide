import Darwin
import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

final class ServerHeadlessTests: XCTestCase {
    func testLegacyMetadataWithoutModeDefaultsToApp() throws {
        let data = Data("""
        {"runtimeId":"rt_old","pid":42,"socketPath":"/tmp/old.sock","authToken":"old","startedAt":"2026-08-23T00:00:00Z"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(RuntimeMetadata.self, from: data).mode, .app)
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/o-head-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    func testHeadlessLifecyclePublishesAndRemovesMetadata() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrchardRuntimeHost(
            terminalFactory: { _, _ in ScriptedTerminalSession() },
            dataDirectory: root, mode: .headless)
        let metadata = try host.startSocketServer(authToken: "headless-secret")

        XCTAssertEqual(metadata.mode, .headless)
        let published = try RuntimeDiscovery.load(dataDirectory: root)
        XCTAssertEqual(published.runtimeId, metadata.runtimeId)
        XCTAssertEqual(published.pid, metadata.pid)
        XCTAssertEqual(published.socketPath, metadata.socketPath)
        XCTAssertEqual(published.authToken, metadata.authToken)
        XCTAssertEqual(published.mode, .headless)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.socketPath))

        host.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: RuntimePaths.metadataURL(dataDirectory: root).path))
    }

    @MainActor
    func testDeadOwnerIsReclaimedAndLiveOwnerIsRefused() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staleSocket = root.appendingPathComponent("run/stale.sock")
        try FileManager.default.createDirectory(at: staleSocket.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: staleSocket.path,
                                                      contents: Data()))
        try writeMetadata(RuntimeMetadata(runtimeId: "rt_stale", pid: 2_000_000_000,
                                          socketPath: staleSocket.path,
                                          authToken: "stale", mode: .headless), to: root)

        let host = try OrchardRuntimeHost(
            terminalFactory: { _, _ in ScriptedTerminalSession() },
            dataDirectory: root, mode: .headless)
        let current = try host.startSocketServer()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleSocket.path))
        XCTAssertEqual(try RuntimeDiscovery.load(dataDirectory: root).runtimeId,
                       current.runtimeId)

        let contender = try OrchardRuntimeHost(
            terminalFactory: { _, _ in ScriptedTerminalSession() },
            dataDirectory: root, mode: .headless)
        XCTAssertThrowsError(try contender.startSocketServer()) { error in
            guard case UnixSocketServerError.runtimeAlreadyRunning(let pid) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(pid, getpid())
        }
        host.shutdown()
    }

    @MainActor
    func testHeadlessHostStatusRoundTripsOverSocket() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try OrchardRuntimeHost(
            terminalFactory: { _, _ in ScriptedTerminalSession() },
            dataDirectory: root, mode: .headless)
        let metadata = try host.startSocketServer()
        defer { host.shutdown() }

        let response = try NDJSONClient(socketPath: metadata.socketPath,
                                        authToken: metadata.authToken).call("status", [:])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.field("mode")?.stringValue, "headless")
        XCTAssertEqual(response.result?.field("runtimeId")?.stringValue, metadata.runtimeId)
    }

    private func writeMetadata(_ metadata: RuntimeMetadata, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: RuntimePaths.metadataURL(dataDirectory: root), options: .atomic)
    }

    func testPrepareKeepsShortSocketBesideData() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try RuntimePaths.prepare(dataDirectory: root)
        XCTAssertEqual(paths.data, root)
        XCTAssertEqual(paths.run, root.appendingPathComponent("run", isDirectory: true))
        let socket = paths.run.appendingPathComponent(RuntimePaths.socketName())
        XCTAssertLessThan(socket.path.utf8.count, RuntimePaths.unixSocketPathLimit)
    }

    func testPrepareMovesLongSocketUnderTmpOrchardUid() throws {
        let long = String(repeating: "d", count: 90)
        let root = URL(fileURLWithPath: "/tmp/\(long)-\(String(UUID().uuidString.prefix(8)))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferred = root.appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent(RuntimePaths.socketName())
        XCTAssertGreaterThanOrEqual(preferred.path.utf8.count, RuntimePaths.unixSocketPathLimit)

        let paths = try RuntimePaths.prepare(dataDirectory: root)
        XCTAssertEqual(paths.data, root)
        XCTAssertEqual(paths.run, RuntimePaths.temporarySocketRoot())
        let socket = paths.run.appendingPathComponent(RuntimePaths.socketName())
        XCTAssertLessThan(socket.path.utf8.count, RuntimePaths.unixSocketPathLimit)
        XCTAssertTrue(socket.path.contains("orchard-\(getuid())"))
    }

    @MainActor
    func testLongDataDirPublishesFallbackSocketInMetadata() throws {
        let long = String(repeating: "d", count: 90)
        let root = URL(fileURLWithPath: "/tmp/\(long)-\(String(UUID().uuidString.prefix(8)))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let host = try OrchardRuntimeHost(
            terminalFactory: { _, _ in ScriptedTerminalSession() },
            dataDirectory: root, mode: .headless)
        let metadata = try host.startSocketServer(authToken: "long-secret")
        defer { host.shutdown() }

        XCTAssertTrue(metadata.socketPath.hasPrefix(RuntimePaths.temporarySocketRoot().path))
        XCTAssertLessThan(metadata.socketPath.utf8.count, RuntimePaths.unixSocketPathLimit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.socketPath))
        let published = try RuntimeDiscovery.load(dataDirectory: root)
        XCTAssertEqual(published.socketPath, metadata.socketPath)
        XCTAssertEqual(published.authToken, "long-secret")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: RuntimePaths.metadataURL(dataDirectory: root).path))
        XCTAssertNotEqual(URL(fileURLWithPath: metadata.socketPath).deletingLastPathComponent(),
                          root.appendingPathComponent("run", isDirectory: true),
                          "socket must leave a too-long data-dir while metadata stays there")
    }
}
