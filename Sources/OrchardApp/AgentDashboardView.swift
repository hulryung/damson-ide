import SwiftUI
import OrchardCore
import OrchardTerminals

/// Agent dashboard: kanban buckets attention | working | done | idle, fed by
/// the UI-free `DashboardBoard` projection. Click-to-focus routes through the
/// store so the main workbench selects that workspace and binds the agent's
/// terminal tab. Observation-only — never writes orchestration state.
struct AgentDashboardView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let board = store.dashboardBoard()
        HStack(alignment: .top, spacing: 8) {
            ForEach(DashboardBucket.allCases) { bucket in
                dashboardColumn(bucket, board: board)
            }
        }
        .padding(10)
        .background(Tokens.background)
        .frame(minWidth: 880, minHeight: 420)
    }

    private func dashboardColumn(_ bucket: DashboardBucket, board: DashboardBoard) -> some View {
        let visible = board.cards(in: bucket)
        let total = board.total(in: bucket)
        let overflow = board.overflow(in: bucket)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bucket.title)
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Text("\(total)")
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
                    .monospacedDigit()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visible) { card in
                        DashboardCardView(card: card)
                    }
                    if overflow > 0 {
                        Text("+\(overflow) more")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .fill(Tokens.surface)
        )
    }
}

struct DashboardCardView: View {
    @EnvironmentObject var store: AppStore
    let card: DashboardCard

    private var dot: DashboardDotState { card.displayDotState }

    /// Done cards stay highlighted until the user focuses them (card.unseen).
    private var highlighted: Bool { card.isHighlighted }

    private var workspaceStatus: WorkspaceStatusAppearance? {
        guard let id = card.workspaceStatusId else { return nil }
        return WorkspaceStatusAppearance.resolve(id: id, vocabulary: store.statusVocabulary)
    }

    private var timeColumn: Date {
        Date(timeIntervalSince1970: card.timeColumnMs / 1000)
    }

    var body: some View {
        Button {
            store.focus(dashboardCard: card)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(DashboardProjection.glyph(for: dot))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dot.color)
                    Text(card.agentType)
                        .font(Tokens.fontRow)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ElapsedLabel(since: timeColumn)
                        .font(.system(size: 9))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Text(card.workspaceName)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                if !card.task.isEmpty {
                    Text(card.task)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(2)
                }
                if let user = card.lastUserMessage, user != card.task {
                    Text(user)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(2)
                }
                if let agent = card.lastAgentMessage {
                    Text(agent)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(2)
                }
                if let ask = card.askSummary {
                    Text(ask)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Color.orange)
                        .lineLimit(2)
                }
                if let parent = card.parentPaneKey {
                    Text("child of \(parent)")
                        .font(Tokens.fontPill)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                }
                if let status = workspaceStatus {
                    Text(status.label)
                        .font(Tokens.fontPill)
                        .foregroundStyle(status.color)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .fill(highlighted ? Color.accentColor.opacity(0.22) : Tokens.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.5) : Tokens.border)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["Focus this agent"]
        if !card.paneKey.isEmpty { parts.append(card.paneKey) }
        return parts.joined(separator: " · ")
    }
}
