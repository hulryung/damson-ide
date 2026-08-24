import SwiftUI
import DamsonTerminal
import OrchardCore
import OrchardRuntime
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
                    Image(systemName: project.isRemote ? "network" : "house")
                        .foregroundStyle(Tokens.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 6) {
                            Text(project.rootSubtitle)
                            if project.isRemote {
                                Text("·")
                                Text(project.repo.path)
                            }
                        }
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                    }
                    HostChip(hostId: project.hostId)
                }
            case .worktree(let id):
                if let record = store.selectedRecord, record.id == id,
                   let project = store.project(owning: record) {
                    WorkspaceStatusSlot(appearance: store.statusAppearance(for: record.id), size: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(record.title)
                                .font(.system(size: 13, weight: .semibold))
                            HostChip(hostId: project.hostId)
                        }
                        HStack(spacing: 6) {
                            Text(record.branch)
                            Text("·")
                            Text(store.statusAppearance(for: record.id).label)
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
                let reason = store.unsupportedReason(tab.kind, for: key)
                TabChip(
                    tab: tab,
                    isSelected: tab.id == group.selectedID,
                    badge: badge(for: tab),
                    onToggleViewMode: tab.isAgentTab
                        ? { store.toggleViewMode(tab.id, in: group.id, key: key) }
                        : nil
                ) {
                    if reason == nil {
                        store.selectTab(tab.id, in: group.id, key: key)
                    }
                }
                .disabled(reason != nil)
                .help(reason ?? "")
                .contextMenu {
                    if tab.isAgentTab {
                        Button(tab.viewMode == .chat ? "Show Terminal" : "Show Chat") {
                            store.toggleViewMode(tab.id, in: group.id, key: key)
                        }
                    }
                    Button("Close Tab") { store.closeTab(tab.id, in: group.id, key: key) }
                }
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(TabKind.allCases) { kind in
                    let reason = store.unsupportedReason(kind, for: key)
                    Button(kind.label) { store.addTab(kind, to: group.id, key: key) }
                        .disabled(reason != nil)
                        .help(reason ?? "")
                }
                // T29: remote shells. Only registered hosts appear — the app never
                // offers a connection target the user did not add.
                if !store.registeredHosts.isEmpty {
                    Menu("Remote Shell") {
                        ForEach(store.registeredHosts) { host in
                            Button(host.name) {
                                store.addRemoteShellTab(host: host, to: group.id, key: key)
                            }
                        }
                    }
                }
                Divider()
                Button("Split Right") { store.split(group.id, key: key, axis: .horizontal) }
                Button("Split Down") { store.split(group.id, key: key, axis: .vertical) }
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
            if let affordance = tab.kind.remoteAffordance,
               store.unsupportedReason(affordance, for: key) != nil {
                RemoteUnsupportedView(affordance: affordance,
                                      hostId: store.executionHostId(for: key))
            } else {
                switch tab.kind {
                case .terminal:
                    TerminalPane(tab: tab, key: key)
                case .diff:
                    DiffHost(key: key)
                case .editor:
                    EditorPane(tab: tab, key: key)
                case .browser:
                    BrowserPane(key: key)
                }
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
    let onToggleViewMode: (() -> Void)?
    let select: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                HStack(spacing: 5) {
                    Image(systemName: tab.kind.symbol)
                        .font(.system(size: 10))
                    Text(tab.title)
                        .font(Tokens.fontRow)
                    if tab.isDirty {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                    // The execution host, never inferred: a pane whose shell lives on
                    // another machine says so in its label.
                    HostChip(hostId: tab.executionHostId)
                    if let badge {
                        Text(badge)
                            .font(Tokens.fontPill)
                            .monospacedDigit()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Tokens.rowHover))
                    }
                }
            }
            .buttonStyle(.plain)
            if let onToggleViewMode {
                Button(action: onToggleViewMode) {
                    Image(systemName: tab.viewMode == .chat
                          ? "terminal"
                          : "bubble.left.and.bubble.right")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(3)
                }
                .buttonStyle(.borderless)
                .help(tab.viewMode == .chat
                      ? "Show terminal (⌘⇧J)"
                      : "Show chat (⌘⇧J)")
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
}

struct TerminalPane: View {
    @EnvironmentObject var store: AppStore
    let tab: WorkbenchTab
    let key: WorkbenchKey

    private var cwd: URL {
        // A remote path is not a local directory. Handing it to Damson as cwd
        // either fails or finds a same-named folder on this machine.
        if store.isRemote(key) {
            return URL(fileURLWithPath: NSHomeDirectory())
        }
        switch key {
        case .projectRoot(let id):
            return store.projects.first { $0.id == id }?.repo
                ?? URL(fileURLWithPath: NSHomeDirectory())
        case .worktree(let id):
            return store.selectedRecord.flatMap { $0.id == id ? $0.path : nil }
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
    }

    /// Identity for the terminal surface: the pane it shows, plus which PTY channel
    /// it is showing. Both halves matter — the first keeps a tab's surface stable
    /// across redraws, the second rebuilds it when a reconnect puts a new PTY behind
    /// the same pane.
    private var paneSurfaceID: String {
        "\(tab.agentID ?? tab.id):\(store.paneGeneration[tab.id] ?? 0)"
    }

    var body: some View {
        Group {
            if let session = store.damsonSession(for: tab, key: key, cwd: cwd) {
                ZStack(alignment: .top) {
                    // The PTY stays in the tree so chat is an overlay, never a
                    // second session. Keyboard focus leaves it while chat is up.
                    // TerminalFitHost snaps the surface to whole cells so the
                    // first row is never half-clipped (T30).
                    TerminalFitHost(session: session, isActive: tab.viewMode != .chat)
                        // The surface binds its session when it is built, so a pane
                        // whose PTY was replaced under it (a reconnect) needs a new
                        // identity — and deserves one: it is a different channel to
                        // the same pane, not the old connection resumed.
                        .id(paneSurfaceID)
                    if tab.isAgentTab, tab.viewMode == .chat {
                        ChatView(controller: store.chatController(for: tab)) {
                            Task { await store.submitChat(for: tab) }
                        }
                    }
                    // What the PTY ending proved, in verdict language: for a remote
                    // pane a dropped connection is never a report that the remote work
                    // stopped.
                    if let note = store.connectionEndedNote(for: tab) {
                        ConnectionEndedBanner(tab: tab, note: note)
                    }
                }
            } else if let note = store.connectionEndedNote(for: tab) {
                // A pane restored with its connection already ended: there is no PTY
                // to draw, and the tab says what ended rather than quietly opening a
                // second connection in its place.
                VStack(spacing: 0) {
                    ConnectionEndedBanner(tab: tab, note: note)
                    Spacer(minLength: 0)
                }
            } else {
                PlaceholderPane(
                    symbol: "terminal", title: "No session",
                    detail: store.paneUnavailableDetail(for: tab, key: key))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.prepareChat(for: tab) }
    }
}

/// What a remote pane says when its connection ended, and the one action that can
/// follow.
///
/// The copy is the verdict vocabulary's, verbatim: the connection ended, what is
/// happening on the far side is unverifiable, and reconnecting opens a *new*
/// connection rather than resuming the old one. The button says "Reconnect" for the
/// same reason — "Resume" or "Reattach" would claim a continuity nobody can prove.
private struct ConnectionEndedBanner: View {
    @EnvironmentObject var store: AppStore
    let tab: WorkbenchTab
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(note)
                .font(Tokens.fontRow)
                .frame(maxWidth: .infinity, alignment: .leading)
            if store.reconnectablePaneKey(for: tab) != nil {
                Button(RemotePaneRestoration.reconnectActionTitle) {
                    store.reconnectRemotePane(tab: tab)
                }
                .buttonStyle(.borderless)
                .font(Tokens.fontRow)
                .help("Open a new connection from this pane's recorded host, directory "
                      + "and command. Any work left on the host is untouched.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface)
    }
}

struct DiffHost: View {
    @EnvironmentObject var store: AppStore
    let key: WorkbenchKey

    var body: some View {
        if store.unsupportedReason(RemoteAffordance.diff, for: key) != nil {
            RemoteUnsupportedView(affordance: .diff, hostId: store.executionHostId(for: key))
        } else {
            switch key {
            case .worktree(let id):
                if let project = store.projects.first(where: { $0.record(id: id) != nil }),
                   let record = project.record(id: id) {
                    // Observe the record so commit/push/refresh actually re-render
                    // the pane (stat and unpushedCommits live on @Published status).
                    WorktreeDiffPane(record: record)
                }
            case .projectRoot(let id):
                if let project = store.projects.first(where: { $0.id == id }) {
                    ProjectCheckoutDiffPane(project: project)
                }
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
            HStack(spacing: 10) {
                Button("Open Project…") { store.addProjectViaPanel() }
                    .buttonStyle(.borderedProminent)
                Button("Open Remote…") { store.presentOpenRemote() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.background)
    }
}
