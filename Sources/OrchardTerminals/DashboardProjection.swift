import Foundation
import OrchardCore

/// Kanban column for the agent dashboard (Orca `DashboardBucket`).
public enum DashboardBucket: String, CaseIterable, Sendable, Hashable, Identifiable {
    case attention, working, done, idle
    public var id: String { rawValue }
}

/// Precise live-state glyph. Kept distinct from `DashboardBucket` so a done
/// card that has been acknowledged can sit in idle while still reading as done
/// internally (Orca `dashboardCardDisplayState`).
public enum DashboardDotState: String, Sendable, Hashable {
    case working, blocked, waiting, done, idle
}

/// UI-free projection of an `AgentStatusSnapshot` onto the dashboard board.
///
/// Observation only — bucketing never writes orchestration or terminal state.
/// Matches Orca's `dashboard-card-bucket` + `dashboardCardDisplayState`:
/// permission/blocked/waiting → attention; a `done` entry stays in done until
/// the user acknowledges it, then settles to idle.
public enum DashboardProjection {

    /// Map a status-entry snapshot to the precise dot (Orca `row.state`).
    public static func dotState(from snapshot: AgentStatusSnapshot) -> DashboardDotState {
        switch snapshot.state {
        case .working: return .working
        case .blocked: return .blocked
        case .waiting: return .waiting
        case .done: return .done
        }
    }

    /// Fallback when the status stream has not yet published a snapshot.
    /// `idle`/`finished`/`errored` all record as status-entry `done` (see
    /// `AgentRuntimeState.statusState`); display + unseen decide the bucket.
    public static func dotState(runtime: AgentRuntimeState) -> DashboardDotState {
        switch runtime {
        case .starting, .working: return .working
        case .awaitingApproval: return .blocked
        case .awaitingInput: return .waiting
        case .idle, .finished, .errored: return .done
        }
    }

    /// Completed agents stay in `done` until acknowledged (`unseen`), then settle to idle.
    public static func displayState(dotState: DashboardDotState, unseen: Bool) -> DashboardDotState {
        (dotState == .done && !unseen) ? .idle : dotState
    }

    public static func bucket(for displayState: DashboardDotState) -> DashboardBucket {
        switch displayState {
        case .working: return .working
        case .done: return .done
        case .idle: return .idle
        case .blocked, .waiting: return .attention
        }
    }

    public static func bucket(snapshot: AgentStatusSnapshot, unseen: Bool) -> DashboardBucket {
        bucket(for: displayState(dotState: dotState(from: snapshot), unseen: unseen))
    }

    public static func bucket(runtime: AgentRuntimeState, unseen: Bool) -> DashboardBucket {
        bucket(for: displayState(dotState: dotState(runtime: runtime), unseen: unseen))
    }

    public static func glyph(for dotState: DashboardDotState) -> String {
        switch dotState {
        case .working: return "⟳"
        case .blocked: return "⚠"
        case .waiting: return "✎"
        case .done: return "✓"
        case .idle: return "●"
        }
    }

    /// Elapsed time in the current state. `stateStartedAtMs` is ms epoch, matching
    /// `AgentStatusSnapshot.stateStartedAt`.
    public static func elapsedInterval(stateStartedAtMs: Double, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince1970 - stateStartedAtMs / 1000)
    }

    public static func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// One-line card body: prefer the live prompt, then the last assistant line.
    public static func detailLine(prompt: String, lastAssistant: String?) -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty { return trimmedPrompt }
        let assistant = lastAssistant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return assistant.isEmpty ? nil : assistant
    }
}
