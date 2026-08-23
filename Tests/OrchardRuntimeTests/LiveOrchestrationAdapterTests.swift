import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// Adapter-contract coverage over the in-process registry (the same registry the
/// socket serves): CLI-flag parsing, blocking ask/reply, retry-request idempotency,
/// worker-mode check, repo verbs on T4's store, and reset.
final class LiveOrchestrationAdapterTests: XCTestCase {
    private var root: URL!
    private var host: OrchardRuntimeHost!

    override func setUp() async throws {
        try await super.setUp()
        root = URL(fileURLWithPath: "/tmp/o-adp-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scoped = ScopedFileManager(root: root)
        host = try await MainActor.run {
            try OrchardRuntimeHost(fileManager: scoped,
                                   terminalFactory: { _, _ in ScriptedTerminalSession() })
        }
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func perform(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await host.inMemory.perform(RPCRequest(method: method, params: .object(params)))
    }

    /// run-create → task-create → dispatch, returning (runId, taskId, dispatchId).
    private func makeDispatched(worker: String = "term_w") async throws -> (run: String, task: String, dispatch: String) {
        let run = await perform("run-create", [
            "objective": .string("t"), "from": .string("term_c")])
        let runID = try XCTUnwrap(run.result?.field("runId")?.stringValue)
        let task = await perform("task-create", [
            "spec": .string("work"), "from": .string("term_c")])
        let taskID = try XCTUnwrap(task.result?.field("taskId")?.stringValue)
        let dispatch = await perform("dispatch", [
            "task": .string(taskID), "to": .string(worker)])
        let dispatchID = try XCTUnwrap(dispatch.result?.field("dispatchId")?.stringValue)
        return (runID, taskID, dispatchID)
    }

    // MARK: - ask / reply

    func testAskBlocksUntilReplyDeliversTheAnswer() async throws {
        let ids = try await makeDispatched()

        let server = host.inMemory
        let asking = Task.detached { () -> RPCResponse in
            await server.perform(RPCRequest(method: "ask", params: .object([
                "from": .string("term_w"),
                "question": .string("Which database?"),
                "options": .string("sqlite,postgres"),
                "timeout-ms": .number(10000),
            ])))
        }

        // The coordinator's long-poll wakes on the question's arrival.
        let woken = await perform("check", [
            "terminal": .string("term_c"), "wait": .bool(true),
            "types": .string("question"), "timeout-ms": .number(10000),
        ])
        XCTAssertTrue(woken.ok, String(describing: woken.error))
        let question = try XCTUnwrap(woken.result?.field("messages")?.arrayValue?.first)
        XCTAssertEqual(question.field("type")?.stringValue, "question")
        let questionID = try XCTUnwrap(question.field("id")?.stringValue)

        let replied = await perform("reply", [
            "id": .string(questionID), "body": .string("sqlite"), "from": .string("term_c")])
        XCTAssertTrue(replied.ok, String(describing: replied.error))
        XCTAssertEqual(replied.result?.field("status")?.stringValue, "answered")

        let answered = await asking.value
        XCTAssertTrue(answered.ok, String(describing: answered.error))
        XCTAssertEqual(answered.result?.field("status")?.stringValue, "answered")
        XCTAssertEqual(answered.result?.field("answer")?.stringValue, "sqlite")
        _ = ids
    }

    func testAskWithoutActiveDispatchIsRejected() async throws {
        _ = await perform("run-create", ["objective": .string("t"), "from": .string("term_c")])
        let response = await perform("ask", [
            "from": .string("term_stranger"), "question": .string("hello?"),
            "timeout-ms": .number(500)])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "dispatch_inactive")
    }

    // MARK: - retry-request idempotency

    func testRetryRequestReplaysWithoutRerunning() async throws {
        let first = await perform("run-create", [
            "objective": .string("idempotent"), "from": .string("term_c"),
            "retry-request": .string("req-1")])
        XCTAssertTrue(first.ok)
        let retried = await perform("run-create", [
            "objective": .string("idempotent"), "from": .string("term_c"),
            "retry-request": .string("req-1")])
        XCTAssertTrue(retried.ok)
        XCTAssertEqual(first.result?.field("runId")?.stringValue,
                       retried.result?.field("runId")?.stringValue)
        let runs = await perform("run-list")
        XCTAssertEqual(runs.result?.field("count")?.numberValue, 1)

        // Same request id with different input is a hard mismatch, not a replay.
        let mismatched = await perform("run-create", [
            "objective": .string("different"), "from": .string("term_c"),
            "retry-request": .string("req-1")])
        XCTAssertFalse(mismatched.ok)
        XCTAssertEqual(mismatched.error?.code, "request_mismatch")
    }

    // MARK: - send guards

    func testLifecycleSendToGroupAddressIsRejected() async throws {
        let ids = try await makeDispatched()
        let response = await perform("send", [
            "from": .string("term_w"), "to": .string("@claude"),
            "subject": .string("done"), "type": .string("worker_done"),
            "task-id": .string(ids.task), "dispatch-id": .string(ids.dispatch),
            "outcome": .string("succeeded")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testWorkerDoneFromWrongTerminalIsRejectedNotSettled() async throws {
        let ids = try await makeDispatched(worker: "term_w")
        let response = await perform("send", [
            "from": .string("term_imposter"),
            "subject": .string("done"), "type": .string("worker_done"),
            "task-id": .string(ids.task), "dispatch-id": .string(ids.dispatch),
            "outcome": .string("succeeded")])
        XCTAssertTrue(response.ok) // stored + converted to a rejection, not an error
        XCTAssertEqual(response.result?.field("lifecycle")?.field("status")?.stringValue, "rejected")
        let tasks = await perform("task-list", ["run": .string(ids.run)])
        XCTAssertEqual(tasks.result?.field("tasks")?.arrayValue?.first?.field("status")?.stringValue,
                       "dispatched")
    }

    // MARK: - worker-mode check

    func testWorkerCheckConsumesDirectMailOnceAndPeekDoesNot() async throws {
        let ids = try await makeDispatched()
        _ = await perform("send", [
            "from": .string("term_c"), "to": .string("term_w"),
            "subject": .string("fyi"), "body": .string("carry on"), "run": .string(ids.run)])

        let peeked = await perform("check", [
            "terminal": .string("term_w"), "peek": .bool(true)])
        XCTAssertEqual(peeked.result?.field("count")?.numberValue, 1)

        let consumed = await perform("check", ["terminal": .string("term_w")])
        XCTAssertEqual(consumed.result?.field("count")?.numberValue, 1)
        XCTAssertEqual(consumed.result?.field("messages")?.arrayValue?.first?
            .field("subject")?.stringValue, "fyi")

        let drained = await perform("check", ["terminal": .string("term_w")])
        XCTAssertEqual(drained.result?.field("count")?.numberValue, 0)
    }

    // MARK: - gates

    func testGateBlocksTaskAndResolutionReachesNextPreamble() async throws {
        let ids = try await makeDispatched()
        let gate = await perform("gate-create", [
            "task": .string(ids.task), "question": .string("Ship to prod?"),
            "options": .string("yes,no")])
        XCTAssertTrue(gate.ok, String(describing: gate.error))
        let gateID = try XCTUnwrap(gate.result?.field("gateId")?.stringValue)
        var tasks = await perform("task-list", ["run": .string(ids.run)])
        XCTAssertEqual(tasks.result?.field("tasks")?.arrayValue?.first?.field("status")?.stringValue,
                       "blocked")

        let resolved = await perform("gate-resolve", [
            "id": .string(gateID), "resolution": .string("yes")])
        XCTAssertTrue(resolved.ok)
        tasks = await perform("task-list", ["run": .string(ids.run)])
        XCTAssertEqual(tasks.result?.field("tasks")?.arrayValue?.first?.field("status")?.stringValue,
                       "ready")

        // The retry dispatch carries the human's answer, not a fresh question.
        let redispatched = await perform("dispatch", [
            "task": .string(ids.task), "to": .string("term_w2"),
            "return-preamble": .bool(true)])
        let preamble = try XCTUnwrap(redispatched.result?.field("preamble")?.stringValue)
        XCTAssertTrue(preamble.contains("RESOLVED DECISION GATES"))
        XCTAssertTrue(preamble.contains("Ship to prod?"))
        XCTAssertTrue(preamble.contains("yes"))
    }

    // MARK: - repo verbs on T4's store

    func testRepoVerbsReadAndWriteTheWorkspaceStore() async throws {
        let repoDir = root.appendingPathComponent("some-folder")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let added = await perform("repo-add", [
            "path": .string(repoDir.path), "display-name": .string("Some Folder")])
        XCTAssertTrue(added.ok, String(describing: added.error))
        let repoID = try XCTUnwrap(added.result?.field("id")?.stringValue)

        let listed = await perform("repo-list")
        XCTAssertEqual(listed.result?.field("count")?.numberValue, 1)

        let shown = await perform("repo-show", ["repo": .string(repoID)])
        XCTAssertEqual(shown.result?.field("displayName")?.stringValue, "Some Folder")

        // Same registry T4's workspace service reads — one store, no sidecar.
        let stored = await MainActor.run { [host] in host!.workspaceService.listRepos() }
        XCTAssertEqual(stored.map(\.id), [repoID])
    }

    // MARK: - reset

    func testResetAllClearsEveryPlane() async throws {
        let ids = try await makeDispatched()
        _ = await perform("send", [
            "from": .string("term_c"), "subject": .string("note"), "run": .string(ids.run)])
        let reset = await perform("reset", ["all": .bool(true)])
        XCTAssertTrue(reset.ok, String(describing: reset.error))
        XCTAssertEqual(reset.result?.field("cleared")?.field("runs")?.numberValue, 1)
        let runs = await perform("run-list")
        XCTAssertEqual(runs.result?.field("count")?.numberValue, 0)
        let tasks = await perform("task-list")
        XCTAssertEqual(tasks.result?.field("count")?.numberValue, 0)
    }
}
