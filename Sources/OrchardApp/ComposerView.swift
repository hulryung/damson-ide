import SwiftUI
import OrchardCore

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
    @FocusState private var nameFocused: Bool

    private var engines: [EngineOption] { EngineOption.all }

    /// Repo default first (often `origin/main`, not a local branch), then locals.
    private var branches: [String] {
        ComposerPlanning.seedBaseRefs(
            resolvedDefault: project.worktrees.baseRef,
            localBranches: project.worktrees.availableBaseRefs())
    }

    private var plannedNames: [String] {
        ComposerPlanning.fanOutNames(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? project.worktrees.suggestedName() : name,
            count: max(count, 1),
            taken: project.worktrees.takenNames)
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
                Button(count == 1 ? "Create" : "Create \(count)") { create() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 500)
        .frame(maxHeight: 640)
        .onAppear {
            name = project.worktrees.suggestedName()
            baseRef = project.worktrees.baseRef
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
        do {
            try store.compose(
                project: project,
                name: trimmedName,
                prompt: trimmedPrompt,
                engineID: engineID,
                baseRef: baseRef.isEmpty ? nil : baseRef,
                count: count,
                workspaceStatus: workspaceStatus)
            dismiss()
        } catch {
            errorMessage = String(describing: error)
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

    private var preflight: WorktreeDeletionPreflight {
        project.worktrees.deletionPreflight(record)
    }

    var body: some View {
        let flight = preflight
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: flight.isSafe ? "trash" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(flight.isSafe ? Tokens.textSecondary : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete “\(record.title)”?")
                        .font(.system(size: 13, weight: .semibold))
                    Text(record.branch)
                        .font(Tokens.fontMono)
                        .foregroundStyle(Tokens.textSecondary)
                }
            }

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

            if let errorMessage {
                Text(errorMessage)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { performDelete(force: !flight.isSafe) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { deleteBranch = store.settings.deleteBranchWithWorktree }
    }

    private func performDelete(force: Bool) {
        do {
            let removed = try store.deleteWorktree(
                record, in: project, force: force, deleteBranch: deleteBranch,
                forceBranch: forceBranch && deleteBranch)
            if !removed {
                errorMessage = "This worktree has uncommitted changes. Press Delete again to discard them."
                return
            }
            dismiss()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
