import Darwin
import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// Wave-2 acceptance: boot the in-process runtime against a temp data dir and drive
/// the coordinator/worker loop through the REAL unix-socket transport —
/// run-create → task-create → dispatch → send worker_done → check --ack — asserting
/// the round trip end to end (delivery, verbatim replay, ack, task settlement).
final class EndToEndOrchestrationTests: XCTestCase {
    private var root: URL!
    private var host: OrchardRuntimeHost!
    private var client: NDJSONClient!

    override func setUp() async throws {
        try await super.setUp()
        // Short prefix keeps the socket path far under sockaddr_un's 104-byte cap.
        root = URL(fileURLWithPath: "/tmp/o-e2e-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scoped = ScopedFileManager(root: root)
        let (host, metadata) = try await MainActor.run { () -> (OrchardRuntimeHost, RuntimeMetadata) in
            let host = try OrchardRuntimeHost(
                fileManager: scoped,
                terminalFactory: { _, _ in ScriptedTerminalSession() })
            let metadata = try host.startSocketServer()
            return (host, metadata)
        }
        self.host = host
        client = NDJSONClient(socketPath: metadata.socketPath, authToken: metadata.authToken)
    }

    override func tearDown() async throws {
        if let host {
            await MainActor.run { host.shutdown() }
        }
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    func testWorkerDoneRoundTripOverTheSocket() async throws {
        // Boot published discovery metadata for the CLI.
        let metadataURL = root.appendingPathComponent("Orchard/orchard-runtime.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        // 1. Coordinator creates + binds a run.
        let created = try client.call("run-create", [
            "objective": .string("integrate the control plane"),
            "from": .string("term_coordinator"),
        ])
        XCTAssertTrue(created.ok, String(describing: created.error))
        let runID = try XCTUnwrap(created.result?.field("runId")?.stringValue)

        // 2. Task inferred into the coordinator's bound run; no deps ⇒ born ready.
        let task = try client.call("task-create", [
            "spec": .string("ship the integration"),
            "task-title": .string("Integration"),
            "from": .string("term_coordinator"),
        ])
        XCTAssertTrue(task.ok, String(describing: task.error))
        let taskID = try XCTUnwrap(task.result?.field("taskId")?.stringValue)
        XCTAssertEqual(task.result?.field("task")?.field("status")?.stringValue, "ready")

        // 3. Dispatch to a worker terminal; --inject returns the preamble text with
        //    the real ids (and the capability secret) inlined for injection.
        let dispatched = try client.call("dispatch", [
            "task": .string(taskID),
            "to": .string("term_worker"),
            "inject": .bool(true),
            "from": .string("term_coordinator"),
        ])
        XCTAssertTrue(dispatched.ok, String(describing: dispatched.error))
        let dispatchID = try XCTUnwrap(dispatched.result?.field("dispatchId")?.stringValue)
        // T11: lifecycle sends must present the minted capability secret.
        let capability = try XCTUnwrap(dispatched.result?.field("dispatchCapability")?.stringValue)
        let preamble = try XCTUnwrap(dispatched.result?.field("preamble")?.stringValue)
        XCTAssertTrue(preamble.contains("--task-id \(taskID)"))
        XCTAssertTrue(preamble.contains("--dispatch-id \(dispatchID)"))
        XCTAssertTrue(preamble.contains("--dispatch-capability dcap_"))
        XCTAssertTrue(preamble.contains("worker_done"))
        XCTAssertEqual(dispatched.result?.field("status")?.stringValue, "dispatched")

        // 4+5. Coordinator parks a long-poll BEFORE the report lands; the worker's
        //      worker_done must wake it with a fresh delivery.
        let waitingClient = client!
        let waiter = Task.detached { () throws -> RPCResponse in
            try waitingClient.call("check", [
                "terminal": .string("term_coordinator"),
                "wait": .bool(true),
                "types": .string("worker_done,escalation"),
                "timeout-ms": .number(10000),
            ])
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let report = try client.call("send", [
            "from": .string("term_worker"),
            "dispatch-capability": .string(capability),
            "type": .string("worker_done"),
            "subject": .string("done"),
            "body": .string("Wired the adapter. Found nothing blocking. Nothing left."),
            "task-id": .string(taskID),
            "dispatch-id": .string(dispatchID),
            "outcome": .string("succeeded"),
            "files-modified": .string("Sources/a.swift,Sources/b.swift"),
        ])
        XCTAssertTrue(report.ok, String(describing: report.error))
        let lifecycle = try XCTUnwrap(report.result?.field("lifecycle"))
        XCTAssertEqual(lifecycle.field("status")?.stringValue, "settled")
        XCTAssertEqual(lifecycle.field("outcome")?.stringValue, "succeeded")
        XCTAssertEqual(lifecycle.field("taskId")?.stringValue, taskID)
        XCTAssertEqual(lifecycle.field("dispatchId")?.stringValue, dispatchID)

        let woken = try await waiter.value
        XCTAssertTrue(woken.ok, String(describing: woken.error))
        XCTAssertEqual(woken.result?.field("count")?.numberValue, 1)
        let deliveryID = try XCTUnwrap(woken.result?.field("deliveryId")?.stringValue)
        let delivered = try XCTUnwrap(woken.result?.field("messages")?.arrayValue?.first)
        XCTAssertEqual(delivered.field("type")?.stringValue, "worker_done")
        XCTAssertEqual(delivered.field("from_handle")?.stringValue, "term_worker")
        XCTAssertEqual(delivered.field("to_handle")?.stringValue, "run:\(runID)")

        // Verbatim replay until ack: an un-acked re-check hands back the same batch.
        let replay = try client.call("check", ["terminal": .string("term_coordinator")])
        XCTAssertTrue(replay.ok)
        XCTAssertEqual(replay.result?.field("deliveryId")?.stringValue, deliveryID)
        XCTAssertEqual(replay.result?.field("replayed")?.boolValue, true)
        XCTAssertEqual(replay.result?.field("count")?.numberValue, 1)

        // 6. Ack closes the outstanding slot; nothing further to deliver.
        let acked = try client.call("check", [
            "terminal": .string("term_coordinator"),
            "ack": .string(deliveryID),
        ])
        XCTAssertTrue(acked.ok, String(describing: acked.error))
        XCTAssertEqual(acked.result?.field("acknowledged")?.field("deliveryId")?.stringValue, deliveryID)
        XCTAssertEqual(acked.result?.field("acknowledged")?.field("duplicate")?.boolValue, false)
        XCTAssertEqual(acked.result?.field("count")?.numberValue, 0)

        // worker_done auto-completed the task and its dispatch.
        let tasks = try client.call("task-list", ["run": .string(runID)])
        XCTAssertEqual(tasks.result?.field("tasks")?.arrayValue?.first?.field("status")?.stringValue,
                       "completed")
        let shown = try client.call("dispatch-show", ["id": .string(dispatchID)])
        XCTAssertEqual(shown.result?.field("dispatch")?.field("status")?.stringValue, "completed")
        XCTAssertEqual(shown.result?.field("heartbeatStale")?.boolValue, false)

        // Every response carries the runtime identity.
        XCTAssertEqual(acked.meta?.runtimeId, host.runtimeId)
    }

    func testRuntimeMetadataMatchesLiveSocket() throws {
        let metadataURL = root.appendingPathComponent("Orchard/orchard-runtime.json")
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RuntimeMetadata.self, from: data)
        XCTAssertEqual(metadata.runtimeId, host.runtimeId)
        XCTAssertEqual(metadata.pid, getpid())
        XCTAssertEqual(metadata.socketPath, client.socketPath)

        let status = try client.call("status", [:])
        XCTAssertTrue(status.ok)
        XCTAssertEqual(status.result?.field("runtimeId")?.stringValue, host.runtimeId)
    }
}

// MARK: - Test transport

/// A minimal NDJSON socket client mirroring the `orchard` CLI's transport: one
/// connection per request, keepalive frames skipped, response envelope decoded.
final class NDJSONClient: @unchecked Sendable {
    let socketPath: String
    let authToken: String

    init(socketPath: String, authToken: String) {
        self.socketPath = socketPath
        self.authToken = authToken
    }

    struct TransportError: Error, CustomStringConvertible {
        let description: String
    }

    func call(_ method: String, _ params: [String: JSONValue]) throws -> RPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError(description: "socket() failed") }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw TransportError(description: "socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            if let base = bytes.baseAddress { memset(base, 0, bytes.count) }
            socketPath.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard connected == 0 else {
            throw TransportError(description: "connect failed: \(String(cString: strerror(errno)))")
        }

        var data = try JSONEncoder().encode(
            RPCRequest(method: method, params: .object(params), authToken: authToken))
        data.append(10)
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return Darwin.write(fd, base, bytes.count)
        }
        guard written == data.count else { throw TransportError(description: "short write") }

        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            guard Darwin.read(fd, &byte, 1) > 0 else {
                throw TransportError(description: "connection closed before response")
            }
            if byte != 10 {
                buffer.append(byte)
                continue
            }
            if let frame = try? JSONDecoder().decode([String: JSONValue].self, from: buffer),
               frame["_keepalive"]?.boolValue == true {
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            return try JSONDecoder().decode(RPCResponse.self, from: buffer)
        }
    }
}

/// Redirects `applicationSupportDirectory` into the test's temp root, so the runtime's
/// data dir, socket, and metadata all live (and die) with the test.
final class ScopedFileManager: FileManager, @unchecked Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: SearchPathDirectory,
                       in domainMask: SearchPathDomainMask) -> [URL] {
        [root]
    }
}
