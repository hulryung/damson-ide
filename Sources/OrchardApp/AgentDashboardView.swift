import SwiftUI
import OrchardCore
import OrchardTerminals

/// Agent dashboard: kanban buckets attention | working | done | idle, fed by
/// the live `AgentStatusSnapshot` stream. Click-to-focus routes through the
/// store so the main workbench selects that workspace and binds the agent's
/// terminal tab. Observation-only — never writes orchestration state.
struct AgentDashboardView: View {
    @EnvironmentObject var store: AppStore

    /// Bound so a huge fleet can't blank the popout (inventory §6).
    private let capPerBucket = 40

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(DashboardBucket.allCases) { bucket in
                dashboardColumn(bucket)
            }
        }
        .padding(10)
        .background(Tokens.background)
        .frame(minWidth: 880, minHeight: 420)
    }

    private func cards(in bucket: DashboardBucket) -> [DashboardCard] {
        var items: [DashboardCard] = []
        for project in store.projects {
            for agent in project.agents.agents {
                if store.dashboardBucket(for: agent) == bucket {
                    items.append(DashboardCard(project: project, agent: agent))
                }
            }
        }
        return items
    }

    private func dashboardColumn(_ bucket: DashboardBucket) -> some View {
        let all = cards(in: bucket)
        let visible = Array(all.prefix(capPerBucket))
        let overflow = max(0, all.count - visible.count)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bucket.title)
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Text("\(all.count)")
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

struct DashboardCard: Identifiable {
    let id: UUID
    let project: ProjectSession
    let agent: AgentSession

    @MainActor
    init(project: ProjectSession, agent: AgentSession) {
        self.id = agent.id
        self.project = project
        self.agent = agent
    }
}

struct DashboardCardView: View {
    @EnvironmentObject var store: AppStore
    let card: DashboardCard

    private var dot: DashboardDotState {
        store.displayDotState(for: card.agent)
    }

    /// Done cards stay highlighted until the user focuses them (AppStore unread).
    private var highlighted: Bool { dot == .done }

    private var workspaceStatus: WorkspaceStatusAppearance? {
        card.agent.worktree.map { store.statusAppearance(for: $0.id) }
    }

    var body: some View {
        Button {
            store.focus(agentID: card.agent.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(DashboardProjection.glyph(for: dot))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dot.color)
                    Text(store.agentTypeName(for: card.agent))
                        .font(Tokens.fontRow)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ElapsedLabel(since: store.stateStartedAt(for: card.agent))
                        .font(.system(size: 9))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Text(store.workspaceName(for: card.agent, in: card.project))
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                if let line = store.detailLine(for: card.agent) {
                    Text(line)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(2)
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
        .help("Focus this agent")
    }
}
