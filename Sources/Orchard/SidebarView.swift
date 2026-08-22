import SwiftUI
import AppKit
import DamsonTerminal
import DamsonOrchestrator

/// The primary navigation surface: a tree of projects → worktrees → the agent running in
/// each one.
///
/// The worktree card is the unit, not the agent. An agent comes and goes inside a worktree;
/// the worktree is what the user thinks of as "the thing I asked for", and it's what still
/// exists tomorrow. So the card carries the durable identity (name, branch, diff stat) and
/// the agent appears as an inline row beneath it only while one is running.
struct SidebarView: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            navHeader
            Divider()
            worktreeList
            Divider()
            toolbar
        }
        .background(Tokens.sidebar)
    }

    // MARK: - Header

    private var navHeader: some View {
        HStack(spacing: 6) {
            Text("Projects")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            Button {
                store.isJumpPaletteOpen = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Jump to a worktree (⌘J)")

            Button {
                store.addWorkspaceViaPanel()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Open a project")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var worktreeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                if store.workspaces.isEmpty {
                    emptyState
                }
                ForEach(store.workspaces) { ws in
                    Section {
                        WorkspaceWorktrees(workspace: ws)
                    } header: {
                        ProjectHeader(workspace: ws)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No projects open")
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
            Text("Open a git repository to start running agents in isolated worktrees.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Project…") { store.addWorkspaceViaPanel() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(10)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                store.requestNewWorktree()
            } label: {
                Label("New Worktree", systemImage: "plus")
                    .font(Tokens.fontMeta)
            }
            .controlSize(.small)
            .disabled(!store.canCreateWorktree)
            .help(store.selectedWorkspace?.controller.worktreeUnavailableReason
                  ?? "Create a worktree and start an agent in it (⌘N)")

            Spacer()

            Toggle(isOn: $store.showsGridOverview) {
                Image(systemName: "square.grid.2x2")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show every agent terminal at once")

            Menu {
                Picker("Theme", selection: $store.themeName) {
                    ForEach(DamsonTheme.presets, id: \.name) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .controlSize(.small)
            .help("Terminal color theme")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Sticky group header for one repo.
struct ProjectHeader: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textTertiary)
            Text(workspace.name)
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(workspace.controller.worktrees.count)")
                .font(Tokens.fontPill)
                .foregroundStyle(Tokens.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.sidebar)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedWorkspaceID = workspace.id }
        .help(workspace.repo.path)
        .contextMenu {
            Button("New Worktree…") {
                store.selectedWorkspaceID = workspace.id
                store.requestNewWorktree()
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([workspace.repo])
            }
            Divider()
            Button("Close Project", role: .destructive) {
                store.removeWorkspace(workspace)
            }
        }
    }
}

/// The worktree cards for one project. Split out so it observes the controller directly and
/// re-renders when a worktree is created or deleted.
struct WorkspaceWorktrees: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace

    var body: some View {
        // The checkout itself, always first and always present — a project you've opened is
        // usable before it has any worktrees.
        ProjectRootRow(
            workspace: workspace,
            isSelected: store.showsProjectRoot && store.selectedWorkspaceID == workspace.id)

        ForEach(workspace.controller.worktrees) { record in
            WorktreeCard(workspace: workspace, record: record,
                         isSelected: store.selectedWorktree?.id == record.id)
        }
    }
}

/// The project's own checkout as a sidebar row. Visually lighter than a worktree card —
/// it's the place you start from, not a piece of parallel work.
struct ProjectRootRow: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    var isSelected: Bool

    @State private var isHovering = false

    private var subtitle: String {
        guard workspace.controller.isGitRepository else { return "folder" }
        return workspace.controller.currentBranchName ?? "detached"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: workspace.controller.isGitRepository ? "house" : "folder")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 14)
            Text(workspace.name)
                .font(Tokens.fontRow)
                .lineLimit(1)
            Text(subtitle)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .fill(isSelected ? Tokens.rowSelected : (isHovering ? Tokens.rowHover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectProjectRoot(workspace) }
        .onHover { isHovering = $0 }
        .help(workspace.repo.path)
        .contextMenu {
            Button("Open Terminal Here") {
                store.selectProjectRoot(workspace)
                store.mainTab = .terminal
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([workspace.repo])
            }
        }
    }
}

/// One worktree: status lane + title row + meta row, with the live agent inline beneath.
struct WorktreeCard: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    @ObservedObject var record: WorktreeRecord
    var isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleRow
            metaRow
            if let agent = record.agent {
                AgentInlineRow(agent: agent)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .fill(isSelected ? Tokens.rowSelected : (isHovering ? Tokens.rowHover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.select(record, in: workspace) }
        .onHover { isHovering = $0 }
        .contextMenu { menu }
        .help(record.path.path)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                WorktreeStatusDot(state: record.displayState)
                // The unread marker rides on the status glyph rather than claiming its own
                // column, so a quiet list and a busy one have identical geometry.
                if record.hasUnseenActivity {
                    Circle()
                        .fill(.orange)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().stroke(Tokens.sidebar, lineWidth: 1.5))
                        .offset(x: -1, y: -1)
                }
            }

            Text(record.title)
                .font(Tokens.fontRow)
                .fontWeight(record.hasUnseenActivity ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            if isHovering {
                Button {
                    store.pendingDeletion = record
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Tokens.textTertiary)
                .help("Delete this worktree")
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundStyle(Tokens.textTertiary)
            Text(record.branch)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if record.status.commitsAhead > 0 {
                Label("\(record.status.commitsAhead)", systemImage: "arrow.up")
                    .font(.system(size: 9))
                    .foregroundStyle(Tokens.textTertiary)
                    .labelStyle(.titleAndIcon)
                    .help("\(record.status.commitsAhead) commits ahead of the base")
            }
            DiffStatBadge(stat: record.status.stat)
        }
        .padding(.leading, 20)   // aligns under the title, past the status lane
    }

    @ViewBuilder
    private var menu: some View {
        if record.agent == nil {
            Button("Start Agent Here") {
                workspace.controller.startAgent(in: record, engineID: "claude-code")
                store.select(record, in: workspace)
            }
        } else {
            Button("Dismiss Agent") {
                if let agent = record.agent { workspace.controller.retire(agent) }
            }
        }
        Divider()
        Button("Show Diff") {
            store.select(record, in: workspace)
            store.mainTab = .diff
        }
        Button("Open in Terminal") {
            store.select(record, in: workspace)
            store.mainTab = .terminal
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([record.path])
        }
        Button("Copy Branch Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.branch, forType: .string)
        }
        Divider()
        Button("Delete Worktree…", role: .destructive) {
            store.pendingDeletion = record
        }
    }
}

/// The live agent inside a worktree, as a single dense line.
struct AgentInlineRow: View {
    @ObservedObject var agent: AgentSession

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(agent.state.color)
                .frame(width: 5, height: 5)
            Image(systemName: agent.engine.id == "claude-code" ? "sparkles" : "terminal")
                .font(.system(size: 9))
                .foregroundStyle(Tokens.textTertiary)
            Text(agent.task.flatMap { $0.prompt.isEmpty ? nil : $0.prompt } ?? agent.state.label)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            ElapsedLabel(since: agent.startedAt)
                .font(.system(size: 9))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.leading, 20)
        .padding(.vertical, 1)
    }
}
