import Foundation
import OrchardProtocol

public struct AutomationFireReceipt: Sendable {
    public var worktreeId: String?
    public var terminalId: String?
    public init(worktreeId: String? = nil, terminalId: String? = nil) {
        self.worktreeId = worktreeId; self.terminalId = terminalId
    }
}

public typealias AutomationFire = @Sendable (Automation) async throws -> AutomationFireReceipt

public actor AutomationService {
    public static let historyLimit = 500
    private let store: OrchardDataStore
    private let fire: AutomationFire

    public init(store: OrchardDataStore, fire: @escaping AutomationFire) {
        self.store = store; self.fire = fire
    }

    public func list() -> [Automation] { store.load().automations.sorted { $0.name < $1.name } }
    public func show(_ id: String) -> Automation? { store.load().automations.first { $0.id == id || $0.name == id } }
    public func runs(automationId: String? = nil) -> [AutomationRun] {
        store.load().automationRuns.filter { automationId == nil || $0.automationId == automationId! }
            .sorted { $0.startedAt > $1.startedAt }
    }
    @discardableResult public func create(_ automation: Automation) throws -> Automation {
        try AutomationSchedule.validate(automation)
        guard !automation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !automation.provider.isEmpty, !automation.prompt.isEmpty else {
            throw AutomationScheduleError.invalid("name, provider, and prompt are required")
        }
        guard !store.load().automations.contains(where: {
            $0.id == automation.id || $0.name.caseInsensitiveCompare(automation.name) == .orderedSame
        }) else { throw AutomationScheduleError.invalid("automation id or name already exists") }
        try store.modify { data in
            data.automations.append(automation)
        }
        return automation
    }
    @discardableResult public func replace(_ automation: Automation) throws -> Automation {
        try AutomationSchedule.validate(automation)
        var found = false
        try store.modify { data in if let i = data.automations.firstIndex(where: { $0.id == automation.id }) { data.automations[i] = automation; found = true } }
        if !found { throw AutomationScheduleError.invalid("automation not found") }
        return automation
    }
    public func remove(_ id: String) throws -> Bool {
        var removed = false
        try store.modify { data in let before = data.automations.count; data.automations.removeAll { $0.id == id || $0.name == id }; removed = data.automations.count != before }
        return removed
    }

    @discardableResult public func run(_ automation: Automation, scheduledAt: Date = Date()) async -> AutomationRun {
        let started = Date()
        if let command = automation.precheck, !command.isEmpty {
            let check = await Self.precheck(command, timeout: automation.precheckTimeoutSeconds)
            guard check.exitCode == 0 else {
                let run = AutomationRun(automationId: automation.id, scheduledAt: scheduledAt,
                    startedAt: started, finishedAt: Date(), outcome: .skipped,
                    message: check.timedOut ? "precheck timed out" : "precheck exited \(check.exitCode)")
                persist(run); return run
            }
        }
        do {
            let receipt = try await fire(automation)
            let run = AutomationRun(automationId: automation.id, scheduledAt: scheduledAt,
                startedAt: started, finishedAt: Date(), outcome: .fired,
                worktreeId: receipt.worktreeId, terminalId: receipt.terminalId)
            persist(run); return run
        } catch {
            let run = AutomationRun(automationId: automation.id, scheduledAt: scheduledAt,
                startedAt: started, finishedAt: Date(), outcome: .failed,
                message: String(describing: error))
            persist(run); return run
        }
    }

    public func run(id: String) async throws -> AutomationRun {
        guard let automation = show(id) else { throw AutomationScheduleError.invalid("automation not found") }
        return await run(automation)
    }

    public func fireDue(since: Date, through now: Date = Date()) async {
        let data = store.load()
        let latest = Dictionary(grouping: data.automationRuns, by: \.automationId)
            .compactMapValues { $0.map(\.scheduledAt).max() }
        for (automation, slot) in AutomationSchedule.due(data.automations, since: since, through: now, lastRuns: latest) {
            _ = await run(automation, scheduledAt: slot)
        }
    }

    private func persist(_ run: AutomationRun) {
        try? store.modify { data in
            data.automationRuns.append(run)
            if data.automationRuns.count > Self.historyLimit {
                data.automationRuns.removeFirst(data.automationRuns.count - Self.historyLimit)
            }
        }
    }

    private static func precheck(_ command: String, timeout: Int) async -> (exitCode: Int32, timedOut: Bool) {
        await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]; process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return (-1, false) }
            let deadline = Date().addingTimeInterval(TimeInterval(max(1, min(timeout, 300))))
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate(); process.waitUntilExit(); return (process.terminationStatus, true) }
            return (process.terminationStatus, false)
        }.value
    }
}

public final class AutomationScheduler: @unchecked Sendable {
    private let service: AutomationService
    private var task: Task<Void, Never>?
    public init(service: AutomationService) { self.service = service }
    public func start() {
        guard task == nil else { return }
        task = Task { [service] in
            // The first pass starts at each automation's persisted creation/latest-run
            // boundary, so a runtime restart catches one (latest) missed slot.
            var checkpoint = Date.distantPast
            while !Task.isCancelled {
                let now = Date(); await service.fireDue(since: checkpoint, through: now); checkpoint = now
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
