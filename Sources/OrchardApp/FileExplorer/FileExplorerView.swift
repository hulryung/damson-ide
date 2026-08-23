import AppKit
import SwiftUI
import OrchardCore
import OrchardRuntime

/// Trailing-edge file explorer. Lives in its own directory so T8 can keep owning
/// the rest of the chrome; the only hook is `View.fileExplorerSidebar()`.
struct FileExplorerSidebar: View {
    @EnvironmentObject var store: AppStore
    @State private var revealPath: String?

    var body: some View {
        VStack(spacing: 0) {
            if let record = store.selectedRecord {
                FileExplorerPane(
                    root: record.path,
                    changed: changedMap(record.status.stat),
                    identity: record.id.uuidString,
                    revealPath: revealPath)
                    .id(record.id)
            } else if case .projectRoot(let id) = store.selection,
                      let project = store.projects.first(where: { $0.id == id }) {
                FileExplorerPane(
                    root: project.repo,
                    changed: changedMap(project.checkoutStatus.stat),
                    identity: project.id.uuidString,
                    revealPath: revealPath)
                    .id(project.id)
            } else {
                empty
            }
        }
        .background(Tokens.sidebar)
        .task { await listenForOpens() }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("No worktree selected")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changedMap(_ stat: GitDiffStat) -> [String: GitFileChange.Kind] {
        Dictionary(uniqueKeysWithValues: stat.files.map { ($0.path, $0.kind) })
    }

    private func listenForOpens() async {
        guard let center = store.runtime?.fileOpenCenter else { return }
        for await request in center.events() {
            await MainActor.run { handleOpen(request) }
        }
    }

    private func handleOpen(_ request: FileOpenRequest) {
        store.focusMainWindow?()
        if let match = matchingRecord(path: request.worktreePath) {
            store.select(match.record, in: match.project)
        }
        store.selectKind(request.mode == .diff ? .diff : .editor)
        revealPath = request.relativePath
    }

    private func matchingRecord(path: String) -> (project: ProjectSession, record: WorktreeRecord)? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for project in store.projects {
            for record in project.records {
                if record.path.standardizedFileURL.path == standardized {
                    return (project, record)
                }
            }
        }
        return nil
    }
}

private struct FileExplorerPane: View {
    let root: URL
    let changed: [String: GitFileChange.Kind]
    let identity: String
    let revealPath: String?

    @EnvironmentObject var store: AppStore
    @StateObject private var model = FileExplorerModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = model.error {
                Text(message)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.filter.trimmingCharacters(in: .whitespaces).isEmpty {
                tree
            } else {
                hits
            }
        }
        .onAppear { configureAndReveal() }
        .onChange(of: identity) { _ in configureAndReveal() }
        .onChange(of: revealPath) { _ in
            if let revealPath { model.reveal(revealPath) }
        }
        .onChange(of: model.showDotfiles) { _ in model.reload() }
        .onChange(of: model.filter) { _ in model.applyFilter() }
    }

    private func configureAndReveal() {
        model.configure(root: root, files: store.runtime?.fileService ?? FileService())
        if let revealPath { model.reveal(revealPath) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Files")
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer(minLength: 4)
                Button {
                    model.showDotfiles.toggle()
                } label: {
                    Image(systemName: model.showDotfiles ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(model.showDotfiles ? "Hide dotfiles" : "Show dotfiles")
                Button { model.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reload")
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textTertiary)
                TextField("Filter", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(Tokens.fontMeta)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Tokens.radius).fill(Tokens.rowHover))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.children[""] ?? []) { node in
                        FileTreeRow(node: node, depth: 0, model: model, changed: changed,
                                    onActivate: activate, onReveal: reveal)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.highlighted) { path in
                if let path { proxy.scrollTo(path, anchor: .center) }
            }
        }
    }

    private var hits: some View {
        List(model.hits, id: \.relativePath) { hit in
            FileRowLabel(name: hit.basename, relativePath: hit.relativePath,
                         isDirectory: false, isSymlink: false,
                         change: changed[hit.relativePath])
                .contentShape(Rectangle())
                .onTapGesture { activate(hit.relativePath) }
                .contextMenu {
                    Button("Reveal in Finder") { reveal(hit.relativePath) }
                    if changed[hit.relativePath] != nil {
                        Button("Open Diff") { activate(hit.relativePath) }
                    }
                }
            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        }
        .listStyle(.sidebar)
    }

    private func activate(_ relativePath: String) {
        model.highlighted = relativePath
        if changed[relativePath] != nil {
            store.selectKind(.diff)
        }
    }

    private func reveal(_ relativePath: String) {
        let url = root.appendingPathComponent(relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    @ObservedObject var model: FileExplorerModel
    let changed: [String: GitFileChange.Kind]
    let onActivate: (String) -> Void
    let onReveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if node.isDirectory {
                    Button {
                        model.toggle(node)
                    } label: {
                        Image(systemName: model.expanded.contains(node.relativePath)
                              ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Tokens.textTertiary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12)
                }
                FileRowLabel(name: node.name, relativePath: node.relativePath,
                             isDirectory: node.isDirectory, isSymlink: node.isSymlink,
                             change: changed[node.relativePath])
            }
            .padding(.leading, CGFloat(depth) * 12 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .background(model.highlighted == node.relativePath ? Tokens.rowSelected : Color.clear)
            .contentShape(Rectangle())
            .id(node.relativePath)
            .onTapGesture {
                if node.isDirectory {
                    model.toggle(node)
                } else {
                    onActivate(node.relativePath)
                }
            }
            .contextMenu {
                Button("Reveal in Finder") { onReveal(node.relativePath) }
                if !node.isDirectory, changed[node.relativePath] != nil {
                    Button("Open Diff") { onActivate(node.relativePath) }
                }
            }
            if node.isDirectory, model.expanded.contains(node.relativePath) {
                ForEach(model.children[node.relativePath] ?? []) { child in
                    FileTreeRow(node: child, depth: depth + 1, model: model, changed: changed,
                                onActivate: onActivate, onReveal: onReveal)
                }
            }
        }
    }
}

private struct FileRowLabel: View {
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let isSymlink: Bool
    let change: GitFileChange.Kind?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(change?.color ?? (isDirectory ? Tokens.textSecondary : Tokens.textTertiary))
                .frame(width: 14)
            Text(name)
                .font(Tokens.fontRow)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Tokens.text)
            Spacer(minLength: 2)
            if let change {
                Text(change.letter)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(change.color)
            }
        }
    }

    private var symbol: String {
        if isDirectory { return "folder" }
        if isSymlink { return "link" }
        return "doc"
    }
}

private struct FileNode: Identifiable, Hashable {
    var relativePath: String
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool
    var id: String { relativePath }
}

@MainActor
private final class FileExplorerModel: ObservableObject {
    @Published var showDotfiles = false
    @Published var filter = ""
    @Published var children: [String: [FileNode]] = [:]
    @Published var expanded: Set<String> = []
    @Published var hits: [FileSearchHit] = []
    @Published var error: String?
    @Published var highlighted: String?

    private var root: URL?
    private var files = FileService()
    private var watcher: FileWatcher?
    private var watchTask: Task<Void, Never>?

    deinit {
        watchTask?.cancel()
        watcher?.stop()
    }

    func configure(root: URL, files: FileService) {
        self.root = root
        self.files = files
        reload()
        startWatching()
    }

    func reload() {
        children = [:]
        expanded = []
        error = nil
        load(parent: "")
        applyFilter()
    }

    func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.relativePath) {
            expanded.remove(node.relativePath)
        } else {
            load(parent: node.relativePath)
            expanded.insert(node.relativePath)
        }
    }

    func applyFilter() {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !needle.isEmpty else {
            hits = []
            return
        }
        do {
            let result = try files.search(root: root, query: needle, showDotfiles: showDotfiles, limit: 64)
            hits = result.files
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Expand ancestors and highlight `relativePath` so an opened diff/file tab
    /// is visible in the tree without a manual refresh.
    func reveal(_ relativePath: String) {
        let trimmed = relativePath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }
        filter = ""
        hits = []
        load(parent: "")
        var prefix = ""
        let parts = trimmed.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            prefix = prefix.isEmpty ? part : prefix + "/" + part
            load(parent: prefix)
            expanded.insert(prefix)
        }
        highlighted = trimmed
    }

    private func startWatching() {
        watchTask?.cancel()
        watcher?.stop()
        guard let root else { return }
        let watcher = FileWatcher()
        self.watcher = watcher
        let stream = watcher.events()
        watchTask = Task { [weak self] in
            for await batch in stream {
                if Task.isCancelled { break }
                await MainActor.run { self?.applyWatch(batch) }
            }
        }
        do {
            try watcher.start(root: root)
        } catch {
            self.error = String(describing: error)
        }
    }

    private func applyWatch(_ batch: FileWatchBatch) {
        if batch.rootDeleted {
            watcher?.stop()
            children = [:]
            expanded = []
            highlighted = nil
            error = "This folder was deleted"
            return
        }
        let loaded = Array(children.keys)
        for parent in loaded {
            if parent.isEmpty {
                load(parent: "")
                continue
            }
            if directoryExists(parent) {
                load(parent: parent)
            } else {
                children[parent] = nil
                expanded.remove(parent)
            }
        }
        if let highlighted, !pathExists(highlighted) {
            self.highlighted = nil
        }
    }

    private func directoryExists(_ relativePath: String) -> Bool {
        guard let root else { return false }
        do {
            return try files.stat(root: root, relativePath: relativePath).isDirectory
        } catch {
            return false
        }
    }

    private func pathExists(_ relativePath: String) -> Bool {
        guard let root else { return false }
        do {
            _ = try files.stat(root: root, relativePath: relativePath)
            return true
        } catch {
            return false
        }
    }

    private func load(parent: String) {
        guard let root else { return }
        do {
            let entries = try files.readDir(root: root, relativePath: parent, showDotfiles: showDotfiles)
            children[parent] = entries.map { entry in
                let rel = parent.isEmpty ? entry.name : parent + "/" + entry.name
                return FileNode(relativePath: rel, name: entry.name,
                                isDirectory: entry.isDirectory, isSymlink: entry.isSymlink)
            }
            if parent.isEmpty { error = nil }
        } catch {
            if parent.isEmpty {
                self.error = String(describing: error)
                children[parent] = []
            } else {
                children[parent] = nil
                expanded.remove(parent)
            }
        }
    }
}

extension View {
    /// T9's single chrome hook: pin the file explorer as a trailing split of the workbench.
    func fileExplorerSidebar() -> some View {
        HSplitView {
            self
            FileExplorerSidebar()
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 380)
        }
    }
}
