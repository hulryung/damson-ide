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
        XCTAssertEqual(response.error?.code, "automation_error")
    }
}
