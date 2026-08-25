import SwiftUI
import OrchardRuntime

/// Create/edit sheet: trigger builder, target picker, provider, prompt, precheck.
struct AutomationEditorSheet: View {
    let mode: AutomationEditorMode
    let repos: [RepoRecord]
    let workspaces: [Workspace]
    let defaultProvider: String
    let onSave: (Automation) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var trigger: AutomationTrigger = .daily
    @State private var time = "09:00"
    @State private var day = 1
    @State private var cron = "0 9 * * 1-5"
    @State private var onceAt = ""
    @State private var targetKind: TargetKind = .repo
    @State private var repoSelector = ""
    @State private var workspaceSelector = ""
    @State private var provider = ""
    @State private var prompt = ""
    @State private var precheck = ""
    @State private var timeout = 30
    @State private var enabled = true
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private enum TargetKind: String, CaseIterable, Identifiable {
        case repo, workspace
        var id: String { rawValue }
        var label: String {
            switch self {
            case .repo: return "Repo (fresh worktree)"
            case .workspace: return "Workspace (reuse session)"
            }
        }
    }

    private var engines: [EngineOption] { EngineOption.all }

    private var scheduleTime: String {
        switch trigger {
        case .cron: return cron
        case .once: return onceAt
        default: return time
        }
    }

    /// Default for a fresh Once schedule: five minutes out, to the minute, UTC.
    private static func defaultOnceAt(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let slot = AutomationSchedule.minute(of: now.addingTimeInterval(300)) ?? now
        return formatter.string(from: slot)
    }

    private var scheduleDay: Int? { trigger == .weekly ? day : nil }

    private var selectedTarget: AutomationTarget? {
        switch targetKind {
        case .repo:
            let value = repoSelector.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : .repo(value)
        case .workspace:
            let value = workspaceSelector.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : .workspace(value)
        }
    }

    private var validation: AutomationDraftValidation {
        AutomationProjection.validateDraft(
            name: name, trigger: trigger, time: scheduleTime, day: scheduleDay,
            provider: provider, prompt: prompt, hasTarget: selectedTarget != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name") {
                        TextField("Nightly review", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                    }
                    Toggle("Enabled", isOn: $enabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    triggerBuilder
                    targetPicker
                    field("Provider") {
                        Picker("", selection: $provider) {
                            ForEach(engines) { engine in
                                Text(engine.displayName).tag(engine.id)
                            }
                            if !engines.contains(where: { $0.id == provider }) && !provider.isEmpty {
                                Text(provider).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    field("Prompt") {
                        TextEditor(text: $prompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 120)
                            .padding(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: Tokens.radius)
                                    .strokeBorder(Tokens.border)
                            )
                    }
                    field("Precheck command") {
                        TextField("optional shell command", text: $precheck)
                            .textFieldStyle(.roundedBorder)
                            .font(Tokens.fontMono)
                        Text(AutomationProjection.precheckSkipExplanation)
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Stepper(value: $timeout, in: 1...300) {
                            HStack {
                                Text("Timeout")
                                Spacer()
                                Text("\(timeout)s")
                                    .monospacedDigit()
                                    .foregroundStyle(Tokens.textSecondary)
                            }
                            .font(Tokens.fontMeta)
                        }
                    }
                    if !validation.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(validation.messages, id: \.self) { message in
                                Text(message)
                                    .font(Tokens.fontMeta)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(Tokens.fontMeta)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(mode.existing == nil ? "Create" : "Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.isValid)
            }
            .padding(14)
        }
        .frame(width: 560)
        .frame(maxHeight: 720)
        .onAppear { seed() }
        .onChange(of: trigger) { next in
            if next == .cron, cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cron = "0 9 * * 1-5"
            }
            if next == .once, onceAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onceAt = Self.defaultOnceAt()
            }
            if next != .cron && next != .once {
                let parts = time.split(separator: ":")
                if parts.count != 2 { time = "09:00" }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.2.circlepath")
                .foregroundStyle(Tokens.textSecondary)
            Text(mode.existing == nil ? "New Automation" : "Edit Automation")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var triggerBuilder: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Trigger") {
                Picker("", selection: $trigger) {
                    Text("Hourly").tag(AutomationTrigger.hourly)
                    Text("Daily").tag(AutomationTrigger.daily)
                    Text("Weekdays").tag(AutomationTrigger.weekdays)
                    Text("Weekly").tag(AutomationTrigger.weekly)
                    Text("Once").tag(AutomationTrigger.once)
                    Text("Cron").tag(AutomationTrigger.cron)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if trigger == .once {
                field("Fire at (ISO-8601 UTC, HH:mm, or now)") {
                    TextField("2026-01-01T09:00:00Z", text: $onceAt)
                        .textFieldStyle(.roundedBorder)
                        .font(Tokens.fontMono)
                    Text("Fires a single time, then the automation disables itself.")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                }
            } else if trigger == .cron {
                field("Cron (five fields)") {
                    TextField("0 9 * * 1-5", text: $cron)
                        .textFieldStyle(.roundedBorder)
                        .font(Tokens.fontMono)
                    Text("UTC. Minute hour day-of-month month weekday (0 = Sunday).")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                }
            } else {
                field(trigger == .hourly ? "Minute (HH:mm, hour ignored)" : "Time (HH:mm UTC)") {
                    TextField("09:00", text: $time)
                        .textFieldStyle(.roundedBorder)
                        .font(Tokens.fontMono)
                }
            }
            if trigger == .weekly {
                field("Weekday") {
                    Picker("", selection: $day) {
                        ForEach(0..<7, id: \.self) { value in
                            Text(AutomationProjection.weekdayNames[value]).tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            if !validation.nextFireLabels.isEmpty {
                field("Next 3 fires") {
                    ForEach(Array(validation.nextFireLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(Tokens.fontMono)
                            .foregroundStyle(Tokens.textSecondary)
                    }
                }
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Target") {
                Picker("", selection: $targetKind) {
                    ForEach(TargetKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Text("A repo target creates a fresh top-level worktree and starts the agent. A workspace target sends the prompt to that workspace's existing agent of the same provider.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if targetKind == .repo {
                field("Repository") {
                    if repos.isEmpty {
                        Text("No repositories registered. Open a project first.")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                    } else {
                        Picker("", selection: $repoSelector) {
                            ForEach(repos) { repo in
                                Text(repo.displayName).tag(repo.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            } else {
                field("Workspace") {
                    if workspaces.isEmpty {
                        Text("No workspaces available.")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                    } else {
                        Picker("", selection: $workspaceSelector) {
                            ForEach(workspaces) { workspace in
                                Text(workspacePickerLabel(workspace)).tag(workspace.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
        }
    }

    private func workspacePickerLabel(_ workspace: Workspace) -> String {
        let branch = workspace.branch.isEmpty ? "folder" : workspace.branch
        return "\(workspace.displayName) · \(branch)"
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            content()
        }
    }

    private func seed() {
        if let existing = mode.existing {
            name = existing.name
            trigger = existing.trigger
            switch existing.trigger {
            case .cron:
                cron = existing.time
                time = "09:00"
            case .once:
                onceAt = existing.time
                time = "09:00"
            default:
                time = existing.time
            }
            day = existing.day ?? 1
            switch existing.target {
            case .repo(let selector):
                targetKind = .repo
                repoSelector = selector
            case .workspace(let selector):
                targetKind = .workspace
                workspaceSelector = selector
            }
            provider = existing.provider
            prompt = existing.prompt
            precheck = existing.precheck ?? ""
            timeout = existing.precheckTimeoutSeconds
            enabled = existing.enabled
        } else {
            provider = engines.contains(where: { $0.id == defaultProvider })
                ? defaultProvider
                : (engines.first?.id ?? defaultProvider)
            repoSelector = repos.first?.id ?? ""
            workspaceSelector = workspaces.first?.id ?? ""
        }
        nameFocused = true
    }

    private func save() async {
        guard validation.isValid, let target = selectedTarget else { return }
        let existing = mode.existing
        let item = Automation(
            id: existing?.id ?? "auto_" + UUID().uuidString.lowercased(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: trigger,
            time: scheduleTime.trimmingCharacters(in: .whitespacesAndNewlines),
            day: scheduleDay,
            provider: provider,
            prompt: prompt,
            target: target,
            precheck: {
                let trimmed = precheck.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }(),
            precheckTimeoutSeconds: timeout,
            enabled: enabled,
            createdAt: existing?.createdAt ?? Date())
        if let error = await onSave(item) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}
