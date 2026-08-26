import SwiftUI
import DamsonTerminal
import OrchardCore
import OrchardTerminals

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

    /// Fallback kanban bucket when the status stream has not published yet.
    var dashboardBucket: DashboardBucket {
        DashboardProjection.bucket(runtime: self, unseen: false)
    }
}

extension DashboardBucket {
    var title: String {
        switch self {
        case .attention: return "Attention"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
}

extension DashboardDotState {
    var color: Color {
        switch self {
        case .working: return .blue
        case .blocked: return .orange
        case .waiting: return .yellow
        case .done: return .gray
        case .idle: return .green
        }
    }
}

/// Resolved board-column visuals for the four defaults plus custom vocabulary
/// (`WorkspaceStatusDefinition.color` / `.icon` from settings / orchard-data.json).
struct WorkspaceStatusAppearance: Identifiable, Hashable {
    let id: String
    let label: String
    let color: Color
    let symbol: String

    init(definition: WorkspaceStatusDefinition) {
        id = definition.id
        label = definition.label
        color = Self.color(token: definition.color, id: definition.id)
        symbol = Self.symbol(icon: definition.icon, id: definition.id)
    }

    init(status: WorkspaceStatus) {
        id = status.rawValue
        label = status.label
        color = status.color
        symbol = status.symbol
    }

    static func resolve(id: String, vocabulary: [WorkspaceStatusDefinition]) -> WorkspaceStatusAppearance {
        if let definition = vocabulary.first(where: { $0.id == id }) {
            return WorkspaceStatusAppearance(definition: definition)
        }
        if let status = WorkspaceStatus(rawValue: id) {
            return WorkspaceStatusAppearance(status: status)
        }
        return WorkspaceStatusAppearance(
            definition: WorkspaceStatusDefinition(id: id, label: id, color: "neutral", icon: "circle"))
    }

    /// Named tokens Orca ships, plus a few extras used by custom columns.
    static let colorTokens = [
        "neutral", "blue", "sky", "violet", "amber", "emerald", "rose", "zinc",
    ]

    static func color(token: String?, id: String) -> Color {
        let raw = (token?.isEmpty == false ? token : defaultColorToken(for: id)) ?? "neutral"
        switch raw {
        case "neutral": return Tokens.textTertiary
        case "blue", "conductor-progress": return Color(hex: 0x5B9FD4)
        case "sky": return Color(hex: 0x7DD3FC)
        case "violet", "conductor-review": return Color(hex: 0xB48EAD)
        case "amber": return Color(hex: 0xE2C08D)
        case "emerald", "conductor-done": return Tokens.Git.added
        case "rose": return Color(hex: 0xE4676B)
        case "zinc": return Tokens.textSecondary
        default:
            if let hex = parseHex(raw) { return Color(hex: hex) }
            return Tokens.textTertiary
        }
    }

    static func symbol(icon: String?, id: String) -> String {
        let raw = (icon?.isEmpty == false ? icon : defaultIcon(for: id)) ?? "circle"
        switch raw {
        case "circle": return "circle"
        case "circle-dot", "circle-progress", "conductor-progress": return "circle.lefthalf.filled"
        case "circle-dashed": return "circle.dashed"
        case "circle-ellipsis": return "ellipsis.circle"
        case "git-pull-request", "conductor-review": return "eye"
        case "timer": return "timer"
        case "flag": return "flag"
        case "circle-alert": return "exclamationmark.circle"
        case "circle-pause": return "pause.circle"
        case "circle-play": return "play.circle"
        case "circle-check", "conductor-done": return "checkmark.circle.fill"
        case "ban": return "nosign"
        default:
            return WorkspaceStatus(rawValue: id)?.symbol ?? "circle"
        }
    }

    private static func defaultColorToken(for id: String) -> String {
        switch id {
        case "todo": return "neutral"
        case "in-progress": return "blue"
        case "in-review": return "violet"
        case "completed": return "emerald"
        default: return "neutral"
        }
    }

    private static func defaultIcon(for id: String) -> String {
        switch id {
        case "todo": return "circle"
        case "in-progress": return "circle-dot"
        case "in-review": return "git-pull-request"
        case "completed": return "circle-check"
        default: return "circle"
        }
    }

    private static func parseHex(_ raw: String) -> UInt32? {
        var hex = raw
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return value
    }
}

/// Status slot on a workspace card: the user-set `workspaceStatus`, not live agent state.
struct WorkspaceStatusSlot: View {
    let appearance: WorkspaceStatusAppearance
    var size: CGFloat = 9

    init(appearance: WorkspaceStatusAppearance, size: CGFloat = 9) {
        self.appearance = appearance
        self.size = size
    }

    init(status: WorkspaceStatus, size: CGFloat = 9) {
        self.appearance = WorkspaceStatusAppearance(status: status)
        self.size = size
    }

    init(definition: WorkspaceStatusDefinition, size: CGFloat = 9) {
        self.appearance = WorkspaceStatusAppearance(definition: definition)
        self.size = size
    }

    var body: some View {
        Image(systemName: appearance.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(appearance.color)
            .frame(width: 14)
            .help(appearance.label)
    }
}

struct DiffStatBadge: View {
    let added: Int
    let deleted: Int
    /// False when a refresh declined to read some untracked file, which makes `added` a
    /// floor rather than a total. The badge says so instead of printing a number it knows
    /// is short.
    var countsComplete = true

    init(stat: GitDiffStat) {
        added = stat.added
        deleted = stat.deleted
        countsComplete = stat.countsComplete
    }

    init(added: Int, deleted: Int) {
        self.added = added
        self.deleted = deleted
    }

    var body: some View {
        if added > 0 || deleted > 0 {
            HStack(spacing: 4) {
                if added > 0 {
                    Text(countsComplete ? "+\(added)" : "+\(added)…")
                        .foregroundStyle(Tokens.Git.added)
                }
                if deleted > 0 {
                    Text("−\(deleted)").foregroundStyle(Tokens.Git.deleted)
                }
            }
            .font(Tokens.fontMeta)
            .monospacedDigit()
            .help(countsComplete ? "" : "Some untracked files were too large to count.")
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
        DashboardProjection.formatElapsed(interval)
    }
}
