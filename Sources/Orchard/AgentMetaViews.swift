import SwiftUI
import DamsonOrchestrator

/// A self-updating "how long has this agent been alive" label. Ticks once a second via
/// `TimelineView`, so there's no per-view timer to manage.
struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }

    /// Compact duration: `42s`, `3m 07s`, `1h 12m`.
    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}

/// Glanceable status roll-up for a workspace: one `glyph × count` chip per distinct agent
/// state, ordered most-urgent first. Rendered in the sidebar's Agents section header.
struct StateSummary: View {
    let agents: [AgentSession]

    /// Group by glyph (stable per state case, ignoring associated values like exit codes).
    private static let order = ["⟳", "⚠", "✎", "●", "◌", "✓", "✗"]

    var body: some View {
        let groups = Dictionary(grouping: agents, by: { $0.state.glyph })
        HStack(spacing: 7) {
            ForEach(Self.order.filter { groups[$0] != nil }, id: \.self) { glyph in
                let members = groups[glyph]!
                HStack(spacing: 2) {
                    Text(glyph).foregroundStyle(members[0].state.color)
                    Text("\(members.count)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption2)
        .monospacedDigit()
    }
}
