import SwiftUI
import OrchardCore

/// ⌘N — name, prompt, engine (claude|codex|grok|cursor|shell), base branch, fan-out.
struct ComposerView: View {
    @ObservedObject var project: ProjectSession
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var engine: ComposerEngine = .claude
    @State private var baseRef = ""
    @State private var count = 1
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var branches: [String] { project.worktrees.availableBaseRefs() }

    private var branchPreview: String {
        let leaf = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? project.worktrees.suggestedName() : name
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
                        Picker("", selection: $engine) {
                            ForEach(ComposerEngine.allCases) { item in
                                Text(item.isRegistered ? item.displayName : "\(item.displayName) (unavailable)")
                                    .tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    field("Base branch") {
                        Picker("", selection: $baseRef) {
                            ForEach(branches, id: \.self) { Text($0).tag($0) }
                            if !branches.contains(baseRef) {
                                Text(baseRef).tag(baseRef)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
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
        .frame(width: 500)
        .frame(maxHeight: 640)
        .onAppear {
            name = project.worktrees.suggestedName()
            baseRef = project.worktrees.baseRef
            engine = ComposerEngine.from(storedDefault: store.settings.defaultEngineID)
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
        guard WorktreeNaming.isValid(trimmedName) else {
            errorMessage = "Give this worktree a name that contains at least one letter or number."
            return
        }
        do {
            try store.compose(
                project: project,
                name: trimmedName,
                prompt: trimmedPrompt,
                engine: engine,
                baseRef: baseRef.isEmpty ? nil : baseRef,
                count: count)
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

            Toggle("Also delete the branch", isOn: $deleteBranch)
                .font(Tokens.fontMeta)

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
                record, in: project, force: force, deleteBranch: deleteBranch)
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
