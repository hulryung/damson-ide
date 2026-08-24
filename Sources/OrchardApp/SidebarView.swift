import SwiftUI
import AppKit
import DamsonTerminal
import OrchardCore
import OrchardRuntime
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

            Menu {
                Button("Open Project…") { store.addProjectViaPanel() }
                Button("Open Remote…") { store.presentOpenRemote() }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .help("Open a project or a remote repo")
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
            Button("Open Remote…") { store.presentOpenRemote() }
                .controlSize(.small)
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
            .help(store.newWorktreeUnavailableReason
                  ?? "Create a worktree and start an agent (⌘N)")

            Spacer()

            Button { store.showDashboard?() } label: {
                Image(systemName: "rectangle.split.3x1")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Agent dashboard")

            Button { store.showOrchestration?() } label: {
                Image(systemName: "list.bullet.indent")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Orchestration runs")

            Button { store.showAutomations?() } label: {
                Image(systemName: "clock.arrow.2.circlepath")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Scheduled automations")

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
            HostChip(hostId: project.hostId)
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
            .disabled(project.isRemote)
            .help(RemoteWorkspacePolicy.unsupportedExplanation(.composer, hostId: project.hostId) ?? "")
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.repo])
            }
            .disabled(project.isRemote)
            .help(project.isRemote
                  ? "This checkout lives on \(RemoteWorkspacePolicy.hostLabel(project.hostId)); it is not a local folder."
                  : "")
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

    private var subtitle: String { project.rootSubtitle }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: project.isRemote
                  ? "network"
                  : (project.worktrees.isGitRepository ? "house" : "folder"))
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
            HostChip(hostId: project.hostId)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Tokens.rowSelected : (isHovering ? Tokens.rowHover : .clear))
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
    /// Finished/errored sessions still sit in the supervisor until dismissed;
    /// the start/restart row is for when nothing is actually running.
    private var hasLiveAgent: Bool { agents.contains { !$0.state.isTerminal } }
    private var unseen: Bool { store.isUnread(workspace: record.id) }
    private var archived: Bool { store.meta.isArchived(for: record.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleRow
            metaRow
            ForEach(agents) { agent in
                AgentInlineRow(agent: agent)
            }
            if !hasLiveAgent, !project.isRemote {
                StartAgentRow(project: project, record: record)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Tokens.rowSelected : (isHovering ? Tokens.rowHover : .clear))
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

            if isHovering, !project.isRemote {
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
            HostChip(hostId: project.hostId)
            Spacer(minLength: 4)
            WorkspacePortsChip(ports: store.ports(for: record, in: project))
            if !project.isRemote {
                DiffStatBadge(stat: record.status.stat)
            }
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
        if !hasLiveAgent {
            Menu(record.lastPrompt == nil ? "Start agent" : "Restart agent") {
                ForEach(EngineOption.all) { engine in
                    Button(engine.displayName) {
                        _ = try? store.startAgent(in: record, project: project, engineID: engine.id)
                    }
                }
            }
            .disabled(project.isRemote)
            .help(RemoteWorkspacePolicy.unsupportedExplanation(.agents, hostId: project.hostId) ?? "")
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
        .disabled(project.isRemote)
        .help(RemoteWorkspacePolicy.unsupportedExplanation(.diff, hostId: project.hostId) ?? "")
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([record.path])
        }
        .disabled(project.isRemote)
        .help(project.isRemote
              ? "This worktree lives on \(RemoteWorkspacePolicy.hostLabel(project.hostId)); it is not a local folder."
              : "")
        Button("Copy Branch Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.branch, forType: .string)
        }
        Divider()
        Button("Delete Worktree…", role: .destructive) {
            store.requestDelete(record, in: project)
        }
        .disabled(project.isRemote)
        .help(project.isRemote
              ? "Remote worktrees are removed through the orchard CLI; this path cannot reach \(RemoteWorkspacePolicy.hostLabel(project.hostId))."
              : "")
    }
}

/// Visible start/restart affordance when nothing is running in this worktree.
/// Spawns agent-first into the *existing* checkout via `AgentSupervisor`;
/// prompt is optional (last prompt is reused on restart, or the engine waits).
struct StartAgentRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var project: ProjectSession
    @ObservedObject var record: WorktreeRecord
    @State private var errorMessage: String?

    private var isRestart: Bool {
        record.lastPrompt != nil
            || project.liveAgents(in: record.id).contains { $0.state.isTerminal }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Button { start(engineID: store.settings.resolvedDefaultEngineID) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isRestart ? "arrow.clockwise" : "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 12)
                        Text(isRestart ? "Restart agent" : "Start agent")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(project.isRemote)
                Spacer(minLength: 4)
                Menu {
                    ForEach(EngineOption.all) { engine in
                        Button(engine.displayName) { start(engineID: engine.id) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Tokens.textTertiary)
                        .padding(.horizontal, 2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(project.isRemote)
            }
            .help(project.isRemote
                  ? (RemoteWorkspacePolicy.unsupportedExplanation(.agents, hostId: project.hostId) ?? "")
                  : (isRestart
                     ? "Spawn a new agent in this worktree. The last prompt is sent again if one was saved."
                     : "Spawn an agent in this worktree. Prompt is optional — empty waits at the input box."))
            if let errorMessage {
                Text(errorMessage)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.red)
                    .padding(.leading, 17)
            }
        }
        .padding(.leading, 20)
        .padding(.vertical, 1)
    }

    private func start(engineID: String) {
        errorMessage = nil
        do {
            try store.startAgent(in: record, project: project, engineID: engineID)
        } catch {
            errorMessage = String(describing: error)
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
