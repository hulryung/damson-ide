import XCTest
@testable import OrchardRuntime

final class AutomationScheduleTests: XCTestCase {
    private let calendar = Calendar.utc
    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
    private func automation(_ trigger: AutomationTrigger, _ time: String, day: Int? = nil) -> Automation {
        Automation(name: "test", trigger: trigger, time: time, day: day,
                   provider: "codex", prompt: "go", target: .repo("repo"))
    }

    func testCronParsesStepsRangesAndLists() throws {
        let cron = try CronSchedule("*/15 9-17 * * 1-5")
        XCTAssertTrue(cron.matches(date("2026-08-24T09:30:00Z"), calendar: calendar))
        XCTAssertFalse(cron.matches(date("2026-08-24T09:31:00Z"), calendar: calendar))
        XCTAssertFalse(cron.matches(date("2026-08-23T09:30:00Z"), calendar: calendar))
        XCTAssertThrowsError(try CronSchedule("*/0 * * * *"))
        XCTAssertThrowsError(try CronSchedule("1-70 * * * *"))
    }

    func testNextFireUsesUTCMinuteMath() throws {
        XCTAssertEqual(try AutomationSchedule.nextFire(for: automation(.daily, "09:45"),
            after: date("2026-08-23T09:45:00Z"), calendar: calendar),
            date("2026-08-24T09:45:00Z"))
        XCTAssertEqual(try AutomationSchedule.nextFire(for: automation(.weekly, "12:00", day: 1),
            after: date("2026-08-23T00:00:00Z"), calendar: calendar),
            date("2026-08-24T12:00:00Z"))
    }

    func testDueAfterDowntimeSelectsOnlyLatestMissedSlot() {
        var item = automation(.hourly, "00:15")
        item.createdAt = date("2026-08-23T08:00:00Z")
        let due = AutomationSchedule.due([item], since: date("2026-08-23T08:00:00Z"),
                                         through: date("2026-08-23T12:40:00Z"), calendar: calendar)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.1, date("2026-08-23T12:15:00Z"))
    }

    func testWeekdaysExcludeWeekend() throws {
        let item = automation(.weekdays, "10:00")
        XCTAssertEqual(try AutomationSchedule.nextFire(for: item,
            after: date("2026-08-21T10:01:00Z"), calendar: calendar),
            date("2026-08-24T10:00:00Z"))
    }

    func testDueIncludesCurrentMatchingMinuteWhenCreatedDuringSlot() {
        // Created in the matching minute must still be due now — otherwise the
        // headless harness cannot drive due/fireDue without waiting an hour.
        var item = automation(.hourly, "13:45")
        item.createdAt = date("2026-08-25T13:45:30Z")
        let now = date("2026-08-25T13:45:45Z")
        let due = AutomationSchedule.due([item], since: .distantPast, through: now, calendar: calendar)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.1, date("2026-08-25T13:45:00Z"))
    }

    func testDueCurrentMinuteIsSkippedWhenAlreadyRecorded() {
        var item = automation(.hourly, "13:45")
        item.createdAt = date("2026-08-25T13:45:30Z")
        let now = date("2026-08-25T13:45:45Z")
        let slot = date("2026-08-25T13:45:00Z")
        let due = AutomationSchedule.due([item], since: .distantPast, through: now,
                                         lastRuns: [item.id: slot], calendar: calendar)
        XCTAssertTrue(due.isEmpty)
    }

    func testDueEveryMinuteCronIsDueImmediately() {
        var item = automation(.cron, "* * * * *")
        item.createdAt = date("2026-08-25T13:45:30Z")
        let now = date("2026-08-25T13:45:45Z")
        let due = AutomationSchedule.due([item], since: .distantPast, through: now, calendar: calendar)
        XCTAssertEqual(due.first?.1, date("2026-08-25T13:45:00Z"))
    }

    func testDueSkipsDisabledAutomations() {
        var item = automation(.hourly, "00:15")
        item.createdAt = date("2026-08-23T08:00:00Z")
        item.enabled = false
        let due = AutomationSchedule.due([item], since: date("2026-08-23T08:00:00Z"),
                                         through: date("2026-08-23T12:40:00Z"), calendar: calendar)
        XCTAssertTrue(due.isEmpty)
        item.enabled = true
        let enabled = AutomationSchedule.due([item], since: date("2026-08-23T08:00:00Z"),
                                             through: date("2026-08-23T12:40:00Z"), calendar: calendar)
        XCTAssertEqual(enabled.count, 1)
    }

    // MARK: - once (T60)

    private func once(_ time: String, createdAt: String) -> Automation {
        var item = automation(.once, time)
        item.createdAt = date(createdAt)
        return item
    }

    func testOnceResolvesNowHHmmAndInstants() throws {
        XCTAssertEqual(try AutomationSchedule.onceFireDate(once("now", createdAt: "2026-08-25T10:30:45Z"), calendar: calendar),
                       date("2026-08-25T10:30:00Z"))
        XCTAssertEqual(try AutomationSchedule.onceFireDate(once("2026-08-26T07:05:30Z", createdAt: "2026-08-25T10:30:45Z"), calendar: calendar),
                       date("2026-08-26T07:05:00Z"))
        XCTAssertEqual(try AutomationSchedule.onceFireDate(once("2026-08-26T07:05Z", createdAt: "2026-08-25T10:30:45Z"), calendar: calendar),
                       date("2026-08-26T07:05:00Z"), "hand-typed instants without seconds resolve")
        XCTAssertEqual(try AutomationSchedule.onceFireDate(once("2026-08-26T16:05:00+09:00", createdAt: "2026-08-25T10:30:45Z"), calendar: calendar),
                       date("2026-08-26T07:05:00Z"), "offsets are honoured")
        // HH:mm is the first such minute at or after the creation minute.
        XCTAssertEqual(try AutomationSchedule.onceFireDate(once("10:30", createdAt: "2026-08-25T10:30:45Z"), calendar: calendar),
                       date("2026-08-25T10:30:00Z"))
        XCTAssertEqual(try AutomationSchedule.onceFireDate(once("09:00", createdAt: "2026-08-25T10:30:45Z"), calendar: calendar),
                       date("2026-08-26T09:00:00Z"))
        XCTAssertThrowsError(try AutomationSchedule.validate(once("soon", createdAt: "2026-08-25T10:30:45Z")))
        XCTAssertThrowsError(try AutomationSchedule.validate(once("25:00", createdAt: "2026-08-25T10:30:45Z")))
        XCTAssertNoThrow(try AutomationSchedule.validate(once("now", createdAt: "2026-08-25T10:30:45Z")))
    }

    func testOnceMatchesAndNextFireOnlyBeforeItsSlot() throws {
        let item = once("2026-08-26T07:05:00Z", createdAt: "2026-08-25T10:30:45Z")
        XCTAssertTrue(try AutomationSchedule.matches(item, date("2026-08-26T07:05:20Z"), calendar: calendar))
        XCTAssertFalse(try AutomationSchedule.matches(item, date("2026-08-26T07:06:00Z"), calendar: calendar))
        XCTAssertEqual(try AutomationSchedule.nextFire(for: item, after: date("2026-08-25T12:00:00Z"), calendar: calendar),
                       date("2026-08-26T07:05:00Z"))
        XCTAssertThrowsError(try AutomationSchedule.nextFire(for: item, after: date("2026-08-26T07:05:00Z"), calendar: calendar),
                             "a passed once slot has no next fire")
    }

    func testOnceIsDueFromItsSlotUntilRecordedRegardlessOfSince() {
        let item = once("2026-08-26T07:05:00Z", createdAt: "2026-08-25T10:30:45Z")
        XCTAssertTrue(AutomationSchedule.due([item], since: .distantPast,
                                             through: date("2026-08-26T07:04:59Z"), calendar: calendar).isEmpty)
        let atSlot = AutomationSchedule.due([item], since: date("2026-08-26T07:04:30Z"),
                                            through: date("2026-08-26T07:05:10Z"), calendar: calendar)
        XCTAssertEqual(atSlot.first?.1, date("2026-08-26T07:05:00Z"))
        // Runtime was down for a day: the slot is still due on the first pass back,
        // even though `since` (the scheduler checkpoint) is far past the slot.
        let catchUp = AutomationSchedule.due([item], since: date("2026-08-27T09:00:00Z"),
                                             through: date("2026-08-27T09:00:30Z"), calendar: calendar)
        XCTAssertEqual(catchUp.first?.1, date("2026-08-26T07:05:00Z"))
        // Recorded → never again; re-armed to a new slot → due at that slot.
        XCTAssertTrue(AutomationSchedule.due([item], since: .distantPast, through: date("2026-08-27T09:00:30Z"),
                                             lastRuns: [item.id: date("2026-08-26T07:05:00Z")], calendar: calendar).isEmpty)
        var rearmed = item
        rearmed.time = "2026-08-27T08:00:00Z"
        let again = AutomationSchedule.due([rearmed], since: .distantPast, through: date("2026-08-27T09:00:30Z"),
                                           lastRuns: [item.id: date("2026-08-26T07:05:00Z")], calendar: calendar)
        XCTAssertEqual(again.first?.1, date("2026-08-27T08:00:00Z"))
        var disabled = item
        disabled.enabled = false
        XCTAssertTrue(AutomationSchedule.due([disabled], since: .distantPast,
                                             through: date("2026-08-27T09:00:30Z"), calendar: calendar).isEmpty)
    }
}
