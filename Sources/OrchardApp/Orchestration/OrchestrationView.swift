import AppKit
import SwiftUI
import OrchardRuntime

/// Read-only window over the runtime's orchestration store: runs → tasks →
/// dispatches/workers, plus a worker archive viewer. No mutation controls.
struct OrchestrationView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var browser = OrchestrationBrowser()

    var body: some View {
        HSplitView {
            runList
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 560)
            detail
                .frame(minWidth: 360)
        }
        .background(Tokens.background)
        .frame(minWidth: 880, minHeight: 480)
        .onAppear { Task { await browser.refresh(from: store) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window.title == "Orchestration" else { return }
            Task { await browser.refresh(from: store) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(OrchestrationBrowser.refreshInterval * 1_000_000_000))
                await browser.refresh(from: store)
            }
        }
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let lastError = browser.lastError {
                Text(lastError)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.red)
                    .padding(10)
            }
            if browser.snapshot.runs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(browser.snapshot.runs) { run in
                            runGroup(run)
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
            Text("Runs")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            Text("Observation only")
                .font(Tokens.fontPill)
                .foregroundStyle(Tokens.textTertiary)
            if let lastRefreshed = browser.lastRefreshed {
                ElapsedLabel(since: lastRefreshed)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .help("Seconds since the last store snapshot")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No orchestration runs")
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
            Text("Runs created through the orchard CLI appear here. This window never starts, stops, or releases workers.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func runGroup(_ run: OrchestrationRunRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            selectableRow(.run(run.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.objective)
                        .font(Tokens.fontRow)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(run.createdAt)
                        Text(run.counts.summary)
                    }
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                }
            }
            ForEach(run.tasks) { task in
                taskGroup(task)
            }
        }
    }

    private func taskGroup(_ task: OrchestrationTaskRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            selectableRow(.task(task.id)) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusChip(text: task.status, color: StatusChip.color(forTask: task.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.label)
                            .font(Tokens.fontRow)
                            .lineLimit(1)
                        if task.title != task.displayName {
                            Text(task.title)
                                .font(Tokens.fontMeta)
                                .foregroundStyle(Tokens.textTertiary)
                                .lineLimit(1)
                        }
                        if !task.deps.isEmpty {
                            Text("deps: \(task.deps.joined(separator: ", "))")
                                .font(Tokens.fontMeta)
                                .foregroundStyle(Tokens.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.leading, 12)
            ForEach(task.dispatches) { dispatch in
                dispatchRow(dispatch)
            }
            if task.dispatches.isEmpty {
                Text("No dispatches")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.leading, 28)
                    .padding(.vertical, 2)
            }
        }
    }

    private func dispatchRow(_ dispatch: OrchestrationDispatchRow) -> some View {
        selectableRow(.dispatch(dispatch.id)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusChip(text: dispatch.dispatchStatus,
                               color: StatusChip.color(forDispatch: dispatch.dispatchStatus))
                    StatusChip(text: dispatch.workerState,
                               color: StatusChip.color(forWorker: dispatch.workerState))
                    if let terminal = dispatch.terminalState {
                        StatusChip(text: terminal,
                                   color: StatusChip.color(forTerminal: terminal))
                    }
                }
                if let handle = dispatch.agentHandle {
                    Text(handle)
                        .font(Tokens.fontMono)
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 16)
    }

    private func selectableRow<Content: View>(
        _ selection: OrchestrationSelection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let selected = browser.selection == selection
        return Button {
            Task { await browser.select(selection, store: store) }
        } label: {
            content()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radius)
                        .fill(selected ? Tokens.rowSelected : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Detail")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch browser.selection {
                    case .run(let id):
                        if let run = browser.run(id: id) { runDetail(run) }
                    case .task(let id):
                        if let task = browser.task(id: id) { taskDetail(task) }
                    case .dispatch(let id):
                        if let dispatch = browser.dispatch(id: id) { dispatchDetail(dispatch) }
                    case nil:
                        Text("Select a run, task, or dispatch.")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Tokens.background)
    }

    private func runDetail(_ run: OrchestrationRunRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(run.objective)
                .font(.system(size: 16, weight: .semibold))
            labeled("Created", run.createdAt)
            labeled("Run", run.id)
            labeled("Tasks", run.counts.summary)
        }
    }

    private func taskDetail(_ task: OrchestrationTaskRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusChip(text: task.status, color: StatusChip.color(forTask: task.status))
                Text(task.label)
                    .font(.system(size: 16, weight: .semibold))
            }
            if task.title != task.displayName {
                labeled("Title", task.title)
            }
            labeled("Display name", task.displayName)
            labeled("Task", task.id)
            labeled("Deps", task.deps.isEmpty ? "none" : task.deps.joined(separator: ", "))
            labeled("Dispatches", "\(task.dispatches.count)")
            Text(task.spec)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
                .textSelection(.enabled)
        }
    }

    private func dispatchDetail(_ dispatch: OrchestrationDispatchRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusChip(text: dispatch.dispatchStatus,
                           color: StatusChip.color(forDispatch: dispatch.dispatchStatus))
                StatusChip(text: dispatch.workerState,
                           color: StatusChip.color(forWorker: dispatch.workerState))
                if let terminal = dispatch.terminalState {
                    StatusChip(text: terminal,
                               color: StatusChip.color(forTerminal: terminal))
                }
            }
            labeled("Dispatch", dispatch.id)
            if let handle = dispatch.agentHandle {
                labeled("Agent handle", handle)
                if store.workerPaneExists(handle: handle) {
                    Button("Jump to terminal") {
                        _ = store.focusWorkerTerminal(handle: handle)
                    }
                    .help("Focus the live pane for this worker in the main window")
                } else {
                    Text("No pane for this handle in this app.")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            if let archive = browser.archive {
                WorkerArchiveViewer(archive: archive, showRaw: $browser.showRaw)
            } else if dispatch.hasArchive {
                Text("Archive is recorded but could not be read.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
            } else {
                Text("No archive yet. Live output stays on the worker pane until release.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Tokens.fontMono)
                .textSelection(.enabled)
        }
    }
}

struct WorkerArchiveViewer: View {
    let archive: OrchestrationArchiveView
    @Binding var showRaw: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(archive.isTranscript ? "Transcript pin" : "Worker archive")
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                if !archive.isTranscript {
                    Toggle("Raw", isOn: $showRaw)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Untouched capture — the same text worker-read --raw serves")
                }
            }
            let lines = archive.lines(showRaw: showRaw)
            if lines.isEmpty {
                Text("Archive is empty.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(Tokens.fontMono)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 360)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radius)
                        .fill(Tokens.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radius)
                        .strokeBorder(Tokens.border)
                )
            }
        }
        .padding(.top, 4)
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Tokens.fontPill)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.16)))
    }

    static func color(forTask status: String) -> Color {
        switch status {
        case "ready": return .green
        case "dispatched": return .blue
        case "completed": return Tokens.Git.added
        case "failed": return .red
        case "blocked": return .orange
        default: return Tokens.textTertiary
        }
    }

    static func color(forDispatch status: String) -> Color {
        switch status {
        case "dispatched", "pending": return .blue
        case "completed": return Tokens.Git.added
        case "failed", "circuit_broken": return .red
        default: return Tokens.textTertiary
        }
    }

    static func color(forWorker state: String) -> Color {
        switch state {
        case "ready", "starting": return .blue
        case "succeeded": return Tokens.Git.added
        case "failed", "abandoned": return .red
        case "stopping", "stopped", "stop_unknown", "start_unknown": return .orange
        default: return Tokens.textTertiary
        }
    }

    static func color(forTerminal state: String) -> Color {
        switch state {
        case "active": return .blue
        case "reclaimable": return .orange
        case "released": return Tokens.textTertiary
        case "release_pending", "release_unknown": return .yellow
        default: return Tokens.textSecondary
        }
    }
}
