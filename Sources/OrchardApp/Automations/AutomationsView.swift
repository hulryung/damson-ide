import AppKit
import SwiftUI
import OrchardRuntime

/// App surface for T16 automations: list, live enable, create/edit, run history.
struct AutomationsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var browser = AutomationsBrowser()

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
            detailPane
                .frame(minWidth: 360)
        }
        .background(Tokens.background)
        .frame(minWidth: 880, minHeight: 480)
        .onAppear {
            browser.startObserving(store: store)
            Task { await browser.refresh(from: store) }
        }
        .onDisappear { browser.stopObserving() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window.title == "Automations" else { return }
            Task { await browser.refresh(from: store) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AutomationsBrowser.refreshInterval * 1_000_000_000))
                await browser.refresh(from: store)
            }
        }
        .sheet(item: $browser.editor) { mode in
            AutomationEditorSheet(
                mode: mode,
                repos: store.workspaceService.listRepos(),
                workspaces: (try? store.workspaceService.listWorkspaces()) ?? [],
                defaultProvider: store.settings.resolvedDefaultEngineID,
                onSave: { automation in
                    await browser.save(automation, isNew: mode.existing == nil, store: store)
                })
        }
        .confirmationDialog(
            browser.pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete this automation?",
            isPresented: Binding(
                get: { browser.pendingDelete != nil },
                set: { if !$0 { browser.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await browser.confirmDelete(store: store) }
            }
            Button("Cancel", role: .cancel) { browser.pendingDelete = nil }
        } message: {
            if let pending = browser.pendingDelete {
                Text(AutomationProjection.deleteConfirmation(name: pending.name, runCount: pending.runCount))
            }
        }
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !store.settings.automationsEnabled {
                Text("Scheduler is paused in Settings. Enable scheduled automations to fire; individual toggles still persist.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.orange)
                    .padding(10)
            }
            if let lastError = browser.lastError {
                Text(lastError)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.red)
                    .padding(10)
            }
            if browser.snapshot.rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(browser.snapshot.rows) { row in
                            listRow(row)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Tokens.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Automations")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            Button {
                browser.editor = .create
            } label: {
                Label("New", systemImage: "plus")
                    .font(Tokens.fontMeta)
            }
            .controlSize(.small)
            if let lastRefreshed = browser.lastRefreshed {
                ElapsedLabel(since: lastRefreshed)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .help("Seconds since the last snapshot")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No automations")
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
            Text("Schedule a prompt against a repo (fresh worktree) or an existing workspace. The runtime scheduler fires due items while Orchard is running.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("New Automation") { browser.editor = .create }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func listRow(_ row: AutomationListRow) -> some View {
        let selected = browser.selection == row.id
        return Button {
            Task { await browser.select(row.id, store: store) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { enabled in
                        Task { await browser.setEnabled(row.id, enabled: enabled, store: store) }
                    }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(row.enabled ? "Enabled — click to pause" : "Paused — click to enable")
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(Tokens.fontRow)
                        .lineLimit(1)
                    Text(row.triggerSummary)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                    Text(row.nextFire)
                        .font(Tokens.fontMono)
                        .foregroundStyle(row.enabled ? Tokens.textSecondary : Tokens.textTertiary)
                        .lineLimit(1)
                    Text(row.targetSummary)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .fill(selected ? Tokens.rowSelected : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { edit(row) }
            Button(row.enabled ? "Disable" : "Enable") {
                Task { await browser.setEnabled(row.id, enabled: !row.enabled, store: store) }
            }
            Divider()
            Button("Delete…", role: .destructive) { browser.pendingDelete = row }
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Run history")
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                if let row = browser.selectedRow() {
                    Button("Edit") { edit(row) }
                        .controlSize(.small)
                    Button("Delete…", role: .destructive) { browser.pendingDelete = row }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let row = browser.selectedRow() {
                history(for: row)
            } else {
                Text("Select an automation to see its runs.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Tokens.background)
    }

    private func history(for row: AutomationListRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                labeled("Name", row.name)
                labeled("Schedule", row.triggerSummary)
                labeled("Next fire", row.nextFire)
                labeled("Target", row.targetSummary)
                labeled("Provider", row.provider)
                labeled("History", "\(row.runCount)")
                Divider()
                if browser.runs.isEmpty {
                    Text("No runs yet.")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                } else {
                    ForEach(browser.runs) { run in
                        runCard(run)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runCard(_ run: AutomationRunRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusChip(text: run.outcome, color: outcomeColor(run.outcome))
                Text(run.startedAt)
                    .font(Tokens.fontMono)
                    .foregroundStyle(Tokens.textSecondary)
            }
            labeled("Scheduled", run.scheduledAt)
            labeled("Finished", run.finishedAt)
            if let message = run.message, !message.isEmpty {
                Text(message)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .textSelection(.enabled)
            }
            if let worktreeId = run.worktreeId, !worktreeId.isEmpty {
                if store.workspaceIdentityExists(worktreeId) {
                    Button("Open worktree") {
                        _ = store.focusWorkspaceIdentity(worktreeId)
                    }
                    .controlSize(.small)
                } else {
                    Text("Worktree \(worktreeId) is no longer in this app.")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .textSelection(.enabled)
                }
            }
            if let terminalId = run.terminalId, !terminalId.isEmpty {
                if store.workerPaneExists(handle: terminalId) {
                    Button("Jump to terminal") {
                        _ = store.focusWorkerTerminal(handle: terminalId)
                    }
                    .controlSize(.small)
                } else {
                    Text("Terminal \(terminalId) is no longer in this app.")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius)
                .fill(Tokens.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radius)
                .strokeBorder(Tokens.border)
        )
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(Tokens.fontMono)
                .textSelection(.enabled)
        }
    }

    private func outcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "fired": return Tokens.Git.added
        case "skipped": return .orange
        case "failed": return .red
        default: return Tokens.textTertiary
        }
    }

    private func edit(_ row: AutomationListRow) {
        if let automation = browser.automations.first(where: { $0.id == row.id }) {
            browser.editor = .edit(automation)
        }
    }
}
