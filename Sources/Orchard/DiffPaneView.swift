import SwiftUI
import DamsonOrchestrator

/// Review pane: what did this agent actually change?
///
/// Two columns — a file list on the left, the unified diff for the selection on the right —
/// measured against the commit the worktree forked from, so committed and uncommitted agent
/// work read as one change set. That framing is the point: the reviewer's question is "what
/// did this agent do", never "what is currently staged".
struct DiffPaneView: View {
    @ObservedObject var record: WorktreeRecord

    @State private var selectedPath: String?
    @State private var diffText: String = ""
    @State private var isLoadingDiff = false
    /// Bumped to cancel an in-flight load when the selection changes again quickly.
    @State private var loadToken = UUID()

    private let service = GitService()

    var body: some View {
        Group {
            if record.status.stat.isEmpty {
                emptyState
            } else {
                HSplitView {
                    fileList
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                    diffContent
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            }
        }
        .background(Tokens.background)
        .task(id: record.id) { await record.refresh() }
        .onChange(of: record.status.stat) { stat in
            // Keep the selection pinned across refreshes when the file is still in the set;
            // losing your place on every agent turn would make review impossible.
            if let selected = selectedPath, stat.files.contains(where: { $0.path == selected }) {
                Task { await loadDiff(for: selected) }
            } else {
                selectFirst(in: stat)
            }
        }
        .onAppear { if selectedPath == nil { selectFirst(in: record.status.stat) } }
    }

    private func selectFirst(in stat: GitDiffStat) {
        selectedPath = stat.files.first?.path
        if let path = selectedPath {
            Task { await loadDiff(for: path) }
        } else {
            diffText = ""
        }
    }

    // MARK: - File list

    private var fileList: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $selectedPath) {
                ForEach(record.status.stat.files) { file in
                    DiffFileRow(file: file)
                        .tag(file.path)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedPath) { path in
                guard let path else { return }
                Task { await loadDiff(for: path) }
            }
        }
        .background(Tokens.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(record.status.stat.fileCount) changed")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            Spacer(minLength: 4)
            DiffStatBadge(stat: record.status.stat)
            Button {
                Task { await record.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(record.isRefreshing)
            .help("Re-read the diff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - Diff

    private var diffContent: some View {
        VStack(spacing: 0) {
            if let path = selectedPath {
                diffHeader(path: path)
                Divider()
            }
            ScrollView([.vertical, .horizontal]) {
                if isLoadingDiff {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    DiffTextView(text: diffText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Tokens.background)
    }

    private func diffHeader(path: String) -> some View {
        HStack(spacing: 8) {
            Text(path)
                .font(Tokens.fontMono)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSWorkspace.shared.selectFile(record.path.appendingPathComponent(path).path,
                                              inFileViewerRootedAtPath: record.path.path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Tokens.surface)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("No changes yet")
                .font(.title3)
                .foregroundStyle(Tokens.textSecondary)
            Text("Changes this agent makes in \(record.branch) will show up here.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
            Button("Refresh") { Task { await record.refresh() } }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Load one file's diff off the main actor — `git diff` on a large file is slow enough
    /// to drop frames if it runs inline.
    private func loadDiff(for path: String) async {
        let token = UUID()
        loadToken = token
        isLoadingDiff = true
        let worktree = record.path
        let base = record.worktree.baseRef.isEmpty ? "HEAD" : record.worktree.baseRef
        let service = self.service
        let text = await Task.detached(priority: .userInitiated) {
            service.diff(worktree: worktree, baseRef: base, path: path)
        }.value
        // A newer selection superseded this load — drop the stale result.
        guard loadToken == token else { return }
        diffText = text
        isLoadingDiff = false
    }
}

/// One row in the changed-file list: status letter, filename, directory, and line counts.
struct DiffFileRow: View {
    let file: GitFileChange

    var body: some View {
        HStack(spacing: 7) {
            Text(file.kind.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(file.kind.color)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 0) {
                Text(file.fileName)
                    .font(Tokens.fontRow)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            if file.isBinary {
                Text("bin")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Tokens.textTertiary)
            } else {
                HStack(spacing: 3) {
                    if file.added > 0 {
                        Text("+\(file.added)").foregroundStyle(Tokens.Git.added)
                    }
                    if file.deleted > 0 {
                        Text("−\(file.deleted)").foregroundStyle(Tokens.Git.deleted)
                    }
                }
                .font(.system(size: 10))
                .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .help(file.path)
    }
}

/// Renders unified-diff text with per-line coloring.
///
/// Each line is its own `Text` in a `LazyVStack` rather than one attributed blob: a diff can
/// run to thousands of lines, and laying out only what's on screen is the difference between
/// instant and a visible stall. Lines are pre-classified once into value types so scrolling
/// does no string inspection at all.
struct DiffTextView: View {
    let text: String

    private var lines: [DiffLine] { DiffLine.parse(text) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(line.content.isEmpty ? " " : line.content)
                    .font(Tokens.fontMono)
                    .foregroundStyle(line.kind.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.kind.background)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }
}

/// One classified line of a unified diff.
struct DiffLine: Identifiable {
    enum Kind {
        case added, removed, hunk, fileHeader, context

        var foreground: Color {
            switch self {
            case .added: return Tokens.Git.added
            case .removed: return Tokens.Git.deleted
            case .hunk: return Tokens.Git.hunkHeader
            case .fileHeader: return Tokens.textSecondary
            case .context: return Tokens.text
            }
        }

        var background: Color {
            switch self {
            case .added: return Tokens.Git.addedLine
            case .removed: return Tokens.Git.deletedLine
            default: return .clear
            }
        }
    }

    let id: Int
    let content: String
    let kind: Kind

    static func parse(_ text: String) -> [DiffLine] {
        text.components(separatedBy: "\n").enumerated().map { index, raw in
            DiffLine(id: index, content: raw, kind: classify(raw))
        }
    }

    /// Order matters: `+++`/`---` are file headers, not add/remove lines, so they have to be
    /// tested before the single-character prefixes.
    private static func classify(_ line: String) -> Kind {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .fileHeader }
        if line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("similarity index") || line.hasPrefix("rename ")
            || line.hasPrefix("Binary files") { return .fileHeader }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}
