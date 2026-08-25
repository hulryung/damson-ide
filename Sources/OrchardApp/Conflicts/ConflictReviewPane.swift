import SwiftUI
import OrchardCore

/// Center tab for a worktree that is stuck mid-merge (T68).
///
/// The tab lists every unmerged path, shows base/ours/theirs for the selected one, and
/// lets the reviewer take a side per hunk — or open the file in the editor and do it by
/// hand. Writing a fully-decided file stages it; a partly-decided one is saved with its
/// remaining markers intact and deliberately *not* staged.
///
/// What this pane will not do: finish or abandon the operation. `git commit`,
/// `rebase --continue` and `merge --abort` rewrite history, so they stay in the terminal
/// where the user types them on purpose. The header says which command is waiting.
struct ConflictReviewHost: View {
    @EnvironmentObject var store: AppStore
    let key: WorkbenchKey

    var body: some View {
        if let root = store.workspaceRoot(for: key) {
            ConflictReviewPane(key: key, root: root)
                // A different worktree is a different review: rebuild rather than carry
                // one workspace's selection into another's file list.
                .id(root.path)
        } else {
            PlaceholderPane(symbol: TabKind.conflicts.symbol,
                            title: "No workspace",
                            detail: "Select a worktree to review its merge conflicts.")
        }
    }
}

@MainActor
final class ConflictReviewModel: ObservableObject {
    @Published private(set) var summary: GitConflictSummary = .none
    @Published private(set) var selectedPath: String?
    @Published private(set) var document: GitConflictDocument?
    /// Full contents per index stage for the selected file; a stage git never wrote is
    /// simply absent, which is what the "Base" column being missing means.
    @Published private(set) var stages: [GitConflictStage: String] = [:]
    @Published var choices: [Int: GitConflictChoice] = [:]
    @Published private(set) var isBusy = false
    @Published var errorText: String?

    private let service = GitConflictService()
    /// Guards against a slow load for the file you just left overwriting the one you
    /// just picked.
    private var loadToken = UUID()

    var selectedFile: GitConflictedFile? {
        summary.files.first { $0.path == selectedPath }
    }

    var hunks: [GitConflictHunk] { document?.hunks ?? [] }

    var decidedCount: Int {
        hunks.filter { (choices[$0.index] ?? .unresolved) != .unresolved }.count
    }

    var isFullyDecided: Bool {
        !hunks.isEmpty && decidedCount == hunks.count
    }

    /// Re-read git, keeping the current selection when that file is still conflicted.
    func refresh(root: URL) async {
        let service = self.service
        let fresh = await Task.detached(priority: .utility) { service.summary(worktree: root) }.value
        summary = fresh
        let stillThere = selectedPath.map { path in fresh.files.contains { $0.path == path } } ?? false
        if let path = selectedPath, stillThere {
            await select(path, root: root)
        } else {
            clearSelection()
            if let first = fresh.files.first?.path {
                await select(first, root: root)
            }
        }
    }

    func select(_ path: String, root: URL) async {
        selectedPath = path
        choices = [:]
        let token = UUID()
        loadToken = token
        let service = self.service
        let kind = summary.files.first { $0.path == path }?.kind
        let loaded = await Task.detached(priority: .utility) { () -> (GitConflictDocument?, [GitConflictStage: String]) in
            var stages: [GitConflictStage: String] = [:]
            for stage in GitConflictStage.allCases where kind?.has(stage) ?? true {
                if let text = service.stageContents(worktree: root, path: path, stage: stage) {
                    stages[stage] = text
                }
            }
            return (service.document(worktree: root, path: path), stages)
        }.value
        guard loadToken == token else { return }
        document = loaded.0
        stages = loaded.1
    }

    private func clearSelection() {
        selectedPath = nil
        document = nil
        stages = [:]
        choices = [:]
    }

    func choose(_ choice: GitConflictChoice, for hunk: Int) {
        choices[hunk] = choice
    }

    func chooseAll(_ choice: GitConflictChoice) {
        for hunk in hunks { choices[hunk.index] = choice }
    }

    /// Write the decided hunks. Staging happens only when nothing is left undecided —
    /// `GitConflictService` enforces that, this just reports what it did.
    func apply(root: URL) async {
        guard let path = selectedPath else { return }
        // Snapshot the choices on the main actor: the write runs off it, and reading
        // @Published state from that closure is exactly the race the compiler flags.
        let decided = choices
        await mutate(root: root) { service in
            try service.resolve(worktree: root, path: path, choices: decided)
        }
    }

    /// Take one side for the whole file, including the case where that side is a delete.
    func take(_ side: GitConflictSide, root: URL) async {
        guard let path = selectedPath else { return }
        await mutate(root: root) { service in
            try service.take(side, worktree: root, path: path)
        }
    }

    /// Stage a file the user resolved in the editor. Refused while markers remain.
    func stageResolved(root: URL) async {
        guard let path = selectedPath else { return }
        await mutate(root: root) { service in
            try service.stage(worktree: root, path: path)
        }
    }

    private func mutate(root: URL, _ body: @escaping @Sendable (GitConflictService) throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        let service = self.service
        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try body(service)
                return nil
            } catch {
                return "\(error)"
            }
        }.value
        errorText = failure
        isBusy = false
        await refresh(root: root)
    }
}

struct ConflictReviewPane: View {
    let key: WorkbenchKey
    let root: URL

    @EnvironmentObject var store: AppStore
    @StateObject private var model = ConflictReviewModel()
    @State private var viewMode: ContentMode = .hunks

    private enum ContentMode: String, CaseIterable, Identifiable {
        case hunks, files
        var id: String { rawValue }
        var label: String { self == .hunks ? "Hunks" : "Whole files" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.summary.files.isEmpty {
                emptyState
            } else {
                HSplitView {
                    fileList
                        .frame(minWidth: 190, idealWidth: 240, maxWidth: 380)
                    detail
                        .frame(minWidth: 340, maxWidth: .infinity)
                }
            }
            if let error = model.errorText {
                errorBar(error)
            }
        }
        .background(Tokens.background)
        .task(id: root.path) { await reload() }
    }

    private func reload() async {
        await model.refresh(root: root)
        // Keep the tab strip's badge and the auto-opened tab in step with what this pane
        // just learned; both live on the store.
        await store.refreshConflicts(for: key)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: TabKind.conflicts.symbol)
                .foregroundStyle(model.summary.isActive ? Tokens.Git.conflicted : Tokens.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.summary.headline)
                    .font(.system(size: 13, weight: .semibold))
                if let hint = model.summary.nextStepHint {
                    Text(hint)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if model.isBusy { ProgressView().controlSize(.small).scaleEffect(0.6) }
            Button { Task { await reload() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Re-read conflicts from git")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    private var emptyState: some View {
        PlaceholderPane(
            symbol: model.summary.isActive ? "checkmark.circle" : TabKind.conflicts.symbol,
            title: model.summary.isActive ? "All conflicts resolved" : "No conflicts",
            detail: model.summary.nextStepHint
                ?? "This worktree has no unmerged files. Conflicts appear here when a merge, "
                 + "rebase, cherry-pick, or revert stops on one.")
    }

    private func errorBar(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .font(Tokens.fontMeta)
                .textSelection(.enabled)
                .lineLimit(4)
            Spacer(minLength: 4)
            Button("Dismiss") { model.errorText = nil }
                .buttonStyle(.borderless)
                .font(Tokens.fontMeta)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - File list

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.summary.fileCount) conflicted")
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            List(model.summary.files, selection: Binding(
                get: { model.selectedPath },
                set: { path in
                    guard let path else { return }
                    Task { await model.select(path, root: root) }
                })) { file in
                ConflictFileRow(file: file)
                    .tag(file.path)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await model.select(file.path, root: root) } }
            }
            .listStyle(.sidebar)
        }
        .background(Tokens.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let file = model.selectedFile {
            VStack(spacing: 0) {
                fileHeader(file)
                Divider()
                if file.kind.hasInlineMarkers, !model.hunks.isEmpty, viewMode == .hunks {
                    hunkList(file)
                } else {
                    stagePanes(file)
                }
                Divider()
                footer(file)
            }
        } else {
            PlaceholderPane(symbol: "doc.text", title: "No file selected",
                            detail: "Pick a conflicted file to review its sides.")
        }
    }

    private func fileHeader(_ file: GitConflictedFile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.system(size: 12, weight: .semibold))
                Text(file.path)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(file.kind.label)
                .font(Tokens.fontPill)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Tokens.rowHover))
            Spacer(minLength: 6)
            if file.kind.hasInlineMarkers, !model.hunks.isEmpty {
                Picker("", selection: $viewMode) {
                    ForEach(ContentMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            Button("Open in Editor") { store.openEditor(file.path) }
                .controlSize(.small)
                .help("Resolve by hand, then stage it here.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Tokens.surface)
    }

    private func hunkList(_ file: GitConflictedFile) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.hunks) { hunk in
                    ConflictHunkCard(
                        hunk: hunk,
                        operation: model.summary.operation,
                        choice: model.choices[hunk.index] ?? .unresolved,
                        onChoose: { model.choose($0, for: hunk.index) })
                }
            }
            .padding(12)
        }
    }

    /// Base / ours / theirs as whole files — the view that answers "what did each side
    /// actually have", which markers alone cannot show (git only writes the base section
    /// under diff3).
    private func stagePanes(_ file: GitConflictedFile) -> some View {
        // Only the stages git actually holds get a column: a delete/modify conflict has
        // no "theirs" file, and an empty pane labelled "Theirs" reads as "they emptied
        // it" rather than "they deleted it".
        let stages = GitConflictStage.allCases.filter { file.kind.has($0) }
        return HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                if index > 0 { Divider() }
                ConflictStagePane(
                    title: title(for: stage, operation: model.summary.operation),
                    text: model.stages[stage],
                    tint: tint(for: stage))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func title(for stage: GitConflictStage, operation: GitConflictOperation) -> String {
        switch stage {
        case .base: return "Base"
        case .ours: return operation.oursLabel
        case .theirs: return operation.theirsLabel
        }
    }

    private func tint(for stage: GitConflictStage) -> Color {
        switch stage {
        case .base: return Tokens.textTertiary
        case .ours: return Tokens.Git.hunkHeader
        case .theirs: return Tokens.Git.untracked
        }
    }

    private func footer(_ file: GitConflictedFile) -> some View {
        HStack(spacing: 8) {
            if file.kind.hasInlineMarkers, !model.hunks.isEmpty {
                Text("\(model.decidedCount) of \(model.hunks.count) hunks decided")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .monospacedDigit()
                Button("All ours") { model.chooseAll(.ours) }
                    .controlSize(.small)
                Button("All theirs") { model.chooseAll(.theirs) }
                    .controlSize(.small)
            } else {
                Text(file.kind.label)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer(minLength: 6)
            Button(file.kind.actionLabel(for: .ours).capitalizedFirst) {
                Task { await model.take(.ours, root: root) }
            }
            .controlSize(.small)
            .disabled(model.isBusy)
            Button(file.kind.actionLabel(for: .theirs).capitalizedFirst) {
                Task { await model.take(.theirs, root: root) }
            }
            .controlSize(.small)
            .disabled(model.isBusy)
            if file.kind.hasInlineMarkers, !model.hunks.isEmpty {
                Button(model.isFullyDecided ? "Stage Resolution" : "Save Progress") {
                    Task { await model.apply(root: root) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isBusy || model.decidedCount == 0)
                .help(model.isFullyDecided
                      ? "Write the chosen sides and stage the file."
                      : "Write the decided hunks. Undecided hunks keep their markers and "
                        + "the file stays unmerged.")
            } else {
                Button("Stage File") { Task { await model.stageResolved(root: root) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("Stage this path as it stands on disk. Refused while conflict "
                          + "markers remain.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Tokens.surface)
    }
}

// MARK: - Rows

struct ConflictFileRow: View {
    let file: GitConflictedFile

    var body: some View {
        HStack(spacing: 7) {
            Text(file.kind.code)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Tokens.Git.conflicted)
                .frame(width: 18)
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
            Spacer(minLength: 2)
        }
        .padding(.vertical, 2)
        .help("\(file.kind.label) — \(file.path)")
    }
}

/// One conflicted region: the two (or three) sides, and the choice for it.
struct ConflictHunkCard: View {
    let hunk: GitConflictHunk
    let operation: GitConflictOperation
    let choice: GitConflictChoice
    let onChoose: (GitConflictChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Hunk \(hunk.index + 1)")
                    .font(Tokens.fontHeader)
                Text("line \(hunk.startLine)")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .monospacedDigit()
                if choice != .unresolved {
                    Text(choice.label)
                        .font(Tokens.fontPill)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Tokens.rowSelected))
                }
                Spacer(minLength: 6)
                Picker("", selection: Binding(get: { choice }, set: onChoose)) {
                    ForEach(GitConflictChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Tokens.surface)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ConflictSideColumn(title: "\(operation.oursLabel) · \(hunk.oursLabel)",
                                   lines: hunk.ours,
                                   tint: Tokens.Git.hunkHeader,
                                   isChosen: choice == .ours || choice == .both)
                Divider()
                ConflictSideColumn(title: "\(operation.theirsLabel) · \(hunk.theirsLabel)",
                                   lines: hunk.theirs,
                                   tint: Tokens.Git.untracked,
                                   isChosen: choice == .theirs || choice == .both)
            }
            // Only present with `merge.conflictStyle = diff3`; without it the pane's
            // "Whole files" mode is where the ancestor lives.
            if let base = hunk.base {
                Divider()
                ConflictSideColumn(title: "Base · \(hunk.baseLabel ?? "common ancestor")",
                                   lines: base,
                                   tint: Tokens.textTertiary,
                                   isChosen: false)
            }
        }
        .background(Tokens.background)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .strokeBorder(choice == .unresolved ? Tokens.Git.conflicted.opacity(0.5) : Tokens.border,
                              lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusCard))
    }
}

struct ConflictSideColumn: View {
    let title: String
    let lines: [String]
    let tint: Color
    let isChosen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Tokens.fontPill)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
            if lines.isEmpty {
                Text("(empty — this side removes these lines)")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(Tokens.fontMono)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isChosen ? tint.opacity(0.12) : Color.clear)
    }
}

/// One whole index stage, read-only.
struct ConflictStagePane: View {
    let title: String
    let text: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Tokens.fontHeader)
                .foregroundStyle(tint)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.surface)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(text ?? "(this side has no version of the file)")
                    .font(Tokens.fontMono)
                    .foregroundStyle(text == nil ? Tokens.textTertiary : Tokens.text)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension String {
    /// "Keep ours" reads better than "keep ours" on a button; the model keeps git's
    /// lowercase vocabulary so it stays testable as data.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
