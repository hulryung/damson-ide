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

    func testFiftyConcurrentStatusCallsAreBoundedAndDoNotLeakFDs() async throws {
        let root = URL(fileURLWithPath: "/tmp/o-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = CommandRegistry(); registry.register(StatusHandler(runtimeId: "rt_load"))
        let scoped = ScopedFileManager(root: root)
        let server = try UnixSocketServer(registry: registry, fileManager: scoped,
                                          runtimeId: "rt_load", authToken: "secret")
        server.start()
        defer { server.stop(fileManager: scoped) }
        let baselineFDs = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let client = NDJSONClient(socketPath: server.metadata.socketPath, authToken: "secret")

        let failures = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let lock = NSLock()
                var failures: [String] = []
                DispatchQueue.concurrentPerform(iterations: 50) { _ in
                    do {
                        if try !client.call("status", [:]).ok {
                            lock.lock(); failures.append("non-ok response"); lock.unlock()
                        }
                    } catch {
                        lock.lock(); failures.append(String(describing: error)); lock.unlock()
                    }
                }
                continuation.resume(returning: failures)
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
        for _ in 0..<50 { try abruptClose(socketPath: server.metadata.socketPath) }
        XCTAssertTrue(try client.call("status", [:]).ok)
        let finalFDs = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(server.peakActiveConnectionCount, UnixSocketServer.maximumConcurrentConnections)
        XCTAssertLessThanOrEqual(finalFDs, baselineFDs + 2, "abrupt clients leaked descriptors")
        print("PERF socket calls=50 completed=50 peak=\(server.peakActiveConnectionCount) cap=\(UnixSocketServer.maximumConcurrentConnections) fdDelta=\(finalFDs - baselineFDs)")
    }

    private func abruptClose(socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            if let base = bytes.baseAddress { memset(base, 0, bytes.count) }
            socketPath.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        Darwin.close(fd)
    }
}

// ScopedFileManager lives in EndToEndOrchestrationTests.swift (shared by both suites).
