import SwiftUI
import DamsonTerminal
import OrchardCore

extension DamsonTheme {
    var swiftBackground: Color { Color(nsColor: background) }
    var swiftForeground: Color { Color(nsColor: foreground) }
}

/// User-set board column on a workspace card. Distinct from live agent state —
/// this is Orca's `workspaceStatus` / cardStatus vocabulary (inventory §6 / §2).
enum WorkspaceStatus: String, CaseIterable, Codable, Hashable, Identifiable {
    case todo = "todo"
    case inProgress = "in-progress"
    case inReview = "in-review"
    case completed = "completed"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In progress"
        case .inReview: return "In review"
        case .completed: return "Done"
        }
    }

    var color: Color {
        switch self {
        case .todo: return Tokens.textTertiary
        case .inProgress: return Color(hex: 0x5B9FD4)
        case .inReview: return Color(hex: 0xB48EAD)
        case .completed: return Tokens.Git.added
        }
    }

    var symbol: String {
        switch self {
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .inReview: return "eye"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

extension WorktreeDisplayState {
    var color: Color {
        switch self {
        case .idle: return Tokens.textTertiary
        case .hasChanges: return Tokens.Git.modified
        case .starting: return Tokens.textSecondary
        case .working: return .accentColor
        case .needsApproval: return .orange
        case .needsInput: return .yellow
        case .agentIdle: return .green
        case .done: return Tokens.textSecondary
        case .failed: return .red
        }
    }
}

extension AgentRuntimeState {
    var color: Color {
        switch self {
        case .starting: return .secondary
        case .idle: return .green
        case .working: return .blue
        case .awaitingApproval: return .orange
        case .awaitingInput: return .yellow
        case .finished: return .gray
        case .errored: return .red
        }
    }

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .idle: return "Idle"
        case .working: return "Working"
        case .awaitingApproval: return "Needs approval"
        case .awaitingInput: return "Needs input"
        case .finished: return "Done"
        case .errored: return "Error"
        }
    }

    /// Kanban bucket for the agent dashboard (inventory §6).
    var dashboardBucket: AgentDashboardBucket {
        switch self {
        case .awaitingApproval, .awaitingInput: return .attention
        case .starting, .working: return .working
        case .finished, .errored: return .done
        case .idle: return .idle
        }
    }
}

enum AgentDashboardBucket: String, CaseIterable, Identifiable {
    case attention, working, done, idle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attention: return "Attention"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
}

/// Status slot on a workspace card: the user-set `workspaceStatus`, not live agent state.
struct WorkspaceStatusSlot: View {
    let status: WorkspaceStatus
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(status.color)
            .frame(width: 14)
            .help(status.label)
    }
}

struct DiffStatBadge: View {
    let added: Int
    let deleted: Int

    init(stat: GitDiffStat) {
        added = stat.added
        deleted = stat.deleted
    }

    init(added: Int, deleted: Int) {
        self.added = added
        self.deleted = deleted
    }

    var body: some View {
        if added > 0 || deleted > 0 {
            HStack(spacing: 4) {
                if added > 0 {
                    Text("+\(added)").foregroundStyle(Tokens.Git.added)
                }
                if deleted > 0 {
                    Text("−\(deleted)").foregroundStyle(Tokens.Git.deleted)
                }
            }
            .font(Tokens.fontMeta)
            .monospacedDigit()
        }
    }
}

extension GitFileChange.Kind {
    var color: Color {
        switch self {
        case .added: return Tokens.Git.added
        case .modified: return Tokens.Git.modified
        case .deleted: return Tokens.Git.deleted
        case .untracked: return Tokens.Git.untracked
        case .conflicted: return Tokens.Git.conflicted
        case .typeChanged: return Tokens.Git.modified
        }
    }
}

/// Elapsed time that ticks while the view is on screen.
struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
