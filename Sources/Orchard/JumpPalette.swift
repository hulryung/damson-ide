import SwiftUI
import DamsonOrchestrator

/// ⌘J — jump straight to any worktree across every open project.
///
/// The sidebar stops being navigable somewhere around a dozen sessions, which is exactly the
/// scale this app is for. Typing a few characters of a name, branch, or repo gets you there
/// without moving your hands.
struct JumpPalette: View {
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var queryFocused: Bool

    private var results: [PaletteItem] {
        let items = store.allWorktrees.map { pair in
            PaletteItem(workspace: pair.workspace, record: pair.record)
        }
        return PaletteRanking.rank(query: query, items: items)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultList
        }
        .frame(width: 560, height: 380)
        .background(Tokens.background)
        .onAppear { queryFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.textTertiary)
            TextField("Jump to a worktree…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($queryFocused)
                .onSubmit(activateSelection)
                .onChange(of: query) { _ in selection = 0 }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
                        Text(store.allWorktrees.isEmpty
                             ? "No worktrees yet — create one with ⌘N."
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
        // Arrow keys drive the list while focus stays in the text field, so the user never
        // has to tab out of what they're typing.
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
        let item = results[selection]
        store.select(item.record, in: item.workspace)
        dismiss()
    }
}

/// One worktree candidate in the palette.
///
/// The searchable fields are snapshotted as plain strings at construction rather than read
/// through the main-actor-isolated record, so `PaletteRanking` stays a pure function over
/// values and can be tested without an actor hop.
struct PaletteItem: Identifiable {
    let id: UUID
    let title: String
    let branch: String
    let repoName: String
    /// Handles used only on activation, back on the main actor.
    let workspace: Workspace
    let record: WorktreeRecord

    @MainActor
    init(workspace: Workspace, record: WorktreeRecord) {
        self.id = record.id
        self.title = record.title
        self.branch = record.branch
        self.repoName = workspace.name
        self.workspace = workspace
        self.record = record
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            WorktreeStatusDot(state: item.record.displayState)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Tokens.fontRow)
                    .lineLimit(1)
                Text("\(item.repoName) · \(item.branch)")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            DiffStatBadge(stat: item.record.status.stat)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius)
                .fill(isSelected ? Tokens.rowSelected : .clear)
        )
    }
}

/// Ranking for the jump palette. Pure and side-effect free so it can be unit-tested without
/// standing up any SwiftUI.
enum PaletteRanking {
    /// Subsequence match (so "fxp" finds "fix-parser"), weighted by which field matched and
    /// bonused when the match starts at a word boundary. Empty query keeps sidebar order.
    static func rank(query: String, items: [PaletteItem]) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }

        return items.compactMap { item -> (PaletteItem, Int)? in
            let fields = [(item.title, 300), (item.branch, 200), (item.repoName, 100)]
            var best: Int?
            for (text, weight) in fields {
                guard let score = matchScore(query: q, in: text.lowercased()) else { continue }
                best = max(best ?? 0, weight + score)
            }
            guard let score = best else { return nil }
            return (item, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// `nil` when `query` isn't a subsequence of `text`. Otherwise a score that prefers
    /// matches which are contiguous and start early.
    static func matchScore(query: String, in text: String) -> Int? {
        if query.isEmpty { return 0 }
        var score = 0
        var lastIndex: String.Index?
        var searchStart = text.startIndex

        for char in query {
            guard let found = text[searchStart...].firstIndex(of: char) else { return nil }
            // Contiguous with the previous match, or sitting on a word boundary.
            if let last = lastIndex, text.index(after: last) == found {
                score += 12
            } else if found == text.startIndex
                        || text[text.index(before: found)] == "-"
                        || text[text.index(before: found)] == "/"
                        || text[text.index(before: found)] == "_" {
                score += 8
            }
            lastIndex = found
            searchStart = text.index(after: found)
        }
        // Earlier overall matches beat later ones.
        let offset = text.distance(from: text.startIndex, to: lastIndex ?? text.startIndex)
        return score + max(0, 40 - offset)
    }
}

/// Bridges arrow/escape keys to closures without stealing first-responder status from the
/// search field. SwiftUI on macOS 13 has no `onKeyPress`, so this is an AppKit monitor
/// scoped to the palette's lifetime.
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
                case 126: self.onUp?(); return nil     // ↑
                case 125: self.onDown?(); return nil   // ↓
                case 53: self.onEscape?(); return nil  // esc
                default: return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
