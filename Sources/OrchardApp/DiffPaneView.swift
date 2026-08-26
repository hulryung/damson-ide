import SwiftUI
import AppKit
import OrchardCore

/// File list + unified diff vs the worktree fork point, plus the review actions
/// (`commitAll` / `push`) that the v1 pane documented but never called.
///
/// Selection is pinned across refreshes (losing your place on every agent turn
/// makes review impossible). In-flight loads are token-guarded so a stale
/// `git diff` cannot overwrite a newer selection. Commit and push run only on
/// an explicit click; failures surface git's own stderr inline.
struct DiffPaneView: View {
    let worktreeURL: URL
    let baseRef: String
    let branch: String
    let stat: GitDiffStat
    let hasUncommittedChanges: Bool
    let unpushedCommits: Int?
    let isRefreshing: Bool
    let onRefresh: () async -> Void

    @EnvironmentObject var store: AppStore
    @State private var selectedPath: String?
    @State private var diffText = ""
    @State private var isLoadingDiff = false
    @State private var loadToken = UUID()
    @State private var currentHunk = 0
    @State private var hunkJump: HunkJump?
    @State private var commitMessage = ""
    @State private var actionError: String?
    @State private var isMutating = false
    @State private var isHovered = false
    @FocusState private var commitFocused: Bool

    private let service = GitService()

    private var fileTree: [ReviewPathNode] { ReviewFileTree.collapsedRoots(from: stat.files) }
    private var hunkLines: [Int] { ReviewHunkIndex.lineIndices(inDiff: diffText) }
    private var upstream: ReviewUpstreamState { ReviewUpstreamState(unpushedCommits: unpushedCommits) }
    private var canCommit: Bool {
        ReviewCommitGate.canCommit(message: commitMessage,
                                   hasUncommittedChanges: hasUncommittedChanges,
                                   isBusy: isMutating || isRefreshing)
    }

    var body: some View {
        VStack(spacing: 0) {
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
            Divider()
            reviewFooter
        }
        .background(Tokens.background)
        .onHover { isHovered = $0 }
        .background(hunkKeyCapture)
        .task(id: worktreeURL.path) { await onRefresh() }
        .onChange(of: stat) { newStat in
            if let selected = selectedPath, newStat.files.contains(where: { $0.path == selected }) {
                Task { await loadDiff(for: selected) }
            } else {
                selectFirst(in: newStat)
            }
        }
        .onAppear {
            if !applyPendingOpen() && selectedPath == nil { selectFirst(in: stat) }
        }
        .onChange(of: store.pendingOpenPath) { _ in
            _ = applyPendingOpen()
        }
    }

    @ViewBuilder
    private var hunkKeyCapture: some View {
        if isHovered && !commitFocused && !stat.isEmpty {
            HunkKeyCapture(onNext: { moveHunk(1) }, onPrev: { moveHunk(-1) })
        }
    }

    @discardableResult
    private func applyPendingOpen() -> Bool {
        guard let path = store.pendingOpenPath,
              stat.files.contains(where: { $0.path == path }) else { return false }
        selectedPath = path
        Task { await loadDiff(for: path) }
        return true
    }

    private func selectFirst(in stat: GitDiffStat) {
        selectedPath = stat.files.first?.path
        if let path = selectedPath {
            Task { await loadDiff(for: path) }
        } else {
            diffText = ""
            currentHunk = 0
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
                ForEach(fileTree) { node in
                    ReviewTreeRows(node: node)
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
                    hunkChrome
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
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    if isLoadingDiff {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    } else {
                        DiffTextView(text: diffText, currentHunkLine: hunkLines.isEmpty ? nil : hunkLines[safe: currentHunk])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: hunkJump) { jump in
                    guard let jump else { return }
                    proxy.scrollTo(jump.line, anchor: .top)
                }
            }
        }
        .background(Tokens.background)
    }

    private var hunkChrome: some View {
        HStack(spacing: 4) {
            Button { moveHunk(-1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(hunkLines.isEmpty)
            .help("Previous hunk (p)")
            Text(ReviewHunkIndex.positionLabel(current: currentHunk, count: hunkLines.count))
                .font(Tokens.fontMeta)
                .monospacedDigit()
                .foregroundStyle(Tokens.textSecondary)
                .help("Hunk position — n next, p previous")
            Button { moveHunk(1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(hunkLines.isEmpty)
            .help("Next hunk (n)")
        }
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

    private var reviewFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .font(Tokens.fontRow)
                    .focused($commitFocused)
                    .disabled(isMutating)
                    .help(hasUncommittedChanges
                          ? "Required. Nothing is committed until you click Commit."
                          : "Nothing to commit — working tree is clean.")
                Button("Commit") { Task { await commit() } }
                    .controlSize(.small)
                    .disabled(!canCommit)
                    .help("git add -A && git commit. Message required.")
            }
            HStack(spacing: 8) {
                Text(upstream.help)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(upstream.buttonTitle) { Task { await push() } }
                    .controlSize(.small)
                    .disabled(!upstream.canPush || isMutating || isRefreshing)
                    .help(upstream.help)
            }
            if let actionError {
                Text(actionError)
                    .font(Tokens.fontMono)
                    .foregroundStyle(Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    private func moveHunk(_ delta: Int) {
        let lines = hunkLines
        guard !lines.isEmpty else { return }
        currentHunk = ReviewHunkIndex.move(current: currentHunk, count: lines.count, delta: delta)
        hunkJump = HunkJump(line: lines[currentHunk])
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
        currentHunk = ReviewHunkIndex.clamp(current: 0, count: ReviewHunkIndex.lineIndices(inDiff: text).count)
        hunkJump = nil
        isLoadingDiff = false
    }

    private func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ReviewCommitGate.canCommit(message: message,
                                         hasUncommittedChanges: hasUncommittedChanges,
                                         isBusy: isMutating) else { return }
        let worktree = worktreeURL
        let service = self.service
        isMutating = true
        actionError = nil
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try service.commitAll(worktree: worktree, message: message)
            }.value
            commitMessage = ""
            await onRefresh()
        } catch {
            actionError = ReviewGitFailure.displayText(error)
        }
        isMutating = false
    }

    private func push() async {
        guard upstream.canPush, !isMutating else { return }
        let worktree = worktreeURL
        let service = self.service
        isMutating = true
        actionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try service.push(worktree: worktree)
            }.value
            await onRefresh()
        } catch {
            actionError = ReviewGitFailure.displayText(error)
        }
        isMutating = false
    }
}

private struct HunkJump: Equatable {
    let line: Int
    let nonce: UUID
    init(line: Int) {
        self.line = line
        self.nonce = UUID()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Observe the worktree record so a refresh after commit/push updates the pane.
struct WorktreeDiffPane: View {
    @ObservedObject var record: WorktreeRecord

    var body: some View {
        DiffPaneView(
            worktreeURL: record.path,
            baseRef: record.worktree.baseRef.isEmpty ? "HEAD" : record.worktree.baseRef,
            branch: record.branch,
            stat: record.status.stat,
            hasUncommittedChanges: record.status.hasUncommittedChanges,
            unpushedCommits: record.status.unpushedCommits,
            isRefreshing: record.isRefreshing,
            onRefresh: { await record.refresh() })
    }
}

/// Same review pane, bound to the project's primary checkout.
struct ProjectCheckoutDiffPane: View {
    @ObservedObject var project: ProjectSession

    var body: some View {
        DiffPaneView(
            worktreeURL: project.repo,
            baseRef: "HEAD",
            branch: project.worktrees.currentBranchName ?? "",
            stat: project.checkoutStatus.stat,
            hasUncommittedChanges: project.checkoutStatus.hasUncommittedChanges,
            unpushedCommits: project.checkoutStatus.unpushedCommits,
            isRefreshing: false,
            onRefresh: { await project.refreshCheckout() })
    }
}

struct ReviewTreeRows: View {
    let node: ReviewPathNode
    @State private var expanded = true

    var body: some View {
        if let file = node.file {
            DiffFileRow(file: file)
                .tag(file.path)
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { child in
                    ReviewTreeRows(node: child)
                }
            } label: {
                ReviewFolderRow(node: node)
            }
            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        }
    }
}

struct ReviewFolderRow: View {
    let node: ReviewPathNode

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 12)
            Text(node.label)
                .font(Tokens.fontRow)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text("\(node.fileCount)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.vertical, 2)
        .help(node.path)
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
            } else if !file.linesCounted {
                // A real change whose size nobody measured. "+0" would read as "nothing
                // in it" and "bin" would read as "nothing to show", and it is neither.
                Text("—")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Tokens.textTertiary)
                    .help("Too large to count lines for.")
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
    var currentHunkLine: Int?
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
                    .background(lineBackground(line))
                    .textSelection(.enabled)
                    .id(line.id)
            }
        }
        .padding(.vertical, 6)
    }

    private func lineBackground(_ line: DiffLine) -> Color {
        if line.id == currentHunkLine {
            return Tokens.Git.hunkHeader.opacity(0.18)
        }
        return line.kind.background
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

/// n/p while the pointer is over the diff pane. macOS 13 has no `onKeyPress`;
/// the monitor is installed only while hovered and the commit field is not
/// focused so a split terminal keeps its keys.
struct HunkKeyCapture: NSViewRepresentable {
    var onNext: () -> Void
    var onPrev: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(onNext: onNext, onPrev: onPrev)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(onNext: onNext, onPrev: onPrev)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var onNext: (() -> Void)?
        private var onPrev: (() -> Void)?

        func install(onNext: @escaping () -> Void, onPrev: @escaping () -> Void) {
            self.onNext = onNext
            self.onPrev = onPrev
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting(.capsLock)
                guard mods.isEmpty else { return event }
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                switch event.charactersIgnoringModifiers {
                case "n": self.onNext?(); return nil
                case "p": self.onPrev?(); return nil
                default: return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
