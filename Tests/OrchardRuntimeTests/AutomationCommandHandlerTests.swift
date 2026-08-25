import XCTest
import OrchardProtocol
@testable import OrchardRuntime

final class AutomationCommandHandlerTests: XCTestCase {
    private func fixture(fire: @escaping AutomationFire = { _ in
        AutomationFireReceipt(worktreeId: "wt", terminalId: "term")
    }) throws -> (AutomationCommandHandler, AutomationService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = AutomationService(
            store: OrchardDataStore(url: root.appendingPathComponent("orchard-data.json")),
            fire: fire)
        return (AutomationCommandHandler(service: service), service, root)
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func call(_ handler: AutomationCommandHandler, _ method: String,
                      _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await handler.handle(RPCRequest(method: method, params: .object(params)))
    }

    func testDueAndFireDueDriveCurrentMatchingSlot() async throws {
        var fired = 0
        let (handler, _, root) = try fixture { _ in
            fired += 1
            return AutomationFireReceipt(worktreeId: "wt-e2e", terminalId: "term-e2e")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let created = await call(handler, "automations-create", [
            "name": .string("e2e-now"),
            "trigger": .string("five-field-cron"),
            "time": .string("* * * * *"),
            "provider": .string("shell"),
            "prompt": .string("orchard-e2e-automation"),
            "repo": .string("repo"),
        ])
        XCTAssertTrue(created.ok, created.error?.message ?? "")
        let id = created.result?.objectValue?["id"]?.stringValue
        XCTAssertEqual(id?.hasPrefix("auto_"), true)

        let through = date("2026-08-25T13:45:45Z")
        let due = await call(handler, "automations-due", [
            "since": .number(0),
            "through": .number(through.timeIntervalSince1970),
        ])
        XCTAssertTrue(due.ok, due.error?.message ?? "")
        let slots = due.result?.objectValue?["due"]?.arrayValue ?? []
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.objectValue?["automation"]?.objectValue?["id"]?.stringValue, id)
        XCTAssertEqual(slots.first?.objectValue?["scheduledAt"]?.numberValue,
                       date("2026-08-25T13:45:00Z").timeIntervalSince1970)

        let firedResponse = await call(handler, "automations-fire-due", [
            "since": .number(0),
            "through": .number(through.timeIntervalSince1970),
        ])
        XCTAssertTrue(firedResponse.ok, firedResponse.error?.message ?? "")
        XCTAssertEqual(fired, 1)
        let runs = firedResponse.result?.objectValue?["runs"]?.arrayValue ?? []
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.objectValue?["outcome"]?.stringValue, "fired")
        XCTAssertEqual(runs.first?.objectValue?["worktreeId"]?.stringValue, "wt-e2e")
        XCTAssertEqual(runs.first?.objectValue?["terminalId"]?.stringValue, "term-e2e")

        let alias = await call(handler, "automations-fireDue", [
            "since": .number(0),
            "through": .number(through.timeIntervalSince1970),
        ])
        XCTAssertTrue(alias.ok, alias.error?.message ?? "")
        XCTAssertEqual(alias.result?.objectValue?["runs"]?.arrayValue?.count, 0)
        XCTAssertEqual(fired, 1)

        let history = await call(handler, "automations-runs", ["id": .string(id ?? "")])
        XCTAssertTrue(history.ok, history.error?.message ?? "")
        let stored = history.result?.objectValue?["runs"]?.arrayValue ?? []
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.objectValue?["worktreeId"]?.stringValue, "wt-e2e")
        XCTAssertEqual(stored.first?.objectValue?["terminalId"]?.stringValue, "term-e2e")
    }

    func testDueRejectsInvalidThrough() async throws {
        let (handler, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let response = await call(handler, "automations-due", ["through": .string("not-a-date")])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "automation_invalid_input")
    }

    // MARK: - T60

    func testOnceCreatesFiresAndAutoDisablesOverRPC() async throws {
        let counter = FireCounter()
        let (handler, _, root) = try fixture { _ in
            counter.increment()
            return AutomationFireReceipt(worktreeId: "wt", terminalId: "term",
                                         runId: "run_x", dispatchId: "ctx_x")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let created = await call(handler, "automations-create", [
            "name": .string("one-shot"),
            "trigger": .string("once"),
            "time": .string("now"),
            "provider": .string("shell"),
            "prompt": .string("printf hi"),
            "repo": .string("repo"),
        ])
        XCTAssertTrue(created.ok, created.error?.message ?? "")
        let id = try XCTUnwrap(created.result?.objectValue?["id"]?.stringValue)
        XCTAssertEqual(created.result?.objectValue?["trigger"]?.stringValue, "once")

        let due = await call(handler, "automations-due", [:])
        XCTAssertEqual(due.result?.objectValue?["due"]?.arrayValue?.count, 1)

        let fired = await call(handler, "automations-fire-due", [:])
        XCTAssertTrue(fired.ok, fired.error?.message ?? "")
        let runs = fired.result?.objectValue?["runs"]?.arrayValue ?? []
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.objectValue?["outcome"]?.stringValue, "fired")
        XCTAssertEqual(runs.first?.objectValue?["dispatchId"]?.stringValue, "ctx_x")
        XCTAssertEqual(runs.first?.objectValue?["orchestrationRunId"]?.stringValue, "run_x")
        XCTAssertEqual(counter.value, 1)

        let shown = await call(handler, "automations-show", ["id": .string(id)])
        XCTAssertEqual(shown.result?.objectValue?["enabled"]?.boolValue, false)
        let dueAfter = await call(handler, "automations-due", [:])
        XCTAssertEqual(dueAfter.result?.objectValue?["due"]?.arrayValue?.count, 0)
        let again = await call(handler, "automations-fire-due", [:])
        XCTAssertEqual(again.result?.objectValue?["runs"]?.arrayValue?.count, 0)
        XCTAssertEqual(counter.value, 1)

        let invalid = await call(handler, "automations-create", [
            "name": .string("bad-once"), "trigger": .string("once"), "time": .string("tomorrow-ish"),
            "provider": .string("shell"), "prompt": .string("true"), "repo": .string("repo"),
        ])
        XCTAssertFalse(invalid.ok)
        XCTAssertEqual(invalid.error?.code, "automation_invalid_input")
    }

    func testShowAndRunMissingIdAreTypedNotFound() async throws {
        let (handler, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let show = await call(handler, "automations-show", ["id": .string("auto_nope")])
        XCTAssertFalse(show.ok)
        XCTAssertEqual(show.error?.code, "automation_not_found")
        let run = await call(handler, "automations-run", ["id": .string("auto_nope")])
        XCTAssertFalse(run.ok)
        XCTAssertEqual(run.error?.code, "automation_not_found")
    }

    func testInvalidTriggerIsTypedInvalidInput() async throws {
        let (handler, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let response = await call(handler, "automations-create", [
            "name": .string("bad"), "trigger": .string("fortnightly"), "time": .string("12:00"),
            "provider": .string("shell"), "prompt": .string("true"), "repo": .string("repo"),
        ])
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "automation_invalid_input")
    }

    func testManualRunOfDisabledAndConsumedOnceIsTypedDisabled() async throws {
        let (handler, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = await call(handler, "automations-create", [
            "name": .string("paused"), "trigger": .string("daily"), "time": .string("12:00"),
            "provider": .string("shell"), "prompt": .string("true"), "repo": .string("repo"),
            "disabled": .bool(true),
        ])
        XCTAssertTrue(created.ok, created.error?.message ?? "")
        let id = try XCTUnwrap(created.result?.objectValue?["id"]?.stringValue)
        let paused = await call(handler, "automations-run", ["id": .string(id)])
        XCTAssertFalse(paused.ok)
        XCTAssertEqual(paused.error?.code, "automation_disabled")

        let once = await call(handler, "automations-create", [
            "name": .string("one-shot-run"), "trigger": .string("once"), "time": .string("now"),
            "provider": .string("shell"), "prompt": .string("true"), "repo": .string("repo"),
        ])
        let onceId = try XCTUnwrap(once.result?.objectValue?["id"]?.stringValue)
        let fired = await call(handler, "automations-run", ["id": .string(onceId)])
        XCTAssertTrue(fired.ok, fired.error?.message ?? "")
        let shown = await call(handler, "automations-show", ["id": .string(onceId)])
        XCTAssertEqual(shown.result?.objectValue?["enabled"]?.boolValue, false)
        let again = await call(handler, "automations-run", ["id": .string(onceId)])
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error?.code, "automation_disabled")
    }

    func testManualRunDuringAFireIsRefusedTyped() async throws {
        let (handler, _, root) = try fixture { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return AutomationFireReceipt(worktreeId: "wt", terminalId: "term")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let created = await call(handler, "automations-create", [
            "name": .string("slow"), "trigger": .string("daily"), "time": .string("12:00"),
            "provider": .string("shell"), "prompt": .string("true"), "repo": .string("repo"),
        ])
        let id = try XCTUnwrap(created.result?.objectValue?["id"]?.stringValue)
        let first = Task { await self.call(handler, "automations-run", ["id": .string(id)]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = await call(handler, "automations-run", ["id": .string(id)])
        XCTAssertFalse(second.ok)
        XCTAssertEqual(second.error?.code, "automation_fire_in_flight")
        let firstResponse = await first.value
        XCTAssertTrue(firstResponse.ok, firstResponse.error?.message ?? "")
        let history = await call(handler, "automations-runs", ["id": .string(id)])
        XCTAssertEqual(history.result?.objectValue?["runs"]?.arrayValue?.count, 1)
    }
}
