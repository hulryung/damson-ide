import Foundation

public enum AutomationScheduleError: Error, CustomStringConvertible {
    case invalid(String)
    /// Show / run / edit of an id that is not in the store.
    case notFound(String)
    /// Manual `run --id` of a disabled automation (including a consumed `once`).
    case disabled(id: String)
    /// T60: a scheduled or manual fire for this automation has not finished yet.
    /// The slot is claimed in-actor before the fire callback runs, so a second
    /// caller (CLI `fire-due` racing the in-process scheduler, or `run --id`
    /// during a fire) is refused instead of starting a second worker.
    case fireInFlight(automationId: String)
    public var description: String {
        switch self {
        case .invalid(let s): return s
        case .notFound(let s): return s
        case .disabled(let id): return "automation \(id) is disabled"
        case .fireInFlight(let id): return "a fire for automation \(id) is already in flight"
        }
    }
    /// Stable RPC error code for the CLI face.
    public var code: String {
        switch self {
        case .invalid: return "automation_invalid_input"
        case .notFound: return "automation_not_found"
        case .disabled: return "automation_disabled"
        case .fireInFlight: return "automation_fire_in_flight"
        }
    }
}

public struct CronSchedule: Equatable, Sendable {
    let minutes, hours, days, months, weekdays: Set<Int>
    public init(_ expression: String) throws {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw AutomationScheduleError.invalid("cron requires five fields") }
        minutes = try Self.parse(fields[0], 0...59); hours = try Self.parse(fields[1], 0...23)
        days = try Self.parse(fields[2], 1...31); months = try Self.parse(fields[3], 1...12)
        weekdays = try Self.parse(fields[4], 0...6)
    }
    static func parse(_ field: String, _ allowed: ClosedRange<Int>) throws -> Set<Int> {
        var result = Set<Int>()
        for partSub in field.split(separator: ",") {
            let pair = partSub.split(separator: "/", omittingEmptySubsequences: false)
            guard pair.count <= 2, let step = pair.count == 2 ? Int(pair[1]) : 1, step > 0 else {
                throw AutomationScheduleError.invalid("invalid cron step: \(partSub)")
            }
            let base = String(pair[0]); let range: ClosedRange<Int>
            if base == "*" { range = allowed }
            else if base.contains("-") {
                let ends = base.split(separator: "-"); guard ends.count == 2,
                    let low = Int(ends[0]), let high = Int(ends[1]), allowed.contains(low),
                    allowed.contains(high), low <= high else { throw AutomationScheduleError.invalid("invalid cron range: \(base)") }
                range = low...high
            } else if let value = Int(base), allowed.contains(value) { range = value...value }
            else { throw AutomationScheduleError.invalid("invalid cron field: \(base)") }
            for value in range where (value - range.lowerBound) % step == 0 { result.insert(value) }
        }
        guard !result.isEmpty else { throw AutomationScheduleError.invalid("empty cron field") }
        return result
    }
    public func matches(_ date: Date, calendar: Calendar = .utc) -> Bool {
        let c = calendar.dateComponents([.minute,.hour,.day,.month,.weekday], from: date)
        return minutes.contains(c.minute!) && hours.contains(c.hour!) && days.contains(c.day!)
            && months.contains(c.month!) && weekdays.contains((c.weekday! - 1) % 7)
    }
}

extension Calendar {
    public static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
}

public enum AutomationSchedule {
    /// The single slot a `once` automation fires at, floored to the minute:
    /// `now` is the creation minute, `HH:mm` the first such UTC minute at or after
    /// the creation minute (today or tomorrow), anything else an ISO-8601 instant.
    public static func onceFireDate(_ automation: Automation, calendar: Calendar = .utc) throws -> Date {
        guard automation.trigger == .once else {
            throw AutomationScheduleError.invalid("not a once schedule")
        }
        let raw = automation.time.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let creation = minute(of: automation.createdAt, calendar: calendar) else {
            throw AutomationScheduleError.invalid("once schedule has no creation minute")
        }
        if raw.lowercased() == "now" { return creation }
        if let instant = parseInstant(raw), let slot = minute(of: instant, calendar: calendar) {
            return slot
        }
        let values = raw.split(separator: ":").compactMap { Int($0) }
        if values.count == 2, (0...23).contains(values[0]), (0...59).contains(values[1]) {
            var candidate = creation
            for _ in 0..<(24 * 60) {
                let c = calendar.dateComponents([.hour, .minute], from: candidate)
                if c.hour == values[0] && c.minute == values[1] { return candidate }
                candidate.addTimeInterval(60)
            }
        }
        throw AutomationScheduleError.invalid("once requires an ISO-8601 instant, HH:mm, or now")
    }

    static func parseInstant(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        // `2026-08-25T10:30Z` (no seconds) is a common hand-typed form.
        let padded = text.replacingOccurrences(
            of: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(Z|[+-]\d{2}:\d{2})$"#,
            with: "$1:00$2", options: .regularExpression)
        iso.formatOptions = [.withInternetDateTime]
        return padded == text ? nil : iso.date(from: padded)
    }

    public static func validate(_ automation: Automation) throws {
        if automation.trigger == .once { _ = try onceFireDate(automation); return }
        if automation.trigger == .cron { _ = try CronSchedule(automation.time); return }
        let values = automation.time.split(separator: ":").compactMap { Int($0) }
        guard values.count == 2, (0...23).contains(values[0]), (0...59).contains(values[1]) else {
            throw AutomationScheduleError.invalid("time must be HH:mm")
        }
        if automation.trigger == .weekly, !(0...6).contains(automation.day ?? -1) {
            throw AutomationScheduleError.invalid("weekly requires day 0...6")
        }
    }
    public static func matches(_ automation: Automation, _ date: Date, calendar: Calendar = .utc) throws -> Bool {
        try validate(automation)
        if automation.trigger == .once {
            return try onceFireDate(automation, calendar: calendar) == minute(of: date, calendar: calendar)
        }
        if automation.trigger == .cron { return try CronSchedule(automation.time).matches(date, calendar: calendar) }
        let values = automation.time.split(separator: ":").map { Int($0)! }
        let c = calendar.dateComponents([.minute,.hour,.weekday], from: date)
        if c.minute != values[1] { return false }
        switch automation.trigger {
        case .hourly: return true
        case .daily: return c.hour == values[0]
        case .weekdays: return c.hour == values[0] && (2...6).contains(c.weekday!)
        case .weekly: return c.hour == values[0] && (c.weekday! - 1) == automation.day
        case .cron, .once: return false
        }
    }
    public static func nextFire(for automation: Automation, after date: Date, calendar: Calendar = .utc) throws -> Date {
        if automation.trigger == .once {
            let slot = try onceFireDate(automation, calendar: calendar)
            guard slot > date else { throw AutomationScheduleError.invalid("once schedule already passed") }
            return slot
        }
        var candidate = calendar.date(bySetting: .second, value: 0, of: date)!.addingTimeInterval(60)
        let limit = candidate.addingTimeInterval(366 * 24 * 3600)
        while candidate <= limit { if try matches(automation, candidate, calendar: calendar) { return candidate }; candidate.addTimeInterval(60) }
        throw AutomationScheduleError.invalid("no fire time within one year")
    }
    /// At most one slot per automation, even if several were missed while offline.
    ///
    /// The current UTC minute is also a candidate when it matches and has not
    /// already been recorded. That is what makes an automation whose trigger
    /// matches *now* immediately `due` (create hourly at this minute, or
    /// `* * * * *`, then `fireDue`) instead of waiting for the next occurrence
    /// after `createdAt`. `since` / `createdAt` still bound the historical walk
    /// so a restart only catches the latest missed slot.
    ///
    /// A `once` automation ignores `since`: its slot is due from the moment it has
    /// passed until a run is recorded for it (a runtime that was down at the slot
    /// fires it on the first pass after coming back), and never again after that.
    /// Re-arming (edit `time`, re-enable) makes the new slot due once more.
    public static func due(_ automations: [Automation], since: Date, through now: Date,
                           lastRuns: [String: Date] = [:], calendar: Calendar = .utc) -> [(Automation, Date)] {
        automations.compactMap { automation in
            guard automation.enabled else { return nil }
            let last = lastRuns[automation.id]
            if automation.trigger == .once {
                guard let slot = try? onceFireDate(automation, calendar: calendar),
                      slot <= now, last != slot else { return nil }
                return (automation, slot)
            }
            let lower = max(since, last ?? automation.createdAt)
            var latest: Date?
            if let slot = try? nextFire(for: automation, after: lower, calendar: calendar), slot <= now {
                latest = slot
                while let next = try? nextFire(for: automation, after: latest!, calendar: calendar), next <= now {
                    latest = next
                }
            }
            if let current = minute(of: now, calendar: calendar),
               current <= now,
               (try? matches(automation, current, calendar: calendar)) == true,
               last.map({ minute(of: $0, calendar: calendar) != current }) ?? true {
                if latest == nil || current > latest! { latest = current }
            }
            return latest.map { (automation, $0) }
        }
    }

    /// Floor to the UTC (or `calendar`) minute. Used so "due immediately" is the
    /// matching clock minute, not `now` with leftover seconds.
    public static func minute(of date: Date, calendar: Calendar = .utc) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.second = 0
        components.nanosecond = 0
        return calendar.date(from: components)
    }
}
