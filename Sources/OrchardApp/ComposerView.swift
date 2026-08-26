import SwiftUI
import OrchardCore
import OrchardRuntime

/// ⌘N — name, prompt, live-registry engine, base branch, fan-out, initial status.
struct ComposerView: View {
    @ObservedObject var project: ProjectSession
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var engineID: String = ""
    @State private var baseRef = ""
    @State private var count = 1
    @State private var workspaceStatus = WorkspaceStatus.inProgress.rawValue
    @State private var errorMessage: String?
    @State private var isCreating = false
    @FocusState private var nameFocused: Bool

    private var engines: [EngineOption] { EngineOption.all }

    /// Repo default first (often `origin/main`, not a local branch), then locals.
    /// Remote repos have no local `for-each-ref`; seed the registry default.
    private var branches: [String] {
        if project.isRemote {
            return ComposerPlanning.seedBaseRefs(
                resolvedDefault: store.remoteComposerBaseRef(for: project),
                localBranches: [])
        }
        return ComposerPlanning.seedBaseRefs(
            resolvedDefault: project.worktrees.baseRef,
            localBranches: project.worktrees.availableBaseRefs())
    }

    private var plannedNames: [String] {
        ComposerPlanning.fanOutNames(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? project.composerSuggestedName() : name,
            count: max(count, 1),
            taken: project.composerTakenNames)
    }

    private var branchPreview: String {
        let leaf = plannedNames.first ?? project.worktrees.suggestedName()
        return WorktreeNaming.branchName(prefix: project.worktrees.branchPrefix, name: leaf)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.folder")
                    .foregroundStyle(Tokens.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New Worktree")
                        .font(.system(size: 13, weight: .semibold))
                    Text(project.name)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                }
                HostChip(hostId: project.hostId)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name") {
                        TextField("fix-parser", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                        Text(branchPreview)
                            .font(Tokens.fontMono)
                            .foregroundStyle(Tokens.textTertiary)
                            .lineLimit(1)
                    }
                    field("Prompt") {
                        TextEditor(text: $prompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 110)
                            .padding(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: Tokens.radius)
                                    .strokeBorder(Tokens.border)
                            )
                        Text("Left empty, the agent starts in the worktree and waits.")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    field("Engine") {
                        // Live registry, one row per canonical id. Aliases appear
                        // in the label once (`claude (claude-code)`), never as a
                        // second choice that would drift from what spawn accepts.
                        Picker("", selection: $engineID) {
                            ForEach(engines) { item in
                                Text(item.displayName).tag(item.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("composer-engine")
                        if project.isRemote {
                            Text("Starts on \(RemoteWorkspacePolicy.hostLabel(project.hostId)) through `terminal create --engine`, the same runtime verb as the CLI.")
                                .font(Tokens.fontMeta)
                                .foregroundStyle(Tokens.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    field("Base branch") {
                        Picker("", selection: $baseRef) {
                            ForEach(branches, id: \.self) { Text($0).tag($0) }
                            if !baseRef.isEmpty, !branches.contains(baseRef) {
                                Text(baseRef).tag(baseRef)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    field("Status") {
                        Picker("", selection: $workspaceStatus) {
                            ForEach(store.statusVocabulary) { status in
                                Text(status.label).tag(status.id)
                            }
                            if store.statusVocabulary.contains(where: { $0.id == workspaceStatus }) == false {
                                Text(workspaceStatus).tag(workspaceStatus)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    field("Fan-out") {
                        Stepper(value: $count, in: ComposerPlanning.fanOutRange) {
                            Text(count == 1 ? "1 worktree" : "\(count) worktrees")
                                .font(Tokens.fontMeta)
                                .monospacedDigit()
                        }
                        .help("N independent worktrees, same prompt, all start now")
                        if count > 1 {
                            Text(plannedNames.joined(separator: ", "))
                                .font(Tokens.fontMono)
                                .foregroundStyle(Tokens.textTertiary)
                                .lineLimit(2)
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreating
                       ? "Starting…"
                       : (count == 1 ? "Create" : "Create \(count)")) { create() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 500)
        .frame(maxHeight: 640)
        .onAppear {
            name = project.composerSuggestedName()
            baseRef = project.isRemote
                ? store.remoteComposerBaseRef(for: project)
                : project.worktrees.baseRef
            engineID = store.settings.resolvedDefaultEngineID
            if store.statusVocabulary.contains(where: { $0.id == workspaceStatus }) == false {
                workspaceStatus = store.statusVocabulary.first?.id
                    ?? WorkspaceStatus.inProgress.rawValue
            }
            nameFocused = true
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            content()
        }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = ComposerPlanning.validationError(name: trimmedName, count: count) {
            errorMessage = error
            return
        }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                try await store.compose(
                    project: project,
                    name: trimmedName,
                    prompt: trimmedPrompt,
                    engineID: engineID,
                    baseRef: baseRef.isEmpty ? nil : baseRef,
                    count: count,
                    workspaceStatus: workspaceStatus)
                dismiss()
            } catch {
                errorMessage = RemoteAgentStart.describe(error)
            }
        }
    }
}

struct DeleteWorktreeSheet: View {
    @ObservedObject var project: ProjectSession
    @ObservedObject var record: WorktreeRecord
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var deleteBranch = false
    @State private var forceBranch = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?

    private var preflight: WorktreeDeletionPreflight {
        project.worktrees.deletionPreflight(record)
    }

    var body: some View {
        let flight = preflight
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: resultMessage != nil
                      ? "checkmark.circle.fill"
                      : (flight.isSafe ? "trash" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 20))
                    .foregroundStyle(resultMessage != nil
                                     ? .green
                                     : (flight.isSafe ? Tokens.textSecondary : .orange))
                VStack(alignment: .leading, spacing: 2) {
                    Text(resultMessage != nil ? "Deleted “\(record.title)”" : "Delete “\(record.title)”?")
                        .font(.system(size: 13, weight: .semibold))
                    Text(record.branch)
                        .font(Tokens.fontMono)
                        .foregroundStyle(Tokens.textSecondary)
                }
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if flight.warnings.isEmpty {
                    Text("This worktree has no changes — nothing will be lost.")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(flight.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.circle.fill")
                                .font(Tokens.fontMeta)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radius)
                            .fill(Color.orange.opacity(0.1))
                    )
                }

                Text(flight.branchStatusMessage)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(flight.branchMerged ? Tokens.textSecondary : .orange)

                Toggle("Also delete the branch", isOn: $deleteBranch)
                    .font(Tokens.fontMeta)

                if deleteBranch && !flight.branchMerged {
                    Toggle("Force delete unmerged branch", isOn: $forceBranch)
                        .font(Tokens.fontMeta)
                }

                Text(WorktreeDeleteFormatter.predictedOutcome(
                    preflight: flight,
                    deleteBranch: deleteBranch,
                    forceBranch: forceBranch && deleteBranch))
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if resultMessage != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete", role: .destructive) { performDelete(force: !flight.isSafe) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { deleteBranch = store.settings.deleteBranchWithWorktree }
    }

    private func performDelete(force: Bool) {
        do {
            let deletion = try store.deleteWorktree(
                record, in: project, force: force, deleteBranch: deleteBranch,
                forceBranch: forceBranch && deleteBranch)
            if !deletion.removed {
                errorMessage = "This worktree has uncommitted changes. Press Delete again to discard them."
                return
            }
            resultMessage = WorktreeDeleteFormatter.resultMessage(
                branch: deletion.branch.isEmpty ? record.branch : deletion.branch,
                removed: deletion.removed,
                branchDeleted: deletion.branchDeleted)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
