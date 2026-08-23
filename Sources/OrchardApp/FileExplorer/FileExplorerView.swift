import AppKit
import SwiftUI
import OrchardCore
import OrchardRuntime

/// Trailing-edge file explorer. Lives in its own directory so T8 can keep owning
/// the rest of the chrome; the only hook is `View.fileExplorerSidebar()`.
struct FileExplorerSidebar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            if let record = store.selectedRecord {
                FileExplorerPane(
                    root: record.path,
                    changed: changedMap(record.status.stat),
                    identity: record.id.uuidString)
                    .id(record.id)
            } else if case .projectRoot(let id) = store.selection,
                      let project = store.projects.first(where: { $0.id == id }) {
                FileExplorerPane(
                    root: project.repo,
                    changed: changedMap(project.checkoutStatus.stat),
                    identity: project.id.uuidString)
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
        .onAppear { model.configure(root: root, files: store.runtime?.fileService ?? FileService()) }
        .onChange(of: identity) { _ in
            model.configure(root: root, files: store.runtime?.fileService ?? FileService())
        }
        .onChange(of: model.showDotfiles) { _ in model.reload() }
        .onChange(of: model.filter) { _ in model.applyFilter() }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.children[""] ?? []) { node in
                    FileTreeRow(node: node, depth: 0, model: model, changed: changed,
                                onActivate: activate, onReveal: reveal)
                }
            }
            .padding(.vertical, 4)
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
            .contentShape(Rectangle())
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

    private var root: URL?
    private var files = FileService()

    func configure(root: URL, files: FileService) {
        self.root = root
        self.files = files
        reload()
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

    private func load(parent: String) {
        guard let root else { return }
        do {
            let entries = try files.readDir(root: root, relativePath: parent, showDotfiles: showDotfiles)
            children[parent] = entries.map { entry in
                let rel = parent.isEmpty ? entry.name : parent + "/" + entry.name
                return FileNode(relativePath: rel, name: entry.name,
                                isDirectory: entry.isDirectory, isSymlink: entry.isSymlink)
            }
            error = nil
        } catch {
            self.error = String(describing: error)
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
