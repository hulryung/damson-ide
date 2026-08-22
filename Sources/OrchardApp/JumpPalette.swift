import SwiftUI
import AppKit
import OrchardCore
import OrchardTerminals

/// ⌘J — jump to a workspace or a live agent across every open project.
struct JumpPalette: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var queryFocused: Bool

    private var results: [PaletteItem] {
        PaletteRanking.rank(query: query, items: items) { item in
            switch item {
            case .workspace(_, _, let record, let repo):
                return [(record.title, 300), (record.branch, 200), (repo, 100)]
            case .agent(_, let agent, _, let repo):
                return [
                    (agent.task?.title ?? agent.engine.displayName, 300),
                    (agent.engine.displayName, 220),
                    (agent.branchName ?? "", 180),
                    (repo, 100),
                ]
            }
        }
    }

    private var items: [PaletteItem] {
        var out: [PaletteItem] = []
        for project in store.projects {
            for record in project.records {
                out.append(.makeWorkspace(project: project, record: record, repo: project.name))
            }
            for agent in project.agents.agents {
                out.append(.makeAgent(agent: agent, project: project, repo: project.name))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Tokens.textTertiary)
                TextField("Jump to a workspace or agent…", text: $query)
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
        .onAppear { queryFocused = true }
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
                        Text(items.isEmpty
                             ? "No workspaces yet — create one with ⌘N."
                             : "Nothing matches “\(query)”.")
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

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func activateSelection() {
        guard results.indices.contains(selection) else { return }
        switch results[selection] {
        case .workspace(_, let project, let record, _):
            store.select(record, in: project)
        case .agent(_, let agent, _, _):
            store.focus(agentID: agent.id)
        }
        dismiss()
    }
}

enum PaletteItem: Identifiable {
    case workspace(id: String, project: ProjectSession, record: WorktreeRecord, repo: String)
    case agent(id: String, agent: AgentSession, project: ProjectSession, repo: String)

    var id: String {
        switch self {
        case .workspace(let id, _, _, _): return id
        case .agent(let id, _, _, _): return id
        }
    }

    @MainActor
    static func makeWorkspace(project: ProjectSession, record: WorktreeRecord, repo: String) -> PaletteItem {
        .workspace(id: "ws-\(record.id.uuidString)", project: project, record: record, repo: repo)
    }

    @MainActor
    static func makeAgent(agent: AgentSession, project: ProjectSession, repo: String) -> PaletteItem {
        .agent(id: "ag-\(agent.id.uuidString)", agent: agent, project: project, repo: repo)
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            switch item {
            case .workspace(_, _, let record, let repo):
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Tokens.textTertiary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title)
                        .font(Tokens.fontRow)
                        .lineLimit(1)
                    Text("\(repo) · \(record.branch)")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                DiffStatBadge(stat: record.status.stat)
            case .agent(_, let agent, _, let repo):
                Text(agent.state.glyph)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(agent.state.color)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.task?.title ?? agent.engine.displayName)
                        .font(Tokens.fontRow)
                        .lineLimit(1)
                    Text("\(repo) · \(agent.engine.displayName) · \(agent.state.label)")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius)
                .fill(isSelected ? Tokens.rowSelected : .clear)
        )
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
