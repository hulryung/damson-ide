import SwiftUI
import AppKit
import DamsonTerminal
import DamsonOrchestrator

/// The main pane for one worktree: a header identifying it, a tab strip, and the selected
/// tab's content.
///
/// The tabs are the three things a user does with an agent's worktree — watch it work
/// (Agent), inspect what it produced (Diff), and poke at the checkout yourself (Terminal).
/// They're per-worktree rather than app-global so switching sessions in the sidebar doesn't
/// silently change which view you're looking at.
struct WorktreeDetailView: View {
    @EnvironmentObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    @ObservedObject var record: WorktreeRecord

    /// One shell per worktree, shared by the Terminal tab and the Agent tab's fallback.
    /// Two independent shells for the same directory would mean two histories and two sets
    /// of background jobs for what the user thinks of as one place.
    @StateObject private var shell = ShellHolder()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            setupBanner
            tabStrip
            Divider()
            content
        }
        .background(Tokens.background)
    }

    /// Setup progress for a fresh worktree. A silently-failed `npm install` looks exactly
    /// like a healthy checkout until the agent starts producing nonsense, so the failure is
    /// shown inline with its output rather than logged.
    @ViewBuilder
    private var setupBanner: some View {
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
            Divider()
        case .failed(let output):
            VStack(alignment: .leading, spacing: 4) {
                Label("Project setup failed", systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.fontMeta.weight(.semibold))
                    .foregroundStyle(.orange)
                if !output.isEmpty {
                    ScrollView(.vertical) {
                        Text(output)
                            .font(Tokens.fontMono)
                            .foregroundStyle(Tokens.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 84)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            Divider()
        case .none, .succeeded:
            EmptyView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            WorktreeStatusDot(state: record.displayState, size: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label(record.branch, systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text(record.displayState.label)
                    if let agent = record.agent {
                        Text("·")
                        ElapsedLabel(since: agent.startedAt)
                    }
                }
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
            }

            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    @ViewBuilder
    private var actions: some View {
        // An approval gate is the one thing that blocks all progress, so its controls are
        // promoted out of any menu and sit directly in the header.
        if let agent = record.agent, agent.state == .awaitingApproval {
            Button("Approve") { agent.sendKey("enter") }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Deny") { agent.sendKey("escape") }
                .controlSize(.small)
        }

        if let agent = record.agent {
            Button {
                agent.interrupt()
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Interrupt (Ctrl-C)")

            Button {
                workspace.controller.retire(agent)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Dismiss this agent (the worktree and its changes stay)")
        } else {
            Button {
                workspace.controller.startAgent(in: record, engineID: "claude-code")
            } label: {
                Label("Start Agent", systemImage: "play.fill")
                    .font(Tokens.fontMeta)
            }
            .controlSize(.small)
            .help("Run a new agent in this worktree")
        }

        Menu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([record.path])
            }
            Button("Copy Worktree Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.path.path, forType: .string)
            }
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.branch, forType: .string)
            }
            Divider()
            Button("Refresh Diff") { Task { await record.refresh() } }
            Divider()
            Button("Delete Worktree…", role: .destructive) {
                store.pendingDeletion = record
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceStore.MainTab.allCases, id: \.self) { tab in
                TabChip(tab: tab,
                        isSelected: store.mainTab == tab,
                        badge: badge(for: tab)) {
                    store.mainTab = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Tokens.surface)
    }

    /// The Diff tab carries the changed-file count, so the user can see there is something
    /// to review without switching to it.
    private func badge(for tab: WorkspaceStore.MainTab) -> String? {
        guard tab == .diff, record.status.stat.fileCount > 0 else { return nil }
        return "\(record.status.stat.fileCount)"
    }

    /// The Agent tab always shows a **live** terminal.
    ///
    /// A worktree with no agent used to show a dead-end empty state, and an agent whose
    /// process had exited left a frozen screen that swallowed keystrokes — the pane looked
    /// broken in exactly the moments the user most wanted to type something. In both cases
    /// the fallback is a real shell in the worktree, with a thin bar offering to start (or
    /// restart) an agent, so there is never a tab you can't work in.
    @ViewBuilder
    private var content: some View {
        switch store.mainTab {
        case .agent:
            if let agent = record.agent, !agent.damsonSession.processExited {
                DamsonTerminalView(session: agent.damsonSession, isActive: true)
                    .id(agent.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    startAgentBar
                    Divider()
                    WorktreeShellView(cwd: record.path, settings: store.settings, holder: shell)
                }
            }
        case .diff:
            DiffPaneView(record: record)
        case .terminal:
            WorktreeShellView(cwd: record.path, settings: store.settings, holder: shell)
        }
    }

    /// Offered above the fallback shell — the worktree is fully usable meanwhile.
    private var startAgentBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
            Text(record.agent == nil
                 ? "No agent here — this is a shell in the worktree."
                 : "The agent exited — this is a shell in the worktree.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
            Spacer(minLength: 6)
            ForEach(AgentEngineRegistry.all, id: \.id) { engine in
                Button(record.agent == nil ? engine.displayName : "Restart \(engine.displayName)") {
                    workspace.controller.startAgent(in: record, engineID: engine.id)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Tokens.surface)
    }
}

/// One tab in the per-worktree strip.
struct TabChip: View {
    let tab: WorkspaceStore.MainTab
    let isSelected: Bool
    let badge: String?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 10))
                Text(tab.label)
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

/// A plain login shell rooted in the worktree — the escape hatch for everything Orchard
/// doesn't do itself (running tests, `git rebase`, opening an editor).
///
/// Lazily spawned: creating a PTY for every worktree up front would mean N idle shells for N
/// sessions, so the process starts the first time the tab is actually opened and is reused
/// after that.
struct WorktreeShellView: View {
    @EnvironmentObject var store: WorkspaceStore
    /// Directory the shell is rooted in — a worktree, or a project's own checkout.
    let cwd: URL
    /// Observed rather than passed as a snapshot, so a theme or font change in Settings
    /// reaches shells that are already running. The config is baked into a `DamsonSession`
    /// at spawn; nothing re-reads it, so it has to be pushed.
    @ObservedObject var settings: OrchardSettings
    @ObservedObject var holder: ShellHolder

    /// Cheap identity for the presentation fields, so `onChange` fires for exactly the
    /// settings a terminal cares about and not for every unrelated preference.
    private var styleKey: String {
        "\(settings.themeName)|\(settings.fontFamily)|\(settings.fontSize)"
    }

    var body: some View {
        Group {
            if let session = holder.session {
                DamsonTerminalView(session: session, isActive: true)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            holder.start(cwd: cwd, config: settings.terminalConfig())
            // Register so the store can push future settings changes here, the same way it
            // does for agents; registering also applies the current settings immediately.
            store.registerShell(holder)
        }
        // Belt and braces for a shell whose tab was hidden while settings changed: the store
        // push already covers it, but re-applying on appear costs nothing and can't be stale.
        .onChange(of: styleKey) { _ in holder.apply(settings.terminalConfig()) }
    }
}

/// Owns the shell `DamsonSession` so it survives tab switches and is torn down with the view.
///
/// Deliberately not `@MainActor`: `deinit` has to terminate the PTY, and a main-actor-isolated
/// stored property is unreachable from a nonisolated deinit. `DamsonSession` is itself
/// nonisolated, and `start` is only ever called from `onAppear`.
final class ShellHolder: ObservableObject {
    @Published private(set) var session: DamsonSession?

    func start(cwd: URL, config: DamsonConfig) {
        guard session == nil else { return }
        var config = config
        config.cwd = cwd.path
        config.argv = [DamsonConfig.loginShellPath(), "-l"]
        session = DamsonSession(config: config)
    }

    /// Push new presentation settings into a running shell. Only the appearance fields are
    /// copied — argv and cwd belong to the live process and must survive a settings change.
    func apply(_ config: DamsonConfig) {
        guard let session else { return }
        var updated = session.config
        guard updated.theme != config.theme
                || updated.fontSize != config.fontSize
                || updated.fontFamily != config.fontFamily else { return }
        updated.theme = config.theme
        updated.fontSize = config.fontSize
        updated.fontFamily = config.fontFamily
        session.updateConfig(updated)
    }

    deinit {
        // Without this the shell process outlives its tab and leaks a PTY per worktree.
        session?.terminate()
    }
}
