import SwiftUI
import DamsonOrchestrator

/// Top-level layout: the project/worktree sidebar and a detail area showing the selected
/// worktree — or, when the grid toggle is on, every agent terminal at once.
struct RootView: View {
    @EnvironmentObject var store: WorkspaceStore
    /// Sidebar can be collapsed (hidden) or shown; also drag-resizable within the width range.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: Tokens.sidebarMinWidth,
                    ideal: Tokens.sidebarIdealWidth,
                    max: Tokens.sidebarMaxWidth)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .help("Toggle sidebar (⌃⌘S)")
                        .keyboardShortcut("s", modifiers: [.command, .control])
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.requestNewWorktree()
                        } label: {
                            Label("New Worktree", systemImage: "plus")
                        }
                        .help("New worktree (⌘N)")
                    }
                }
        }
        .sheet(isPresented: composerPresented) {
            if let ws = store.workspaces.first(where: { $0.id == store.composerWorkspaceID }) {
                NewWorktreeComposer(workspace: ws)
            }
        }
        .sheet(item: $store.pendingDeletion) { record in
            if let ws = store.workspace(owning: record) {
                DeleteWorktreeSheet(workspace: ws, record: record)
            }
        }
        .sheet(isPresented: $store.isJumpPaletteOpen) {
            JumpPalette()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if store.workspaces.isEmpty {
            EmptyStateView()
        } else if store.showsGridOverview, let ws = store.selectedWorkspace {
            AgentGridView(controller: ws.controller)
                .background(store.theme.swiftBackground)
                .navigationTitle(ws.name)
                .navigationSubtitle("All agents")
        } else if let record = store.selectedWorktree,
                  let ws = store.workspace(owning: record) {
            // Keyed by worktree so per-worktree view state (notably the fallback shell)
            // is rebuilt when the selection changes rather than leaking across sessions.
            WorktreeDetailView(workspace: ws, record: record)
                .id(record.id)
                .navigationTitle(record.title)
                .navigationSubtitle(record.branch)
        } else if let ws = store.selectedWorkspace {
            // The project's own checkout — and the landing spot for a project with no
            // worktrees, so opening a directory always lands somewhere you can type.
            ProjectRootView(workspace: ws)
                .id(ws.id)
                .navigationTitle(ws.name)
                .navigationSubtitle(ws.controller.currentBranchName ?? ws.repo.path)
        } else {
            EmptyStateView()
        }
    }

    private var composerPresented: Binding<Bool> {
        Binding(
            get: { store.composerWorkspaceID != nil },
            set: { if !$0 { store.composerWorkspaceID = nil } }
        )
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("No project open")
                .font(.title3)
            Text("Open a git repository to start orchestrating agents.")
                .foregroundStyle(Tokens.textSecondary)
            Button("Open Project…") { store.addWorkspaceViaPanel() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.background)
    }
}

/// A project is open but has no worktrees yet.
struct NoWorktreesView: View {
    @EnvironmentObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("No worktrees yet")
                .font(.title3)
            Text("Each agent works in its own git worktree, isolated from your checkout.")
                .foregroundStyle(Tokens.textSecondary)
                .multilineTextAlignment(.center)
            Button("New Worktree…") { store.requestNewWorktree() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.background)
    }
}
