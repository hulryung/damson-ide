import Foundation

public enum AutomationTrigger: String, Codable, CaseIterable, Sendable {
    case hourly, daily, weekdays, weekly
    case cron = "five-field-cron"
}

public enum AutomationTarget: Codable, Equatable, Sendable {
    case repo(String)
    case workspace(String)

    private enum CodingKeys: String, CodingKey { case type, selector }
    private enum Kind: String, Codable { case repo, workspace }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let selector = try c.decode(String.self, forKey: .selector)
        self = try c.decode(Kind.self, forKey: .type) == .repo ? .repo(selector) : .workspace(selector)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repo(let value): try c.encode(Kind.repo, forKey: .type); try c.encode(value, forKey: .selector)
        case .workspace(let value): try c.encode(Kind.workspace, forKey: .type); try c.encode(value, forKey: .selector)
        }
    }
}

public struct Automation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var trigger: AutomationTrigger
    /// HH:mm for built-ins, five fields for cron.
    public var time: String
    /// Sunday = 0, only meaningful for weekly.
    public var day: Int?
    public var provider: String
    public var prompt: String
    public var target: AutomationTarget
    public var precheck: String?
    public var precheckTimeoutSeconds: Int
    public var createdAt: Date

    public init(id: String = "auto_" + UUID().uuidString.lowercased(), name: String,
                trigger: AutomationTrigger, time: String, day: Int? = nil,
                provider: String, prompt: String, target: AutomationTarget,
                precheck: String? = nil, precheckTimeoutSeconds: Int = 30,
                createdAt: Date = Date()) {
        self.id = id; self.name = name; self.trigger = trigger; self.time = time
        self.day = day; self.provider = provider; self.prompt = prompt; self.target = target
        self.precheck = precheck; self.precheckTimeoutSeconds = max(1, min(precheckTimeoutSeconds, 300))
        self.createdAt = createdAt
    }
}

public enum AutomationRunOutcome: String, Codable, Sendable { case fired, skipped, failed }

public struct AutomationRun: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var automationId: String
    public var scheduledAt: Date
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: AutomationRunOutcome
    public var message: String?
    public var worktreeId: String?
    public var terminalId: String?
    public init(id: String = "arun_" + UUID().uuidString.lowercased(), automationId: String,
                scheduledAt: Date, startedAt: Date, finishedAt: Date,
                outcome: AutomationRunOutcome, message: String? = nil,
                worktreeId: String? = nil, terminalId: String? = nil) {
        self.id = id; self.automationId = automationId; self.scheduledAt = scheduledAt
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.outcome = outcome
        self.message = message; self.worktreeId = worktreeId; self.terminalId = terminalId
    }
}
