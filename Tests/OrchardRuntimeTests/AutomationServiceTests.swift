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

    /// T60 (dogfood-4 finding 2): two due→fire paths racing on one minute slot —
    /// CLI `fire-due` and the in-process scheduler — must produce exactly one run.
    /// The fire callback is slow, so the second `fireDue` arrives while the first
    /// is still awaiting it; the slot claim (not the persisted row) is the guard.
    func testConcurrentFireDueFiresOneSlotExactlyOnce() async throws {
        let counter = FireCounter()
        let (service, root) = try fixture { _ in
            counter.increment()
            try await Task.sleep(nanoseconds: 300_000_000)
            return AutomationFireReceipt(worktreeId: "wt", terminalId: "term",
                                         runId: "run_1", dispatchId: "ctx_1")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        var item = Automation(name: "race", trigger: .cron, time: "* * * * *", provider: "shell",
                              prompt: "true", target: .repo("repo"))
        item.createdAt = Date()
        _ = try await service.create(item)
        let now = Date()

        async let first = service.fireDue(since: .distantPast, through: now)
        async let second = service.fireDue(since: .distantPast, through: now)
        let (a, b) = await (first, second)

        XCTAssertEqual(counter.value, 1, "the fire callback ran for one slot twice")
        XCTAssertEqual(a.count + b.count, 1, "exactly one run row must come out of the race")
        let history = await service.runs(automationId: item.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.dispatchId, "ctx_1")
        XCTAssertEqual(history.first?.orchestrationRunId, "run_1")
        let inFlight = await service.isFireInFlight(item.id)
        XCTAssertFalse(inFlight, "the claim must be released once the row is persisted")
    }

    func testDueHidesAndManualRunRefusesAnInFlightFire() async throws {
        let (service, root) = try fixture { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return AutomationFireReceipt()
        }
        defer { try? FileManager.default.removeItem(at: root) }
        var item = Automation(name: "busy", trigger: .cron, time: "* * * * *", provider: "shell",
                              prompt: "true", target: .repo("repo"))
        item.createdAt = Date()
        _ = try await service.create(item)
        let now = Date()
        let pending = Task { await service.fireDue(since: .distantPast, through: now) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let inFlight = await service.isFireInFlight(item.id)
        XCTAssertTrue(inFlight)
        let due = await service.due(since: .distantPast, through: now)
        XCTAssertTrue(due.isEmpty, "a claimed slot is not due")
        do {
            _ = try await service.run(id: item.id)
            XCTFail("a manual run during a fire must be refused")
        } catch let error as AutomationScheduleError {
            XCTAssertEqual(error.code, "automation_fire_in_flight")
        }
        let runs = await pending.value
        XCTAssertEqual(runs.count, 1)
        let history = await service.runs(automationId: item.id)
        XCTAssertEqual(history.count, 1)
    }

    /// T60 (dogfood-4 finding 4): `once` fires a single time, then the service
    /// disables the automation in the same write that records the run.
    func testOnceFiresThenAutoDisablesAndIsNeverDueAgain() async throws {
        let counter = FireCounter()
        let (service, root) = try fixture { _ in
            counter.increment()
            return AutomationFireReceipt(worktreeId: "wt", terminalId: "term")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        var item = Automation(name: "one-shot", trigger: .once, time: "now", provider: "shell",
                              prompt: "true", target: .repo("repo"))
        item.createdAt = Date()
        _ = try await service.create(item)
        let now = Date()
        let due = await service.due(since: .distantPast, through: now)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.scheduledAt, AutomationSchedule.minute(of: item.createdAt))

        let runs = await service.fireDue(since: .distantPast, through: now)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.outcome, .fired)
        XCTAssertEqual(runs.first?.message, AutomationService.onceConsumedMessage)
        XCTAssertEqual(counter.value, 1)
        let stored = await service.show(item.id)
        XCTAssertEqual(stored?.enabled, false, "a once automation disables itself after firing")

        // Neither the same pass, a later pass, nor a much later restart pass fires again.
        let again = await service.fireDue(since: .distantPast, through: now.addingTimeInterval(3600))
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(counter.value, 1)
        let later = await service.due(since: now, through: now.addingTimeInterval(86_400))
        XCTAssertTrue(later.isEmpty)

        // Re-arming (re-enable) does not refire the consumed slot either.
        _ = try await service.setEnabled(item.id, enabled: true)
        let rearmed = await service.due(since: .distantPast, through: now.addingTimeInterval(3600))
        XCTAssertTrue(rearmed.isEmpty, "the recorded slot stays consumed")
    }

    func testOnceIsConsumedByAPrecheckSkipToo() async throws {
        let (service, root) = try fixture { _ in XCTFail("must not fire"); return AutomationFireReceipt() }
        defer { try? FileManager.default.removeItem(at: root) }
        var item = Automation(name: "skip-once", trigger: .once, time: "now", provider: "shell",
                              prompt: "true", target: .repo("repo"), precheck: "exit 3")
        item.createdAt = Date()
        _ = try await service.create(item)
        let run = try await service.run(id: item.id)
        XCTAssertEqual(run.outcome, .skipped)
        let stored = await service.show(item.id)
        XCTAssertEqual(stored?.enabled, false)
        do {
            _ = try await service.run(id: item.id)
            XCTFail("a consumed once must not fire again via run --id")
        } catch let error as AutomationScheduleError {
            XCTAssertEqual(error.code, "automation_disabled")
        }
    }

    func testManualRunRefusesADisabledAutomation() async throws {
        let (service, root) = try fixture { _ in XCTFail("must not fire"); return AutomationFireReceipt() }
        defer { try? FileManager.default.removeItem(at: root) }
        let item = Automation(name: "paused", trigger: .daily, time: "12:00", provider: "shell",
                              prompt: "true", target: .repo("repo"))
        _ = try await service.create(item)
        _ = try await service.setEnabled(item.id, enabled: false)
        do {
            _ = try await service.run(id: item.id)
            XCTFail("run --id on a disabled automation must be refused")
        } catch let error as AutomationScheduleError {
            XCTAssertEqual(error.code, "automation_disabled")
        }
        do {
            _ = try await service.run(id: "auto_missing")
            XCTFail("run --id on a missing automation must be refused")
        } catch let error as AutomationScheduleError {
            XCTAssertEqual(error.code, "automation_not_found")
        }
    }

    func testAutomationRunDecodesWithoutDispatchFields() throws {
        let json = Data("""
        {"id":"arun_1","automationId":"auto_1","scheduledAt":0,"startedAt":0,"finishedAt":1,"outcome":"fired"}
        """.utf8)
        let run = try JSONBridge.decoder.decode(AutomationRun.self, from: json)
        XCTAssertNil(run.dispatchId)
        XCTAssertNil(run.orchestrationRunId)
        XCTAssertEqual(run.outcome, .fired)
    }
}

/// Lock-guarded call counter for `@Sendable` fire closures.
final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
