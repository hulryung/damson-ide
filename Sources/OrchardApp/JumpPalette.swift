import SwiftUI
import AppKit
import OrchardCore
import OrchardRuntime
import OrchardTerminals

/// ⌘J — workspaces, agents, quickOpen files for the selected workspace, and commands.
/// Every row is ranked by `PaletteRanking` through `PaletteSources`.
struct JumpPalette: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = 0
    @State private var quickOpenPaths: [String] = []
    @FocusState private var queryFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var catalog: [PaletteCandidate] {
        var workspaces: [PaletteWorkspaceSeed] = []
        var agents: [PaletteAgentSeed] = []
        for project in store.projects {
            for record in project.records {
                workspaces.append(PaletteWorkspaceSeed(
                    id: record.id, title: record.title,
                    branch: record.branch, repo: project.name))
            }
            for agent in project.agents.agents {
                agents.append(PaletteAgentSeed(
                    id: agent.id,
                    title: agent.task?.title ?? agent.engine.displayName,
                    engine: agent.engine.displayName,
                    branch: agent.branchName ?? "",
                    repo: project.name,
                    state: agent.state.label))
            }
        }
        return PaletteSources.catalog(
            workspaces: workspaces,
            agents: agents,
            files: quickOpenPaths,
            workspaceTitle: selectedWorkspaceTitle,
            includeFiles: !trimmedQuery.isEmpty)
    }

    private var results: [PaletteCandidate] {
        PaletteSources.rank(query: query, candidates: catalog)
    }

    private var selectedWorkspaceTitle: String {
        if let record = store.selectedRecord { return record.title }
        return store.selectedProject?.name ?? ""
    }

    private var selectedRoot: URL? {
        if let record = store.selectedRecord { return record.path }
        if case .projectRoot(let id) = store.selection {
            return store.projects.first { $0.id == id }?.repo
        }
        return store.selectedProject?.repo
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Tokens.textTertiary)
                TextField("Jump to a workspace, file, or command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($queryFocused)
                    .onSubmit(activateSelection)
                    .onChange(of: query) { _ in selection = 0 }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider()
            resultList
        }
        .frame(width: 560, height: 380)
        .background(Tokens.background)
        .onAppear {
            queryFocused = true
            loadQuickOpen()
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                activateSelection()
                            }
                    }
                    if results.isEmpty {
                        Text(emptyMessage)
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(6)
            }
            .onChange(of: selection) { proxy.scrollTo($0, anchor: .center) }
        }
        .background(
            KeyCaptureView(
                onUp: { move(-1) },
                onDown: { move(1) },
                onEscape: { dismiss() }
            )
        )
    }

    private var emptyMessage: String {
        if store.projects.isEmpty {
            return "No workspaces yet — create one with ⌘N."
        }
        return "Nothing matches “\(query)”."
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func activateSelection() {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        if let id = PaletteSources.parseWorkspaceID(item.id) {
            activateWorkspace(id)
        } else if let id = PaletteSources.parseAgentID(item.id) {
            store.focus(agentID: id)
        } else if let path = PaletteSources.parseFilePath(item.id) {
            activateFile(path)
        } else if let command = PaletteSources.parseCommand(item.id) {
            store.runPaletteCommand(command)
        }
        dismiss()
    }

    private func activateWorkspace(_ id: UUID) {
        for project in store.projects {
            if let record = project.record(id: id) {
                store.select(record, in: project)
                return
            }
        }
    }

    private func activateFile(_ path: String) {
        if let record = store.selectedRecord,
           let project = store.project(owning: record) {
            store.openPaletteFile(path, in: record, project: project)
            return
        }
        store.pendingOpenPath = path
        store.selectKind(.editor)
    }

    private func loadQuickOpen() {
        guard let root = selectedRoot else {
            quickOpenPaths = []
            return
        }
        let files = store.runtime?.fileService ?? FileService()
        Task.detached {
            let paths = (try? files.list(root: root, limit: 500).files) ?? []
            await MainActor.run { quickOpenPaths = paths }
        }
    }
}

struct PaletteRow: View {
    @EnvironmentObject var store: AppStore
    let item: PaletteCandidate
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Tokens.fontRow)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius)
                .fill(isSelected ? Tokens.rowSelected : .clear)
        )
    }

    @ViewBuilder
    private var leading: some View {
        if item.kind == .agent, let id = PaletteSources.parseAgentID(item.id),
           let agent = agent(id) {
            Text(agent.state.glyph)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(agent.state.color)
                .frame(width: 14)
        } else {
            Image(systemName: item.symbol)
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 14)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if item.kind == .workspace, let id = PaletteSources.parseWorkspaceID(item.id),
           let record = record(id) {
            DiffStatBadge(stat: record.status.stat)
        } else if item.kind == .command {
            Text("⌘")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
        }
    }

    private func record(_ id: UUID) -> WorktreeRecord? {
        for project in store.projects {
            if let record = project.record(id: id) { return record }
        }
        return nil
    }

    private func agent(_ id: UUID) -> AgentSession? {
        for project in store.projects {
            if let agent = project.agents.agents.first(where: { $0.id == id }) {
                return agent
            }
        }
        return nil
    }
}

/// Arrow/escape while the search field keeps first responder. macOS 13 has no `onKeyPress`.
struct KeyCaptureView: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(onUp: onUp, onDown: onDown, onEscape: onEscape)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onUp: onUp, onDown: onDown, onEscape: onEscape)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var onUp: (() -> Void)?
        private var onDown: (() -> Void)?
        private var onEscape: (() -> Void)?

        func install(onUp: @escaping () -> Void, onDown: @escaping () -> Void,
                     onEscape: @escaping () -> Void) {
            self.onUp = onUp
            self.onDown = onDown
            self.onEscape = onEscape
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 126: self.onUp?(); return nil
                case 125: self.onDown?(); return nil
                case 53: self.onEscape?(); return nil
                default: return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
