import Foundation
import OrchardProtocol

public struct AutomationCommandHandler: CommandHandler {
    public let verbs = ["automations-list", "automations-show", "automations-create",
                        "automations-edit", "automations-remove", "automations-run", "automations-runs",
                        "automations-due", "automations-fire-due", "automations-fireDue"]
    private let service: AutomationService
    public init(service: AutomationService) { self.service = service }
    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do { return .success(id: request.id, result: try await route(request)) }
        catch let error as AutomationScheduleError {
            return .failure(id: request.id, error: RPCError(code: error.code, message: error.description))
        }
        catch { return .failure(id: request.id, error: RPCError(code: "automation_error", message: String(describing: error))) }
    }
    private func route(_ request: RPCRequest) async throws -> JSONValue {
        let p = request.params?.objectValue ?? [:]
        switch request.method {
        case "automations-list": return try JSONBridge.value(["automations": await service.list()])
        case "automations-show": return try JSONBridge.value(try required(await service.show(try identifier(p))))
        case "automations-create": return try JSONBridge.value(await service.create(try automation(p)))
        case "automations-edit":
            let old = try required(await service.show(try identifier(p)))
            return try JSONBridge.value(await service.replace(try automation(p, existing: old)))
        case "automations-remove": return .object(["removed": .bool(try await service.remove(try identifier(p)))])
        case "automations-run": return try JSONBridge.value(try await service.run(id: try identifier(p)))
        case "automations-runs": return try JSONBridge.value(["runs": await service.runs(automationId: p["id"]?.stringValue)])
        case "automations-due":
            let window = try dueWindow(p)
            let slots = await service.due(since: window.since, through: window.through)
            return try JSONBridge.value(["due": slots.map { AutomationDueSlot(automation: $0.automation, scheduledAt: $0.scheduledAt) }])
        case "automations-fire-due", "automations-fireDue":
            let window = try dueWindow(p)
            let runs = await service.fireDue(since: window.since, through: window.through)
            return try JSONBridge.value(["runs": runs])
        default: throw AutomationScheduleError.invalid("unknown automation command")
        }
    }
    /// `since` / `through` are unix seconds. Absent `since` is distantPast (same
    /// first-pass window the in-process scheduler uses); absent `through` is now.
    private func dueWindow(_ p: [String: JSONValue]) throws -> (since: Date, through: Date) {
        (since: try dateParam(p, "since", default: .distantPast),
         through: try dateParam(p, "through", default: Date()))
    }

    private func dateParam(_ p: [String: JSONValue], _ key: String, default fallback: Date) throws -> Date {
        guard let value = p[key] else { return fallback }
        if let number = value.numberValue { return Date(timeIntervalSince1970: number) }
        if let text = value.stringValue {
            if let number = Double(text) { return Date(timeIntervalSince1970: number) }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }
        }
        throw AutomationScheduleError.invalid("\(key) must be unix seconds or ISO-8601")
    }

    private func identifier(_ p: [String: JSONValue]) throws -> String {
        guard let id = p["id"]?.stringValue ?? p["name"]?.stringValue else { throw AutomationScheduleError.invalid("--id is required") }; return id
    }
    private func required(_ value: Automation?) throws -> Automation {
        guard let value else { throw AutomationScheduleError.invalid("automation not found") }; return value
    }
    private func automation(_ p: [String: JSONValue], existing: Automation? = nil) throws -> Automation {
        func string(_ key: String, _ fallback: String? = nil) throws -> String {
            guard let value = p[key]?.stringValue ?? fallback else { throw AutomationScheduleError.invalid("--\(key) is required") }; return value
        }
        let triggerRaw = try string("trigger", existing?.trigger.rawValue)
        guard let trigger = AutomationTrigger(rawValue: triggerRaw) else { throw AutomationScheduleError.invalid("invalid trigger") }
        let target: AutomationTarget
        if p["repo"] != nil && p["workspace"] != nil {
            throw AutomationScheduleError.invalid("pass only one of --repo or --workspace")
        } else if let repo = p["repo"]?.stringValue { target = .repo(repo) }
        else if let workspace = p["workspace"]?.stringValue { target = .workspace(workspace) }
        else if let existing { target = existing.target }
        else { throw AutomationScheduleError.invalid("exactly one of --repo or --workspace is required") }
        return Automation(id: existing?.id ?? "auto_" + UUID().uuidString.lowercased(),
            name: try string("name", existing?.name), trigger: trigger,
            time: try string("time", existing?.time), day: p["day"]?.intValue ?? existing?.day,
            provider: try string("provider", existing?.provider), prompt: try string("prompt", existing?.prompt),
            target: target, precheck: p["precheck"]?.stringValue ?? existing?.precheck,
            precheckTimeoutSeconds: p["timeout"]?.intValue ?? existing?.precheckTimeoutSeconds ?? 30,
            enabled: try enabledFlag(p, existing: existing?.enabled),
            createdAt: existing?.createdAt ?? Date())
    }
    private func enabledFlag(_ p: [String: JSONValue], existing: Bool?) throws -> Bool {
        let on = p["enabled"]?.boolValue == true
        let off = p["disabled"]?.boolValue == true
        if on && off { throw AutomationScheduleError.invalid("use either --enabled or --disabled") }
        if on { return true }
        if off { return false }
        return existing ?? true
    }
}
