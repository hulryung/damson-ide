import SwiftUI
import OrchardCore
import OrchardRuntime

/// Right-sidebar source-control section for the selected workspace (T70).
///
/// Git lives in `GitSourceControlService`. This view only renders a snapshot
/// and routes clicks; every refusal is the service's typed code, shown inline.
struct SourceControlSidebar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            if let key = store.selection,
               store.unsupportedReason(RemoteAffordance.fileExplorer, for: key) != nil {
                RemoteUnsupportedView(affordance: .fileExplorer,
                                      hostId: store.executionHostId(for: key))
            } else if let key = store.selection, let root = store.workspaceRoot(for: key) {
                SourceControlPane(root: root, workspaceKey: key)
                    .id(root.path)
            } else {
                empty
            }
        }
        .background(Tokens.sidebar)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("No worktree selected")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class SourceControlModel: ObservableObject {
    @Published private(set) var snapshot = GitSourceControlSnapshot.empty
    @Published var commitMessage = ""
    @Published var newBranchName = ""
    @Published private(set) var isBusy = false
    @Published var errorText: String?

    private let service = GitSourceControlService()

    func refresh(root: URL) async {
        let service = self.service
        do {
            let snap = try await Task.detached(priority: .utility) {
                try service.snapshot(worktree: root)
            }.value
            snapshot = snap
            // A successful reload clears a stale refusal; a new action will
            // write its own error if it fails.
            errorText = nil
        } catch let error as GitSourceControlError {
            snapshot = .empty
            errorText = error.displayText
        } catch {
            snapshot = .empty
            errorText = GitSourceControlError.gitFailed(error.localizedDescription).displayText
        }
    }

    func stage(_ path: String, root: URL) async { await mutate(root: root) { try $0.stage(worktree: root, path: path) } }
    func unstage(_ path: String, root: URL) async { await mutate(root: root) { try $0.unstage(worktree: root, path: path) } }
    func stageAll(root: URL) async { await mutate(root: root) { try $0.stageAll(worktree: root) } }
    func unstageAll(root: URL) async { await mutate(root: root) { try $0.unstageAll(worktree: root) } }

    func commit(root: URL) async {
        let message = commitMessage
        await mutate(root: root) { service in
            _ = try service.commit(worktree: root, message: message)
        }
        if errorText == nil { commitMessage = "" }
    }

    func switchBranch(_ name: String, root: URL) async {
        await mutate(root: root) { try $0.switchBranch(worktree: root, name: name) }
    }

    func createBranch(root: URL) async {
        let name = newBranchName
        await mutate(root: root) { try $0.createBranch(worktree: root, name: name) }
        if errorText == nil { newBranchName = "" }
    }

    func push(root: URL) async { await mutate(root: root) { try $0.push(worktree: root) } }
    func pull(root: URL) async { await mutate(root: root) { try $0.pull(worktree: root) } }

    private func mutate(root: URL, _ body: @escaping (GitSourceControlService) throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        let service = self.service
        do {
            try await Task.detached(priority: .userInitiated) {
                try body(service)
            }.value
            await refresh(root: root)
        } catch let error as GitSourceControlError {
            errorText = error.displayText
        } catch {
            errorText = GitSourceControlError.gitFailed(error.localizedDescription).displayText
        }
        isBusy = false
    }
}

private struct SourceControlPane: View {
    let root: URL
    let workspaceKey: WorkbenchKey

    @EnvironmentObject var store: AppStore
    @StateObject private var model = SourceControlModel()
    @FocusState private var commitFocused: Bool
    @State private var showingCreateBranch = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let errorText = model.errorText {
                Text(errorText)
                    .font(Tokens.fontMono)
                    .foregroundStyle(Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    branchBlock
                    changeSection(title: "Staged",
                                  files: model.snapshot.staged,
                                  empty: "No staged changes",
                                  stageAllTitle: nil,
                                  unstageAll: true)
                    changeSection(title: "Changes",
                                  files: model.snapshot.unstaged,
                                  empty: "No unstaged changes",
                                  stageAllTitle: "Stage All",
                                  unstageAll: false)
                }
                .padding(.vertical, 8)
            }
            Divider()
            footer
        }
        .task(id: root.path) { await reload() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Source Control")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            Spacer(minLength: 4)
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(model.isBusy)
            .help("Re-read git status")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var branchBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
                    .frame(width: 14)
                Menu {
                    ForEach(model.snapshot.branches, id: \.self) { name in
                        Button(name) {
                            Task { await switchBranch(name) }
                        }
                        .disabled(name == model.snapshot.branch || model.isBusy)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.snapshot.branch.isEmpty ? "—" : model.snapshot.branch)
                            .font(Tokens.fontRow)
                            .foregroundStyle(Tokens.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(model.isBusy || model.snapshot.branches.isEmpty)
                .help("Switch branch")
                Spacer(minLength: 4)
                Button {
                    showingCreateBranch.toggle()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.isBusy)
                .help("Create branch")
            }
            if showingCreateBranch {
                HStack(spacing: 6) {
                    TextField("New branch", text: $model.newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .font(Tokens.fontMeta)
                        .disabled(model.isBusy)
                    Button("Create") {
                        Task { await createBranch() }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("Create and switch to this branch")
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func changeSection(title: String,
                               files: [GitSourceControlChange],
                               empty: String,
                               stageAllTitle: String?,
                               unstageAll: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Text("\(files.count)")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if let stageAllTitle, !files.isEmpty {
                    Button(stageAllTitle) {
                        Task { await run { await model.stageAll(root: root) } }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("git add -A")
                }
                if unstageAll, !files.isEmpty {
                    Button("Unstage All") {
                        Task { await run { await model.unstageAll(root: root) } }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("Unstage every path")
                }
            }
            .padding(.horizontal, 10)
            if files.isEmpty {
                Text(empty)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ForEach(files) { file in
                    SourceControlFileRow(file: file, isBusy: model.isBusy,
                                         onStage: { Task { await run { await model.stage(file.path, root: root) } } },
                                         onUnstage: { Task { await run { await model.unstage(file.path, root: root) } } },
                                         onOpen: { store.openDiff(file.path) })
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Commit message", text: $model.commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .font(Tokens.fontRow)
                    .focused($commitFocused)
                    .disabled(model.isBusy)
                    .help("Required. Refused when empty or when nothing is staged.")
                Button("Commit") {
                    Task { await run { await model.commit(root: root) } }
                }
                .controlSize(.small)
                .disabled(model.isBusy)
                .help("Commit the staged set. Empty message and empty index are typed refusals.")
            }
            if model.snapshot.hasRemote {
                HStack(spacing: 8) {
                    Text(model.snapshot.preferredRemote.map { "Remote \($0)" } ?? "Remote")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                    Spacer(minLength: 4)
                    Button("Pull") {
                        Task { await run { await model.pull(root: root) } }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("git pull")
                    Button("Push") {
                        Task { await run { await model.push(root: root) } }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("git push --set-upstream")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    private func reload() async {
        await model.refresh(root: root)
    }

    private func switchBranch(_ name: String) async {
        await run { await model.switchBranch(name, root: root) }
    }

    private func createBranch() async {
        await run { await model.createBranch(root: root) }
        if model.errorText == nil { showingCreateBranch = false }
    }

    /// Run a mutation, then refresh the workspace's review/card git status so
    /// the sidebar +/- and the diff pane stay honest.
    private func run(_ body: @escaping () async -> Void) async {
        await body()
        await store.refreshGit(for: workspaceKey)
    }
}

private struct SourceControlFileRow: View {
    let file: GitSourceControlChange
    let isBusy: Bool
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(file.kind.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(file.kind.color)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.fileName)
                    .font(Tokens.fontRow)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Tokens.text)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 2)
            if file.area == .unstaged {
                Button("Stage", action: onStage)
                    .controlSize(.mini)
                    .disabled(isBusy)
                    .help("Stage \(file.path)")
            } else {
                Button("Unstage", action: onUnstage)
                    .controlSize(.mini)
                    .disabled(isBusy)
                    .help("Unstage \(file.path)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open Diff", action: onOpen)
            if file.area == .unstaged {
                Button("Stage", action: onStage)
            } else {
                Button("Unstage", action: onUnstage)
            }
        }
    }
}
