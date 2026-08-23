import SwiftUI

/// Top-level layout: workspace-card sidebar + tab-group workbench.
struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        // NavigationSplitView must stay the window-root view: wrapping it in a
        // VStack breaks its NSSplitViewController sizing (content collapses to
        // the top-left). The status bar rides in as a bottom safe-area inset.
        NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(
                        min: Tokens.sidebarMinWidth,
                        ideal: Tokens.sidebarIdealWidth,
                        max: Tokens.sidebarMaxWidth)
            } detail: {
                WorkbenchView()
                    .fileExplorerSidebar()
                    .toolbar {
                        // NavigationSplitView supplies its own sidebar toggle on
                        // macOS 13+; a custom one shows as a duplicate icon.
                        ToolbarItem(placement: .primaryAction) {
                            Button { store.requestNewWorktree() } label: {
                                Label("New Worktree", systemImage: "plus")
                            }
                            .disabled(!store.canCreateWorktree)
                            .help(store.newWorktreeUnavailableReason ?? "New worktree (⌘N)")
                        }
                    }
            }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBarView() }
        .sheet(isPresented: composerPresented) {
            if let project = store.projects.first(where: { $0.id == store.composerProjectID }) {
                ComposerView(project: project)
            }
        }
        .sheet(item: $store.pendingDeletion) { pending in
            if let project = store.projects.first(where: { $0.id == pending.projectID }) {
                DeleteWorktreeSheet(project: project, record: pending.record)
            }
        }
        .sheet(isPresented: $store.isJumpPaletteOpen) {
            JumpPalette()
        }
        .sheet(isPresented: $store.isOpenRemotePresented) {
            OpenRemoteSheet()
        }
    }

    private var composerPresented: Binding<Bool> {
        Binding(
            get: { store.composerProjectID != nil },
            set: { if !$0 { store.composerProjectID = nil } }
        )
    }
}
