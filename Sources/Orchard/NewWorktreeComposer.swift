import SwiftUI
import DamsonOrchestrator

/// Create one or more worktrees and start an agent in each.
///
/// Replaces the old "Add Task" and "New Session" sheets, which split one decision across two
/// dialogs. There is only ever one thing being set up here — a piece of work in an isolated
/// worktree — so it's one form, with the rarely-changed parts (base branch, branch override)
/// folded behind an Advanced disclosure.
struct NewWorktreeComposer: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var engineID: String = AgentEngineRegistry.all.first?.id ?? "claude-code"
    @State private var baseRef: String = ""
    @State private var branchOverride: String = ""
    @State private var showsAdvanced = false
    /// Fan-out: run the same prompt in N independent worktrees and compare the results.
    @State private var count: Int = 1
    @State private var errorMessage: String?

    @FocusState private var nameFocused: Bool

    private var branches: [String] { workspace.controller.availableBaseRefs() }

    /// The branch that will actually be created, previewed live so the name field's effect
    /// is never a surprise.
    private var branchPreview: String {
        let leaf = branchOverride.trimmingCharacters(in: .whitespaces).isEmpty
            ? (name.trimmingCharacters(in: .whitespaces).isEmpty
               ? workspace.controller.suggestedName() : name)
            : branchOverride
        return WorktreeNaming.branchName(prefix: workspace.controller.branchPrefix, name: leaf)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameField
                    promptField
                    engineField
                    advancedDisclosure
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
            footer
        }
        .frame(width: 500)
        .frame(maxHeight: 640)
        .onAppear {
            name = workspace.controller.suggestedName()
            baseRef = workspace.controller.baseRef
            engineID = store.settings.defaultEngineID
            nameFocused = true
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.folder")
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Worktree")
                    .font(.system(size: 13, weight: .semibold))
                Text(workspace.name)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Name")
            TextField("fix-parser", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            Text(branchPreview)
                .font(Tokens.fontMono)
                .foregroundStyle(Tokens.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Prompt")
            TextEditor(text: $prompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radius)
                        .strokeBorder(Tokens.border)
                )
            Text("Left empty, the agent starts in the worktree and waits for you to type.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
        }
    }

    private var engineField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Agent")
            Picker("", selection: $engineID) {
                ForEach(AgentEngineRegistry.all, id: \.id) { engine in
                    Text(engine.displayName).tag(engine.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Base branch")
                    Picker("", selection: $baseRef) {
                        ForEach(branches, id: \.self) { Text($0).tag($0) }
                        if !branches.contains(baseRef) {
                            Text(baseRef).tag(baseRef)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Text("Each worktree forks from this, not from whatever is checked out.")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Branch name")
                    TextField("Defaults to the name above", text: $branchOverride)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Fan-out: the same prompt in N isolated worktrees, so you can compare
            // approaches instead of betting the turn on one.
            Stepper(value: $count, in: 1...8) {
                Text(count == 1 ? "1 agent" : "\(count) agents")
                    .font(Tokens.fontMeta)
                    .monospacedDigit()
            }
            .fixedSize()
            .help("Run this prompt in several independent worktrees at once")

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

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Tokens.fontHeader)
            .foregroundStyle(Tokens.textSecondary)
    }

    // MARK: - Create

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = branchOverride.trimmingCharacters(in: .whitespaces).isEmpty
            ? trimmedName : branchOverride.trimmingCharacters(in: .whitespaces)

        guard WorktreeNaming.isValid(leaf) else {
            errorMessage = "Give this worktree a name that contains at least one letter or number."
            return
        }

        // Each fan-out copy is an independent task: same prompt, its own worktree and branch,
        // uniquified by the manager's `-2`/`-3` suffix rather than by anything chosen here.
        for _ in 0..<count {
            let title = trimmedName.isEmpty
                ? String(trimmedPrompt.prefix(40))
                : trimmedName
            workspace.controller.enqueue(AgentTask(
                title: title.isEmpty ? leaf : title,
                prompt: trimmedPrompt,
                engineID: engineID,
                baseRepoPath: workspace.repo.path,
                branchHint: leaf,
                baseRef: baseRef.isEmpty ? nil : baseRef
            ))
        }
        dismiss()
    }
}

/// Confirmation for the one destructive action in the app.
///
/// It always leads with what would be lost. A worktree's whole value is the work inside it,
/// and an agent's output is frequently uncommitted — so a bare "Are you sure?" would be
/// asking the user to guess.
struct DeleteWorktreeSheet: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var record: WorktreeRecord
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var deleteBranch = false
    @State private var errorMessage: String?

    private var preflight: WorktreeDeletionPreflight {
        workspace.controller.deletionPreflight(record)
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

            Toggle("Also delete the branch", isOn: $deleteBranch)
                .font(Tokens.fontMeta)
                .help("The branch is kept by default, so commits survive even after the checkout is gone")

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
            let removed = try workspace.controller.deleteWorktree(
                record, force: force, deleteBranch: deleteBranch)
            if !removed {
                // git refused a non-force removal — the worktree turned dirty between the
                // preflight and now. Re-ask rather than silently forcing.
                errorMessage = "This worktree has uncommitted changes. Press Delete again to discard them."
                return
            }
            // A safe branch delete leaves the branch behind when it holds unmerged commits;
            // saying so is what makes the deletion recoverable.
            if deleteBranch, workspace.controller.branchStillExists(record.branch) {
                NSLog("orchard: kept branch %@ (unmerged commits)", record.branch)
            }
            dismiss()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
