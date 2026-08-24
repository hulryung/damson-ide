import Foundation

/// UI-free row models for the Automations window (docs/REBUILD-PLAN.md T48).
/// Next-fire math is always `AutomationSchedule.nextFire` — this file formats
/// and validates; it does not reimplement trigger matching.

public struct AutomationListRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let triggerSummary: String
    public let nextFire: String
    public let nextFireDate: Date?
    public let targetSummary: String
    public let provider: String
    public let runCount: Int

    public init(id: String, name: String, enabled: Bool, triggerSummary: String,
                nextFire: String, nextFireDate: Date?, targetSummary: String,
                provider: String, runCount: Int) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.triggerSummary = triggerSummary
        self.nextFire = nextFire
        self.nextFireDate = nextFireDate
        self.targetSummary = targetSummary
        self.provider = provider
        self.runCount = runCount
    }
}

public struct AutomationRunRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let outcome: String
    public let scheduledAt: String
    public let startedAt: String
    public let finishedAt: String
    public let message: String?
    public let worktreeId: String?
    public let terminalId: String?

    public init(id: String, outcome: String, scheduledAt: String, startedAt: String,
                finishedAt: String, message: String?, worktreeId: String?,
                terminalId: String?) {
        self.id = id
        self.outcome = outcome
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.message = message
        self.worktreeId = worktreeId
        self.terminalId = terminalId
    }
}

public struct AutomationDraftValidation: Equatable, Sendable {
    public let isValid: Bool
    public let messages: [String]
    public let nextFires: [Date]
    public let nextFireLabels: [String]

    public init(isValid: Bool, messages: [String], nextFires: [Date],
                nextFireLabels: [String]) {
        self.isValid = isValid
        self.messages = messages
        self.nextFires = nextFires
        self.nextFireLabels = nextFireLabels
    }
}

public struct AutomationViewSnapshot: Equatable, Sendable {
    public let rows: [AutomationListRow]
    public static let empty = AutomationViewSnapshot(rows: [])

    public init(rows: [AutomationListRow]) {
        self.rows = rows
    }
}

public enum AutomationProjection {
    public static let weekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    /// Shown under the precheck field. Matches T16 skip semantics: nonzero or
    /// timeout records skipped and does not start an agent.
    public static let precheckSkipExplanation =
        "Exit 0 continues; any other exit or timeout records skipped and does not start an agent."

    public static func triggerSummary(_ automation: Automation) -> String {
        switch automation.trigger {
        case .hourly:
            return "Hourly at :\(minuteField(automation.time))"
        case .daily:
            return "Daily at \(automation.time) UTC"
        case .weekdays:
            return "Weekdays at \(automation.time) UTC"
        case .weekly:
            return "Weekly on \(weekdayName(automation.day)) at \(automation.time) UTC"
        case .cron:
            return "Cron \(automation.time)"
        }
    }

    public static func weekdayName(_ day: Int?) -> String {
        guard let day, weekdayNames.indices.contains(day) else { return "unknown day" }
        return weekdayNames[day]
    }

    public static func targetSummary(_ target: AutomationTarget) -> String {
        switch target {
        case .repo(let selector):
            return "Repo \(selector) · fresh worktree"
        case .workspace(let selector):
            return "Workspace \(selector) · reuse session"
        }
    }

    public static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    public static func relativeFire(_ date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta < 0 { return "overdue" }
        let minutes = Int(delta / 60)
        if minutes < 1 { return "in <1m" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "in \(hours)h" }
        return "in \(hours / 24)d"
    }

    /// List-row next-fire label. Disabled items still show the next slot so
    /// pausing is visible without hiding the schedule.
    public static func formatNextFire(_ date: Date?, now: Date, enabled: Bool) -> String {
        guard let date else { return "invalid schedule" }
        let stamp = "\(relativeFire(date, now: now)) · \(formatTimestamp(date))"
        return enabled ? stamp : "paused · \(formatTimestamp(date))"
    }

    /// Walks `AutomationSchedule.nextFire` `count` times. Empty when the
    /// schedule cannot produce a slot (invalid expression, or none within a year).
    public static func nextFires(for automation: Automation, count: Int,
                                 after date: Date, calendar: Calendar = .utc) -> [Date] {
        var dates: [Date] = []
        var cursor = date
        for _ in 0..<max(0, count) {
            guard let next = try? AutomationSchedule.nextFire(
                for: automation, after: cursor, calendar: calendar) else { break }
            dates.append(next)
            cursor = next
        }
        return dates
    }

    public static func listRow(automation: Automation, runCount: Int, now: Date,
                               calendar: Calendar = .utc) -> AutomationListRow {
        let next = try? AutomationSchedule.nextFire(for: automation, after: now, calendar: calendar)
        return AutomationListRow(
            id: automation.id,
            name: automation.name,
            enabled: automation.enabled,
            triggerSummary: triggerSummary(automation),
            nextFire: formatNextFire(next, now: now, enabled: automation.enabled),
            nextFireDate: next,
            targetSummary: targetSummary(automation.target),
            provider: automation.provider,
            runCount: runCount)
    }

    public static func runRow(_ run: AutomationRun) -> AutomationRunRow {
        AutomationRunRow(
            id: run.id,
            outcome: run.outcome.rawValue,
            scheduledAt: formatTimestamp(run.scheduledAt),
            startedAt: formatTimestamp(run.startedAt),
            finishedAt: formatTimestamp(run.finishedAt),
            message: run.message,
            worktreeId: run.worktreeId,
            terminalId: run.terminalId)
    }

    public static func snapshot(automations: [Automation], runs: [AutomationRun],
                                now: Date, calendar: Calendar = .utc) -> AutomationViewSnapshot {
        let counts = Dictionary(grouping: runs, by: \.automationId).mapValues(\.count)
        let rows = automations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { listRow(automation: $0, runCount: counts[$0.id] ?? 0, now: now, calendar: calendar) }
        return AutomationViewSnapshot(rows: rows)
    }

    public static func validateDraft(
        name: String,
        trigger: AutomationTrigger,
        time: String,
        day: Int?,
        provider: String,
        prompt: String,
        hasTarget: Bool,
        now: Date = Date(),
        calendar: Calendar = .utc
    ) -> AutomationDraftValidation {
        var messages: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Name is required")
        }
        if provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Provider is required")
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Prompt is required")
        }
        if !hasTarget {
            messages.append("Choose a repo (fresh worktree) or an existing workspace")
        }
        let probe = Automation(
            name: name.isEmpty ? "draft" : name,
            trigger: trigger,
            time: time,
            day: day,
            provider: provider.isEmpty ? "shell" : provider,
            prompt: prompt.isEmpty ? "draft" : prompt,
            target: .repo("draft"))
        var scheduleOK = true
        do {
            try AutomationSchedule.validate(probe)
        } catch {
            scheduleOK = false
            messages.append(String(describing: error))
        }
        let fires = scheduleOK ? nextFires(for: probe, count: 3, after: now, calendar: calendar) : []
        return AutomationDraftValidation(
            isValid: messages.isEmpty,
            messages: messages,
            nextFires: fires,
            nextFireLabels: fires.map(formatTimestamp))
    }

    public static func deleteConfirmation(name: String, runCount: Int) -> String {
        let history = runCount == 1 ? "1 run in history" : "\(runCount) runs in history"
        return "Delete “\(name)”? This automation has \(history). This cannot be undone."
    }

    private static func minuteField(_ time: String) -> String {
        let parts = time.split(separator: ":")
        if parts.count == 2 { return String(parts[1]) }
        return time
    }
}
