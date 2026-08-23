import SwiftUI
import DamsonTerminal
import OrchardCore
import OrchardTerminals

/// Center workbench: per-workspace tab groups with splits.
struct WorkbenchView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if store.projects.isEmpty {
                EmptyStateView()
            } else if let key = store.selection {
                workbench(for: key)
            } else {
                EmptyStateView()
            }
        }
        .background(Tokens.background)
    }

    @ViewBuilder
    private func workbench(for key: WorkbenchKey) -> some View {
        let node = store.layout(for: key)
        VStack(spacing: 0) {
            header(for: key)
            setupBanner(for: key)
            Divider()
            SplitContainer(key: key, node: node)
        }
    }

    @ViewBuilder
    private func header(for key: WorkbenchKey) -> some View {
        HStack(spacing: 10) {
            switch key {
            case .projectRoot(let id):
                if let project = store.projects.first(where: { $0.id == id }) {
                    Image(systemName: "house")
                        .foregroundStyle(Tokens.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(project.worktrees.currentBranchName ?? project.repo.path)
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textSecondary)
                            .lineLimit(1)
                    }
                }
            case .worktree(let id):
                if let record = store.selectedRecord, record.id == id,
                   let project = store.project(owning: record) {
                    WorkspaceStatusSlot(status: store.meta.status(for: record.id), size: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.title)
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 6) {
                            Text(record.branch)
                            Text("·")
                            Text(store.meta.status(for: record.id).label)
                        }
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                    }
                    Spacer(minLength: 8)
                    approvalActions(project: project, record: record)
                }
            }
            Spacer(minLength: 8)
            Button { store.splitFocused(axis: .horizontal) } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .help("Split right")
            Button { store.splitFocused(axis: .vertical) } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .buttonStyle(.borderless)
            .help("Split down")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    @ViewBuilder
    private func approvalActions(project: ProjectSession, record: WorktreeRecord) -> some View {
        if let agent = project.liveAgents(in: record.id).first(where: {
            $0.state == .awaitingApproval
        }) {
            Button("Approve") { agent.sendKey("enter") }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Deny") { agent.sendKey("esc") }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func setupBanner(for key: WorkbenchKey) -> some View {
        if case .worktree(let id) = key, let record = store.selectedRecord, record.id == id {
            switch record.setupState {
            case .running:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Running project setup…")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Tokens.surface)
            case .failed(let output):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Project setup failed", systemImage: "exclamationmark.triangle.fill")
                        .font(Tokens.fontMeta.weight(.semibold))
                        .foregroundStyle(.orange)
                    if !output.isEmpty {
                        Text(output)
                            .font(Tokens.fontMono)
                            .foregroundStyle(Tokens.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
            case .none, .succeeded:
                EmptyView()
            }
        }
    }
}

struct SplitContainer: View {
    @EnvironmentObject var store: AppStore
    let key: WorkbenchKey
    let node: SplitNode

    var body: some View {
        switch node {
        case .group(let group):
            TabGroupPane(key: key, group: group)
        case .split(_, let axis, let first, let second):
            if axis == .horizontal {
                HSplitView {
                    SplitContainer(key: key, node: first)
                        .frame(minWidth: 220)
                    SplitContainer(key: key, node: second)
                        .frame(minWidth: 220)
                }
            } else {
                VSplitView {
                    SplitContainer(key: key, node: first)
                        .frame(minHeight: 120)
                    SplitContainer(key: key, node: second)
                        .frame(minHeight: 120)
                }
            }
        }
    }
}

struct TabGroupPane: View {
    @EnvironmentObject var store: AppStore
    let key: WorkbenchKey
    let group: TabGroup

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            tabBody
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focusedGroupID = group.id }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(group.tabs) { tab in
                TabChip(
                    tab: tab,
                    isSelected: tab.id == group.selectedID,
                    badge: badge(for: tab)
                ) {
                    store.selectTab(tab.id, in: group.id, key: key)
                }
                .contextMenu {
                    Button("Close Tab") { store.closeTab(tab.id, in: group.id, key: key) }
                }
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(TabKind.allCases) { kind in
                    Button(kind.label) { store.addTab(kind, to: group.id, key: key) }
                }
                Divider()
                Button("Split Right") { store.splitFocused(axis: .horizontal) }
                Button("Split Down") { store.splitFocused(axis: .vertical) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Tokens.surface)
    }

    @ViewBuilder
    private var tabBody: some View {
        if let tab = group.selected {
            switch tab.kind {
            case .terminal:
                TerminalPane(tab: tab, key: key)
            case .diff:
                DiffHost(key: key)
            case .editor:
                PlaceholderPane(
                    symbol: "doc.text",
                    title: "Editor",
                    detail: "The file editor lands in wave 2.")
            case .browser:
                BrowserPane(key: key)
            }
        } else {
            Color.clear
        }
    }

    private func badge(for tab: WorkbenchTab) -> String? {
        guard tab.kind == .diff, case .worktree(let id) = key,
              let record = store.selectedRecord, record.id == id,
              record.status.stat.fileCount > 0
        else { return nil }
        return "\(record.status.stat.fileCount)"
    }
}

struct TabChip: View {
    let tab: WorkbenchTab
    let isSelected: Bool
    let badge: String?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: tab.kind.symbol)
                    .font(.system(size: 10))
                Text(tab.title)
                    .font(Tokens.fontRow)
                if let badge {
                    Text(badge)
                        .font(Tokens.fontPill)
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Tokens.rowHover))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .fill(isSelected ? Tokens.background : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .strokeBorder(isSelected ? Tokens.border : .clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Tokens.text : Tokens.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

struct TerminalPane: View {
    @EnvironmentObject var store: AppStore
    let tab: WorkbenchTab
    let key: WorkbenchKey

    private var cwd: URL {
        switch key {
        case .projectRoot(let id):
            return store.projects.first { $0.id == id }?.repo
                ?? URL(fileURLWithPath: NSHomeDirectory())
        case .worktree(let id):
            return store.selectedRecord.flatMap { $0.id == id ? $0.path : nil }
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
    }

    var body: some View {
        Group {
            if let session = store.damsonSession(for: tab, cwd: cwd) {
                DamsonTerminalView(session: session, isActive: true)
                    .id(tab.agentID ?? tab.id)
            } else {
                PlaceholderPane(symbol: "terminal", title: "No session",
                                detail: "Could not attach a terminal to this tab.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DiffHost: View {
    @EnvironmentObject var store: AppStore
    let key: WorkbenchKey

    var body: some View {
        switch key {
        case .worktree(let id):
            if let project = store.projects.first(where: { $0.record(id: id) != nil }),
               let record = project.record(id: id) {
                DiffPaneView(
                    worktreeURL: record.path,
                    baseRef: record.worktree.baseRef.isEmpty ? "HEAD" : record.worktree.baseRef,
                    branch: record.branch,
                    stat: record.status.stat,
                    isRefreshing: record.isRefreshing,
                    onRefresh: { await record.refresh() })
            }
        case .projectRoot(let id):
            if let project = store.projects.first(where: { $0.id == id }) {
                DiffPaneView(
                    worktreeURL: project.repo,
                    baseRef: "HEAD",
                    branch: project.worktrees.currentBranchName ?? "",
                    stat: project.checkoutStatus.stat,
                    isRefreshing: false,
                    onRefresh: { await project.refreshCheckout() })
            }
        }
    }
}

struct PlaceholderPane: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text(title)
                .font(.title3)
                .foregroundStyle(Tokens.textSecondary)
            Text(detail)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.background)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("No project open")
                .font(.title3)
            Text("Open a git repository to start orchestrating agents.")
                .foregroundStyle(Tokens.textSecondary)
            Button("Open Project…") { store.addProjectViaPanel() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.background)
    }
}
