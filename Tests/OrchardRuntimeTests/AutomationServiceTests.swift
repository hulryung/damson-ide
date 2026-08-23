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
}
