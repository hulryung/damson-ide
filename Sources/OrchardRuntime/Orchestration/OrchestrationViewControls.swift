import Foundation
import OrchardOrchestration
import OrchardProtocol

/// UI-free enablement, confirm copy, and audit formatting for the in-app
/// orchestration view (docs/REBUILD-PLAN.md T47). The view never invents
/// lifecycle outcomes — it only decides which verbs to offer, then records
/// whatever the store/verb path returned.
public struct OrchestrationViewEnablement: Equatable, Sendable {
    public let release: Bool
    public let retain: Bool
    public let stop: Bool

    public init(release: Bool, retain: Bool, stop: Bool) {
        self.release = release
        self.retain = retain
        self.stop = stop
    }
}

public struct OrchestrationViewMutationResult: Equatable, Sendable {
    public let timestamp: Date
    public let action: String
    public let target: String
    public let outcome: String
    public let reason: String?
    public let message: String?

    public init(timestamp: Date = Date(), action: String, target: String,
                outcome: String, reason: String? = nil, message: String? = nil) {
        self.timestamp = timestamp
        self.action = action
        self.target = target
        self.outcome = outcome
        self.reason = reason
        self.message = message
    }

    /// Typed refusal the view must render inline — never a silent no-op.
    /// `retained` (except an explicit user retain) and RPC errors always qualify.
    public var isRefusal: Bool {
        switch outcome {
        case "error", "release_unknown": return true
        case "retained": return reason != "user_requested"
        default: return false
        }
    }

    public var displayReason: String? {
        if let reason, !reason.isEmpty { return reason }
        if isRefusal { return outcome }
        return nil
    }
}

/// Enablement rules, confirm wording, receipt parsing, and audit lines.
public enum OrchestrationViewControls {
    public static let workerRelease = "worker-release"
    public static let workerRetain = "worker-retain"
    public static let workerStop = "worker-stop"
    public static let gateResolve = "gate-resolve"

    public static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Settled / enablement

    /// A supervised worker is settled when `WorkerDispatchState.isSettled`.
    /// An unsupervised (`dispatch --inject`) assignment is settled when the
    /// dispatch row itself is completed/failed/circuit_broken.
    public static func isSettled(dispatchStatus: String, workerState: String) -> Bool {
        if workerState == "unsupervised" {
            switch dispatchStatus {
            case DispatchStatus.completed.rawValue,
                 DispatchStatus.failed.rawValue,
                 DispatchStatus.circuitBroken.rawValue:
                return true
            default:
                return false
            }
        }
        return WorkerDispatchState(rawValue: workerState)?.isSettled ?? false
    }

    /// Release: settled only. Stop: never offered once settled. Retain: a
    /// recorded terminal that is not already released.
    public static func enablement(
        dispatchStatus: String,
        workerState: String,
        terminalState: String?,
        agentHandle: String?
    ) -> OrchestrationViewEnablement {
        let settled = isSettled(dispatchStatus: dispatchStatus, workerState: workerState)
        let released = terminalState == WorkerTerminalListState.released.rawValue
        let hasTerminal = (agentHandle?.isEmpty == false) || terminalState != nil
        return OrchestrationViewEnablement(
            release: settled,
            retain: hasTerminal && !released,
            stop: !settled)
    }

    // MARK: - Confirm copy

    /// Title names the exact terminal that will close.
    public static func releaseConfirmTitle(terminalHandle: String?) -> String {
        if let handle = nonempty(terminalHandle) {
            return "Release terminal \(handle)?"
        }
        return "Release this dispatch?"
    }

    public static func releaseConfirmBody(terminalHandle: String?) -> String {
        if let handle = nonempty(terminalHandle) {
            return "This archives inspectable output, then closes terminal \(handle)."
        }
        return "This archives inspectable output. No agent terminal is recorded for this dispatch."
    }

    /// Title names the task; body warns the dispatch will be failed.
    public static func stopConfirmTitle(taskTitle: String) -> String {
        "Stop “\(taskTitle)”?"
    }

    public static func stopConfirmBody() -> String {
        "The dispatch will be failed."
    }

    // MARK: - Audit

    /// `timestamp  action  target  outcome  [reason]`
    public static func formatAudit(
        timestamp: Date,
        action: String,
        target: String,
        outcome: String,
        reason: String? = nil,
        formatter: ISO8601DateFormatter = iso8601
    ) -> String {
        var parts = [formatter.string(from: timestamp), action, target, outcome]
        if let reason, !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: "  ")
    }

    public static func formatAudit(_ result: OrchestrationViewMutationResult,
                                   formatter: ISO8601DateFormatter = iso8601) -> String {
        formatAudit(
            timestamp: result.timestamp, action: result.action, target: result.target,
            outcome: result.outcome, reason: result.reason, formatter: formatter)
    }

    // MARK: - Receipt / error → result

    public static func result(action: String, target: String, receipt: JSONValue,
                              timestamp: Date = Date()) -> OrchestrationViewMutationResult {
        let state = receipt.field("state")?.stringValue
        let gate = receipt.field("gate")
        let outcome: String
        if let state, !state.isEmpty {
            outcome = state
        } else if let status = gate?.field("status")?.stringValue, !status.isEmpty {
            outcome = status
        } else {
            outcome = "ok"
        }
        let reason = receipt.field("reason")?.stringValue
            ?? receipt.field("lastError")?.stringValue
        let message = receipt.field("warning")?.stringValue
            ?? receipt.field("recovery")?.stringValue
            ?? gate?.field("resolution")?.stringValue
        return OrchestrationViewMutationResult(
            timestamp: timestamp, action: action, target: target,
            outcome: outcome, reason: reason, message: message)
    }

    public static func result(action: String, target: String, error: RPCServiceError,
                              timestamp: Date = Date()) -> OrchestrationViewMutationResult {
        result(action: action, target: target,
               code: error.rpcError.code, message: error.rpcError.message,
               timestamp: timestamp)
    }

    public static func result(action: String, target: String,
                              code: String, message: String,
                              timestamp: Date = Date()) -> OrchestrationViewMutationResult {
        OrchestrationViewMutationResult(
            timestamp: timestamp, action: action, target: target,
            outcome: "error", reason: code, message: message)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
