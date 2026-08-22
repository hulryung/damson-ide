import SwiftUI
import AppKit
import DamsonTerminal
import DamsonOrchestrator

/// The main pane for a project's own checkout.
///
/// Opening a directory should immediately give you somewhere to type — before any worktree
/// exists, and whether or not the directory is even a git repository. This is that place: a
/// shell rooted in the project, its working-tree diff, and a way to start an agent right
/// here when isolation isn't what you want.
struct ProjectRootView: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace

    @StateObject private var shell = ShellHolder()
    @State private var status: GitWorktreeStatus = .unknown
    @State private var isRefreshing = false

    private var isRepo: Bool { workspace.controller.isGitRepository }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabStrip
            Divider()
            content
        }
        .background(Tokens.background)
        .task(id: workspace.id) { await refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isRepo ? "house.fill" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if isRepo, let branch = workspace.controller.currentBranchName {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    } else if !isRepo {
                        Text("Not a git repository")
                    }
                    Text("·")
                    Text((workspace.repo.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
            }

            Spacer(minLength: 8)

            Button {
                store.requestNewWorktree()
            } label: {
                Label("New Worktree", systemImage: "plus")
                    .font(Tokens.fontMeta)
            }
            .controlSize(.small)
            .disabled(!isRepo)
            .help(workspace.controller.worktreeUnavailableReason
                  ?? "Create an isolated worktree and start an agent in it (⌘N)")

            Menu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([workspace.repo])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workspace.repo.path, forType: .string)
                }
                if isRepo {
                    Divider()
                    Button("Refresh Diff") { Task { await refresh() } }
                }
                Divider()
                Button("Close Project", role: .destructive) {
                    store.removeWorkspace(workspace)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    // MARK: - Tabs

    /// The project root has no agent of its own, so the Agent tab is replaced by Terminal as
    /// the primary view. Diff is offered only for a real repo.
    private var availableTabs: [WorkspaceStore.MainTab] {
        isRepo ? [.terminal, .diff] : [.terminal]
    }

    private var effectiveTab: WorkspaceStore.MainTab {
        availableTabs.contains(store.mainTab) ? store.mainTab : .terminal
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(availableTabs, id: \.self) { tab in
                TabChip(tab: tab,
                        isSelected: effectiveTab == tab,
                        badge: tab == .diff && status.stat.fileCount > 0
                            ? "\(status.stat.fileCount)" : nil) {
                    store.mainTab = tab
                }
            }
            Spacer()
            if isRepo {
                DiffStatBadge(stat: status.stat)
                    .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Tokens.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveTab {
        case .diff:
            PrimaryCheckoutDiffView(workspace: workspace, status: status, refresh: refresh)
        default:
            WorktreeShellView(cwd: workspace.repo, settings: store.settings, holder: shell)
        }
    }

    private func refresh() async {
        guard isRepo, !isRefreshing else { return }
        isRefreshing = true
        let controller = workspace.controller
        status = await Task.detached(priority: .utility) {
            await controller.primaryCheckoutStatus()
        }.value
        isRefreshing = false
    }
}

/// Uncommitted changes in the primary checkout — your own work in progress, not an agent's.
struct PrimaryCheckoutDiffView: View {
    @ObservedObject var workspace: Workspace
    let status: GitWorktreeStatus
    let refresh: () async -> Void

    @State private var selectedPath: String?
    @State private var diffText = ""

    private let service = GitService()

    var body: some View {
        Group {
            if status.stat.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Tokens.textTertiary)
                    Text("Working tree clean")
                        .font(.title3)
                        .foregroundStyle(Tokens.textSecondary)
                    Button("Refresh") { Task { await refresh() } }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selectedPath) {
                        ForEach(status.stat.files) { file in
                            DiffFileRow(file: file).tag(file.path)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)

                    ScrollView([.vertical, .horizontal]) {
                        DiffTextView(text: diffText)
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .onChange(of: selectedPath) { path in load(path) }
        .onAppear { if selectedPath == nil { selectedPath = status.stat.files.first?.path } }
        .onChange(of: status.stat) { stat in
            if selectedPath == nil || !stat.files.contains(where: { $0.path == selectedPath }) {
                selectedPath = stat.files.first?.path
            }
            load(selectedPath)
        }
    }

    private func load(_ path: String?) {
        guard let path else { diffText = ""; return }
        let repo = workspace.repo
        let service = self.service
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                service.diff(worktree: repo, baseRef: "HEAD", path: path)
            }.value
            await MainActor.run { diffText = text }
        }
    }
}
