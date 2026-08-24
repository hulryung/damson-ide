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
}
