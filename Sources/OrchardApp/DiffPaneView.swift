import SwiftUI
import AppKit
import OrchardCore

/// File list + unified diff vs the worktree fork point.
///
/// Selection is pinned across refreshes (losing your place on every agent turn
/// makes review impossible). In-flight loads are token-guarded so a stale
/// `git diff` cannot overwrite a newer selection.
struct DiffPaneView: View {
    let worktreeURL: URL
    let baseRef: String
    let branch: String
    let stat: GitDiffStat
    let isRefreshing: Bool
    let onRefresh: () async -> Void

    @State private var selectedPath: String?
    @State private var diffText = ""
    @State private var isLoadingDiff = false
    @State private var loadToken = UUID()

    private let service = GitService()

    var body: some View {
        Group {
            if stat.isEmpty {
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
        .task(id: worktreeURL.path) { await onRefresh() }
        .onChange(of: stat) { newStat in
            if let selected = selectedPath, newStat.files.contains(where: { $0.path == selected }) {
                Task { await loadDiff(for: selected) }
            } else {
                selectFirst(in: newStat)
            }
        }
        .onAppear { if selectedPath == nil { selectFirst(in: stat) } }
    }

    private func selectFirst(in stat: GitDiffStat) {
        selectedPath = stat.files.first?.path
        if let path = selectedPath {
            Task { await loadDiff(for: path) }
        } else {
            diffText = ""
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(stat.fileCount) changed")
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer(minLength: 4)
                DiffStatBadge(stat: stat)
                Button { Task { await onRefresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isRefreshing)
                .help("Re-read the diff")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            List(selection: $selectedPath) {
                ForEach(stat.files) { file in
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

    private var diffContent: some View {
        VStack(spacing: 0) {
            if let path = selectedPath {
                HStack(spacing: 8) {
                    Text(path)
                        .font(Tokens.fontMono)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button {
                        NSWorkspace.shared.selectFile(
                            worktreeURL.appendingPathComponent(path).path,
                            inFileViewerRootedAtPath: worktreeURL.path)
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("No changes yet")
                .font(.title3)
                .foregroundStyle(Tokens.textSecondary)
            Text(branch.isEmpty
                 ? "Changes will show up here."
                 : "Changes in \(branch) will show up here.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
            Button("Refresh") { Task { await onRefresh() } }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadDiff(for path: String) async {
        let token = UUID()
        loadToken = token
        isLoadingDiff = true
        let worktree = worktreeURL
        let base = baseRef
        let service = self.service
        let text = await Task.detached(priority: .userInitiated) {
            service.diff(worktree: worktree, baseRef: base, path: path)
        }.value
        guard loadToken == token else { return }
        diffText = text
        isLoadingDiff = false
    }
}

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
