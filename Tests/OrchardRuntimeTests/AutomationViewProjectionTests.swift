import XCTest
@testable import OrchardRuntime

final class AutomationViewProjectionTests: XCTestCase {
    private let calendar = Calendar.utc

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func automation(_ trigger: AutomationTrigger, _ time: String, day: Int? = nil,
                            enabled: Bool = true, name: String = "test") -> Automation {
        Automation(name: name, trigger: trigger, time: time, day: day,
                   provider: "codex", prompt: "go", target: .repo("damson-ide"),
                   enabled: enabled)
    }

    func testTriggerSummaries() {
        XCTAssertEqual(AutomationProjection.triggerSummary(automation(.hourly, "00:15")),
                       "Hourly at :15")
        XCTAssertEqual(AutomationProjection.triggerSummary(automation(.daily, "09:00")),
                       "Daily at 09:00 UTC")
        XCTAssertEqual(AutomationProjection.triggerSummary(automation(.weekdays, "09:30")),
                       "Weekdays at 09:30 UTC")
        XCTAssertEqual(AutomationProjection.triggerSummary(automation(.weekly, "12:00", day: 1)),
                       "Weekly on Monday at 12:00 UTC")
        XCTAssertEqual(AutomationProjection.triggerSummary(automation(.cron, "0 9 * * 1-5")),
                       "Cron 0 9 * * 1-5")
        XCTAssertEqual(AutomationProjection.weekdayName(nil), "unknown day")
        XCTAssertEqual(AutomationProjection.weekdayName(7), "unknown day")
    }

    func testTargetSummaries() {
        XCTAssertEqual(AutomationProjection.targetSummary(.repo("damson-ide")),
                       "Repo damson-ide · fresh worktree")
        XCTAssertEqual(AutomationProjection.targetSummary(.workspace("repo::/tmp/ws")),
                       "Workspace repo::/tmp/ws · reuse session")
    }

    func testFormatNextFireEnabledDisabledAndInvalid() {
        let now = date("2026-08-25T10:00:00Z")
        let later = date("2026-08-25T12:00:00Z")
        XCTAssertEqual(AutomationProjection.formatNextFire(later, now: now, enabled: true),
                       "in 2h · 2026-08-25 12:00 UTC")
        XCTAssertEqual(AutomationProjection.formatNextFire(later, now: now, enabled: false),
                       "paused · 2026-08-25 12:00 UTC")
        XCTAssertEqual(AutomationProjection.formatNextFire(nil, now: now, enabled: true),
                       "invalid schedule")
        XCTAssertEqual(AutomationProjection.relativeFire(now.addingTimeInterval(45), now: now), "in <1m")
        XCTAssertEqual(AutomationProjection.relativeFire(now.addingTimeInterval(-60), now: now), "overdue")
        XCTAssertEqual(AutomationProjection.formatTimestamp(later), "2026-08-25 12:00 UTC")
    }

    func testNextFiresDelegatesToScheduleMath() throws {
        let item = automation(.daily, "09:45")
        let after = date("2026-08-23T09:45:00Z")
        let fires = AutomationProjection.nextFires(for: item, count: 3, after: after, calendar: calendar)
        XCTAssertEqual(fires.count, 3)
        XCTAssertEqual(fires[0], try AutomationSchedule.nextFire(for: item, after: after, calendar: calendar))
        XCTAssertEqual(fires[1], try AutomationSchedule.nextFire(for: item, after: fires[0], calendar: calendar))
        XCTAssertEqual(fires[2], try AutomationSchedule.nextFire(for: item, after: fires[1], calendar: calendar))
    }

    func testNextFiresEmptyOnInvalidCron() {
        let item = automation(.cron, "not-a-cron")
        XCTAssertTrue(AutomationProjection.nextFires(
            for: item, count: 3, after: date("2026-08-23T00:00:00Z"), calendar: calendar).isEmpty)
    }

    func testListRowAndSnapshotSortAndCounts() {
        let now = date("2026-08-23T09:00:00Z")
        var zebra = automation(.daily, "09:45", name: "zebra")
        zebra.id = "auto_z"
        var alpha = automation(.hourly, "00:15", name: "alpha")
        alpha.id = "auto_a"
        alpha.enabled = false
        let runs = [
            AutomationRun(automationId: "auto_z", scheduledAt: now, startedAt: now,
                          finishedAt: now, outcome: .fired),
            AutomationRun(automationId: "auto_z", scheduledAt: now, startedAt: now,
                          finishedAt: now, outcome: .skipped, message: "precheck exited 1"),
        ]
        let snapshot = AutomationProjection.snapshot(
            automations: [zebra, alpha], runs: runs, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.rows.map(\.name), ["alpha", "zebra"])
        XCTAssertEqual(snapshot.rows[0].runCount, 0)
        XCTAssertFalse(snapshot.rows[0].enabled)
        XCTAssertTrue(snapshot.rows[0].nextFire.hasPrefix("paused"))
        XCTAssertEqual(snapshot.rows[0].triggerSummary, "Hourly at :15")
        XCTAssertEqual(snapshot.rows[1].runCount, 2)
        XCTAssertEqual(snapshot.rows[1].targetSummary, "Repo damson-ide · fresh worktree")
        XCTAssertEqual(snapshot.rows[1].nextFireDate,
                       try? AutomationSchedule.nextFire(for: zebra, after: now, calendar: calendar))
    }

    func testRunRowProjectsOutcomeTimestampsAndLinks() {
        let started = date("2026-08-25T09:00:00Z")
        let finished = date("2026-08-25T09:01:00Z")
        let run = AutomationRun(
            id: "arun_1", automationId: "auto_1", scheduledAt: started,
            startedAt: started, finishedAt: finished, outcome: .failed,
            message: "agent prompt refused", worktreeId: "repo::/tmp/wt",
            terminalId: "term_abc")
        let row = AutomationProjection.runRow(run)
        XCTAssertEqual(row.outcome, "failed")
        XCTAssertEqual(row.startedAt, "2026-08-25 09:00 UTC")
        XCTAssertEqual(row.finishedAt, "2026-08-25 09:01 UTC")
        XCTAssertEqual(row.message, "agent prompt refused")
        XCTAssertEqual(row.worktreeId, "repo::/tmp/wt")
        XCTAssertEqual(row.terminalId, "term_abc")
    }

    func testValidateDraftMessagesAndNextFirePreview() {
        let now = date("2026-08-23T09:45:00Z")
        let empty = AutomationProjection.validateDraft(
            name: "  ", trigger: .daily, time: "09:45", day: nil,
            provider: "", prompt: "", hasTarget: false, now: now, calendar: calendar)
        XCTAssertFalse(empty.isValid)
        XCTAssertTrue(empty.messages.contains("Name is required"))
        XCTAssertTrue(empty.messages.contains("Provider is required"))
        XCTAssertTrue(empty.messages.contains("Prompt is required"))
        XCTAssertTrue(empty.messages.contains("Choose a repo (fresh worktree) or an existing workspace"))
        XCTAssertEqual(empty.nextFires.count, 3)

        let badCron = AutomationProjection.validateDraft(
            name: "n", trigger: .cron, time: "*/0 * * * *", day: nil,
            provider: "codex", prompt: "go", hasTarget: true, now: now, calendar: calendar)
        XCTAssertFalse(badCron.isValid)
        XCTAssertTrue(badCron.messages.contains { $0.contains("invalid cron") || $0.contains("step") })
        XCTAssertTrue(badCron.nextFires.isEmpty)

        let weekly = AutomationProjection.validateDraft(
            name: "n", trigger: .weekly, time: "12:00", day: nil,
            provider: "codex", prompt: "go", hasTarget: true, now: now, calendar: calendar)
        XCTAssertFalse(weekly.isValid)
        XCTAssertTrue(weekly.messages.contains { $0.contains("weekly requires day") })

        let ok = AutomationProjection.validateDraft(
            name: "n", trigger: .daily, time: "09:45", day: nil,
            provider: "codex", prompt: "go", hasTarget: true, now: now, calendar: calendar)
        XCTAssertTrue(ok.isValid)
        XCTAssertTrue(ok.messages.isEmpty)
        XCTAssertEqual(ok.nextFireLabels.first, "2026-08-24 09:45 UTC")
    }

    func testDeleteConfirmationNamesHistoryCount() {
        XCTAssertEqual(
            AutomationProjection.deleteConfirmation(name: "Nightly", runCount: 0),
            "Delete “Nightly”? This automation has 0 runs in history. This cannot be undone.")
        XCTAssertEqual(
            AutomationProjection.deleteConfirmation(name: "Nightly", runCount: 1),
            "Delete “Nightly”? This automation has 1 run in history. This cannot be undone.")
    }

    func testPrecheckSkipExplanationIsOneLine() {
        XCTAssertFalse(AutomationProjection.precheckSkipExplanation.contains("\n"))
        XCTAssertTrue(AutomationProjection.precheckSkipExplanation.lowercased().contains("skipped"))
    }

    // MARK: - once (T60)

    func testOnceSummaryAndListLabels() {
        var item = automation(.once, "2026-08-26T07:05:00Z")
        item.createdAt = date("2026-08-25T10:00:00Z")
        XCTAssertEqual(AutomationProjection.triggerSummary(item), "Once at 2026-08-26 07:05 UTC")
        XCTAssertEqual(AutomationProjection.triggerSummary(automation(.once, "garbage")), "Once at garbage")

        let before = AutomationProjection.listRow(automation: item, runCount: 0,
                                                  now: date("2026-08-26T07:00:00Z"), calendar: calendar)
        XCTAssertEqual(before.nextFire, "in 5m · 2026-08-26 07:05 UTC")
        XCTAssertEqual(before.nextFireDate, date("2026-08-26T07:05:00Z"))

        let passedUnfired = AutomationProjection.listRow(automation: item, runCount: 0,
                                                         now: date("2026-08-26T07:06:00Z"), calendar: calendar)
        XCTAssertEqual(passedUnfired.nextFire, "due now")
        XCTAssertNil(passedUnfired.nextFireDate)

        var consumed = item
        consumed.enabled = false
        let fired = AutomationProjection.listRow(automation: consumed, runCount: 1,
                                                 now: date("2026-08-26T07:06:00Z"), calendar: calendar)
        XCTAssertEqual(fired.nextFire, "fired · once")
        let paused = AutomationProjection.listRow(automation: consumed, runCount: 0,
                                                  now: date("2026-08-26T07:06:00Z"), calendar: calendar)
        XCTAssertEqual(paused.nextFire, "paused · once")

        let draft = AutomationProjection.validateDraft(
            name: "n", trigger: .once, time: "2026-08-26T07:05:00Z", day: nil,
            provider: "shell", prompt: "true", hasTarget: true,
            now: date("2026-08-26T07:00:00Z"), calendar: calendar)
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.nextFireLabels, ["2026-08-26 07:05 UTC"])
    }
}
