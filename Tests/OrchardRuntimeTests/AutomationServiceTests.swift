import XCTest
@testable import OrchardRuntime

final class AutomationServiceTests: XCTestCase {
    private func fixture(fire: @escaping AutomationFire) throws -> (AutomationService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (AutomationService(store: OrchardDataStore(url: root.appendingPathComponent("orchard-data.json")), fire: fire), root)
    }

    func testPrecheckNonzeroRecordsSkippedWithoutFiring() async throws {
        let (service, root) = try fixture { _ in XCTFail("must not fire"); return AutomationFireReceipt() }
        defer { try? FileManager.default.removeItem(at: root) }
        let item = Automation(name: "skip", trigger: .daily, time: "12:00", provider: "codex",
                              prompt: "go", target: .repo("repo"), precheck: "exit 7")
        _ = try await service.create(item)
        let run = try await service.run(id: item.id)
        XCTAssertEqual(run.outcome, .skipped)
        let runs = await service.runs()
        XCTAssertEqual(runs.count, 1)
    }

    func testSuccessfulRunPersistsReceiptAndCRUD() async throws {
        let (service, root) = try fixture { _ in AutomationFireReceipt(worktreeId: "wt", terminalId: "term") }
        defer { try? FileManager.default.removeItem(at: root) }
        var item = Automation(name: "daily", trigger: .daily, time: "12:00", provider: "codex",
                              prompt: "go", target: .repo("repo"))
        _ = try await service.create(item)
        let run = try await service.run(id: item.id)
        XCTAssertEqual(run.outcome, .fired); XCTAssertEqual(run.worktreeId, "wt"); XCTAssertEqual(run.terminalId, "term")
        item.name = "changed"; _ = try await service.replace(item)
        let changed = await service.show(item.id)
        XCTAssertEqual(changed?.name, "changed")
        let removed = try await service.remove(item.id)
        let remaining = await service.list()
        XCTAssertTrue(removed); XCTAssertTrue(remaining.isEmpty)
    }

    func testLegacyOrchardDataDecodesWithoutAutomationKeys() throws {
        let json = Data("{\"schemaVersion\":1,\"repos\":[]}".utf8)
        let data = try JSONBridge.decoder.decode(OrchardData.self, from: json)
        XCTAssertEqual(data.automations, []); XCTAssertEqual(data.automationRuns, [])
    }

    func testAutomationDecodesWithoutEnabledDefaultsTrue() throws {
        let json = Data("""
        {"id":"auto_1","name":"n","trigger":"daily","time":"12:00","provider":"codex","prompt":"go","target":{"type":"repo","selector":"r"},"precheckTimeoutSeconds":30,"createdAt":0}
        """.utf8)
        let item = try JSONBridge.decoder.decode(Automation.self, from: json)
        XCTAssertTrue(item.enabled)
        XCTAssertEqual(item.name, "n")
    }

    func testAutomationDecodesEnabledFalse() throws {
        let json = Data("""
        {"id":"auto_1","name":"n","trigger":"daily","time":"12:00","provider":"codex","prompt":"go","target":{"type":"repo","selector":"r"},"precheckTimeoutSeconds":30,"enabled":false,"createdAt":0}
        """.utf8)
        let item = try JSONBridge.decoder.decode(Automation.self, from: json)
        XCTAssertFalse(item.enabled)
    }

    func testDueAndFireDueRecordCurrentMatchingSlot() async throws {
        var fired: [String] = []
        let (service, root) = try fixture { automation in
            fired.append(automation.id)
            return AutomationFireReceipt(worktreeId: "wt-live", terminalId: "term-live")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        var item = Automation(name: "now", trigger: .cron, time: "* * * * *", provider: "shell",
                              prompt: "go", target: .repo("repo"))
        item.createdAt = Date()
        _ = try await service.create(item)
        let now = Date()
        let slots = await service.due(since: .distantPast, through: now)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.automation.id, item.id)
        let runs = await service.fireDue(since: .distantPast, through: now)
        XCTAssertEqual(fired, [item.id])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.outcome, .fired)
        XCTAssertEqual(runs.first?.worktreeId, "wt-live")
        XCTAssertEqual(runs.first?.terminalId, "term-live")
        let history = await service.runs(automationId: item.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.worktreeId, "wt-live")
        let again = await service.fireDue(since: .distantPast, through: now)
        XCTAssertTrue(again.isEmpty, "the same minute must not fire twice")
        XCTAssertEqual(fired.count, 1)
    }

    func testSetEnabledTogglesLiveAndPersists() async throws {
        let (service, root) = try fixture { _ in AutomationFireReceipt() }
        defer { try? FileManager.default.removeItem(at: root) }
        let item = Automation(name: "daily", trigger: .daily, time: "12:00", provider: "codex",
                              prompt: "go", target: .repo("repo"))
        _ = try await service.create(item)
        let paused = try await service.setEnabled(item.id, enabled: false)
        XCTAssertFalse(paused.enabled)
        let stored = await service.show(item.id)
        XCTAssertEqual(stored?.enabled, false)
        let resumed = try await service.setEnabled(item.id, enabled: true)
        XCTAssertTrue(resumed.enabled)
    }
}
