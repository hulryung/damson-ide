import SwiftUI

/// Top-level layout: workspace-card sidebar + tab-group workbench.
struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
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
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .help("Toggle sidebar")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { store.requestNewWorktree() } label: {
                            Label("New Worktree", systemImage: "plus")
                        }
                        .help("New worktree (⌘N)")
                    }
                }
        }
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
    }

    private var composerPresented: Binding<Bool> {
        Binding(
            get: { store.composerProjectID != nil },
            set: { if !$0 { store.composerProjectID = nil } }
        )
    }
}
