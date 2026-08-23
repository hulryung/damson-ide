import Foundation

public enum AutomationScheduleError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let s): return s } }
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
    public static func validate(_ automation: Automation) throws {
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
        if automation.trigger == .cron { return try CronSchedule(automation.time).matches(date, calendar: calendar) }
        let values = automation.time.split(separator: ":").map { Int($0)! }
        let c = calendar.dateComponents([.minute,.hour,.weekday], from: date)
        if c.minute != values[1] { return false }
        switch automation.trigger {
        case .hourly: return true
        case .daily: return c.hour == values[0]
        case .weekdays: return c.hour == values[0] && (2...6).contains(c.weekday!)
        case .weekly: return c.hour == values[0] && (c.weekday! - 1) == automation.day
        case .cron: return false
        }
    }
    public static func nextFire(for automation: Automation, after date: Date, calendar: Calendar = .utc) throws -> Date {
        var candidate = calendar.date(bySetting: .second, value: 0, of: date)!.addingTimeInterval(60)
        let limit = candidate.addingTimeInterval(366 * 24 * 3600)
        while candidate <= limit { if try matches(automation, candidate, calendar: calendar) { return candidate }; candidate.addTimeInterval(60) }
        throw AutomationScheduleError.invalid("no fire time within one year")
    }
    /// At most one slot per automation, even if several were missed while offline.
    public static func due(_ automations: [Automation], since: Date, through now: Date,
                           lastRuns: [String: Date] = [:], calendar: Calendar = .utc) -> [(Automation, Date)] {
        automations.compactMap { automation in
            let lower = max(since, lastRuns[automation.id] ?? automation.createdAt)
            guard let slot = try? nextFire(for: automation, after: lower, calendar: calendar), slot <= now else { return nil }
            var latest = slot
            while let next = try? nextFire(for: automation, after: latest, calendar: calendar), next <= now { latest = next }
            return (automation, latest)
        }
    }
}
