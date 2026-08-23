import SwiftUI
import AppKit
import DamsonTerminal
import OrchardCore
import OrchardTerminals

/// Repo groups → workspace cards. Card status is the user-set `workspaceStatus`;
/// live agents appear as inline rows with state glyphs.
struct SidebarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            navHeader
            filterBar
            Divider()
            cardList
            Divider()
            toolbar
        }
        // Keep the pinned New/toggle row above the window status bar (the
        // safe-area inset stops at the AppKit column boundary).
        .padding(.bottom, Tokens.statusBarHeight)
        .background(Tokens.sidebar)
        // NavigationSplitView's window-level status-bar inset does not reach
        // the sidebar, so the New button was clipped. Reserve the same height.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: Tokens.statusBarInset)
        }
    }

    private var navHeader: some View {
        HStack(spacing: 6) {
            Text("Workspaces")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            Button { store.isJumpPaletteOpen = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Jump to a workspace, file, or command (⌘J)")

            Button { store.addProjectViaPanel() } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Open a project")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("All repos") { store.filterProjectID = nil }
                Divider()
                ForEach(store.projects) { project in
                    Button(project.name) { store.filterProjectID = project.id }
                }
            } label: {
                filterChip(
                    store.filterProjectID.flatMap { id in store.projects.first { $0.id == id }?.name }
                    ?? "Repo")
            }
            .menuStyle(.borderlessButton)

            Menu {
                Button("All statuses") { store.filterStatusID = nil }
                Divider()
                ForEach(store.statusVocabulary) { status in
                    Button(status.label) { store.filterStatusID = status.id }
                }
            } label: {
                filterChip(
                    store.filterStatusID.flatMap { id in
                        store.statusVocabulary.first { $0.id == id }?.label
                    } ?? "Status")
            }
            .menuStyle(.borderlessButton)

            Button {
                store.showArchived.toggle()
            } label: {
                Image(systemName: store.showArchived ? "archivebox.fill" : "archivebox")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.showArchived ? Color.accentColor : Tokens.textSecondary)
            }
            .buttonStyle(.borderless)
            .help(store.showArchived
                  ? "Showing archived workspaces. Click to hide them."
                  : "Archived workspaces are hidden. Click to show them.")

            Spacer(minLength: 2)

            Picker("", selection: $store.ordering) {
                ForEach(CardOrdering.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(maxWidth: 132)
            .help("Card order: manual (sortOrder) or recent (lastActivityAt)")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func filterChip(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
        }
        .font(Tokens.fontMeta)
        .foregroundStyle(Tokens.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.rowHover))
    }

    private var cardList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                if store.projects.isEmpty {
                    emptyState
                }
                ForEach(store.visibleProjects) { project in
                    Section {
                        ProjectRootRow(
                            project: project,
                            isSelected: store.selection == .projectRoot(project.id))
                        ForEach(store.visibleRecords(in: project)) { record in
                            WorkspaceCard(
                                project: project,
                                record: record,
                                isSelected: store.selection == .worktree(record.id))
                        }
                    } header: {
                        RepoHeader(project: project)
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
            Button("Open Project…") { store.addProjectViaPanel() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(10)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { store.requestNewWorktree() } label: {
                Label("New", systemImage: "plus")
                    .font(Tokens.fontMeta)
            }
            .controlSize(.small)
            .disabled(!store.canCreateWorktree)
            .help(store.selectedProject?.worktrees.worktreeUnavailableReason
                  ?? "Create a worktree and start an agent (⌘N)")

            Spacer()

            Button { store.showDashboard?() } label: {
                Image(systemName: "rectangle.split.3x1")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Agent dashboard")

            Menu {
                Picker("Theme", selection: Binding(
                    get: { store.settings.themeName },
                    set: { store.settings.themeName = $0 }
                )) {
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

struct RepoHeader: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var project: ProjectSession

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textTertiary)
            Text(project.name)
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(project.records.count)")
                .font(Tokens.fontPill)
                .foregroundStyle(Tokens.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.sidebar)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedProjectID = project.id }
        .help(project.repo.path)
        .contextMenu {
            Button("New Worktree…") {
                store.selectedProjectID = project.id
                store.requestNewWorktree()
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.repo])
            }
            Divider()
            Button("Close Project", role: .destructive) {
                store.removeProject(project)
            }
        }
    }
}

struct ProjectRootRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var project: ProjectSession
    var isSelected: Bool
    @State private var isHovering = false

    private var subtitle: String {
        guard project.worktrees.isGitRepository else { return "folder" }
        return project.worktrees.currentBranchName ?? "detached"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: project.worktrees.isGitRepository ? "house" : "folder")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 14)
            Text(project.name)
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
        .onTapGesture { store.selectProjectRoot(project) }
        .onHover { isHovering = $0 }
        .help(project.repo.path)
    }
}

struct WorkspaceCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var project: ProjectSession
    @ObservedObject var record: WorktreeRecord
    var isSelected: Bool
    @State private var isHovering = false

    private var status: WorkspaceStatusAppearance { store.statusAppearance(for: record.id) }
    private var agents: [AgentSession] { project.liveAgents(in: record.id) }
    private var unseen: Bool { store.isUnread(workspace: record.id) }
    private var archived: Bool { store.meta.isArchived(for: record.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleRow
            metaRow
            ForEach(agents) { agent in
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
        .onTapGesture { store.select(record, in: project) }
        .onHover { isHovering = $0 }
        .contextMenu { menu }
        .help(record.path.path)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                WorkspaceStatusSlot(appearance: status)
                if unseen {
                    Circle()
                        .fill(.orange)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().stroke(Tokens.sidebar, lineWidth: 1.5))
                        .offset(x: -1, y: -1)
                }
            }

            Text(record.title)
                .font(Tokens.fontRow)
                .fontWeight(unseen ? .semibold : .regular)
                .lineLimit(1)
            if archived {
                Text("Archived")
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
            }

            Spacer(minLength: 2)

            if isHovering {
                Button { store.requestDelete(record, in: project) } label: {
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
            WorkspacePortsChip(ports: store.ports(for: record, in: project))
            DiffStatBadge(stat: record.status.stat)
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private var menu: some View {
        Menu("Set status") {
            ForEach(store.statusVocabulary) { status in
                Button(status.label) { store.setWorkspaceStatus(status.id, for: record.id) }
            }
        }
        if store.ordering == .manual {
            Button("Move up") {
                store.meta.move(record.id, delta: -1, among: store.visibleRecords(in: project).map(\.id))
            }
            Button("Move down") {
                store.meta.move(record.id, delta: 1, among: store.visibleRecords(in: project).map(\.id))
            }
        }
        Divider()
        if agents.isEmpty {
            Menu("Start agent") {
                ForEach(EngineOption.all) { engine in
                    Button(engine.displayName) {
                        _ = try? store.startAgent(in: record, project: project, engineID: engine.id)
                    }
                }
            }
        } else {
            Button("Dismiss agents") {
                project.agents.retireAgents(inWorktree: record.id)
            }
        }
        Divider()
        if archived {
            Button("Unarchive") { store.setArchived(false, for: record, in: project) }
        } else {
            Button("Archive") { store.setArchived(true, for: record, in: project) }
        }
        Button("Show Diff") {
            store.select(record, in: project)
            store.selectKind(.diff)
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
            store.requestDelete(record, in: project)
        }
    }
}

struct AgentInlineRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var agent: AgentSession

    private var dot: DashboardDotState { store.displayDotState(for: agent) }

    var body: some View {
        HStack(spacing: 5) {
            Text(DashboardProjection.glyph(for: dot))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(dot.color)
                .frame(width: 12)
            Text(store.agentTypeName(for: agent))
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
            Text(store.detailLine(for: agent) ?? dotLabel)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            ElapsedLabel(since: store.stateStartedAt(for: agent))
                .font(.system(size: 9))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.leading, 20)
        .padding(.vertical, 1)
    }

    private var dotLabel: String {
        switch dot {
        case .working: return "Working"
        case .blocked: return "Needs approval"
        case .waiting: return "Needs input"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
}
