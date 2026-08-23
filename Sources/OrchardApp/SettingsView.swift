import SwiftUI
import AppKit
import DamsonTerminal
import OrchardCore
import OrchardRuntime

/// Preferences (⌘,), in the three groups v1 actually decided in.
struct SettingsView: View {
    @ObservedObject var settings: OrchardSettings
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            WorktreeSettingsTab(settings: settings)
                .tabItem { Label("Worktrees", systemImage: "arrow.triangle.branch") }
            TerminalSettingsTab(settings: settings)
                .tabItem { Label("Terminal", systemImage: "terminal") }
            ServicesSettingsTab(settings: settings)
                .tabItem { Label("Services", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 520, height: 560)
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var settings: OrchardSettings

    var body: some View {
        Form {
            Section {
                Picker("Default agent", selection: Binding(
                    get: { settings.resolvedDefaultEngineID },
                    set: { settings.defaultEngineID = $0 })) {
                    ForEach(EngineOption.all) { engine in
                        Text(engine.displayName).tag(engine.id)
                    }
                }
                .help("Pre-selected in the new-worktree composer")

                Stepper(value: $settings.maxConcurrency, in: 1...12) {
                    HStack {
                        Text("Agents at once")
                        Spacer()
                        Text("\(settings.maxConcurrency)")
                            .monospacedDigit()
                            .foregroundStyle(Tokens.textSecondary)
                    }
                }
                SettingsFootnote("Display only — v2 has no scheduler. Coordinators drive the loop through the CLI.")
            }

            Section("Notifications") {
                Toggle("Notify when an agent needs attention", isOn: $settings.notificationsEnabled)
                Toggle("Only when blocked on approval or input", isOn: $settings.notifyOnlyWhenBlocked)
                    .disabled(!settings.notificationsEnabled)
                SettingsFootnote("Notifications are only posted for worktrees you aren't currently looking at.")
            }
        }
        .formStyle(.grouped)
    }
}

struct WorktreeSettingsTab: View {
    @ObservedObject var settings: OrchardSettings
    @EnvironmentObject var store: AppStore

    private var branchPreview: String {
        let prefix = settings.branchPrefixOverride.trimmingCharacters(in: .whitespaces)
        let effective = prefix.isEmpty
            ? (store.selectedProject?.worktrees.branchPrefix ?? "orchard")
            : WorktreeNaming.sanitize(prefix)
        return WorktreeNaming.branchName(prefix: effective, name: "fix-parser")
    }

    var body: some View {
        Form {
            Section("Location") {
                HStack(spacing: 6) {
                    TextField(settings.defaultWorktreeRootDisplay, text: $settings.worktreeRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseRoot() }
                }
                SettingsFootnote(
                    "Each project gets a subdirectory here. Keep it outside your checkouts.",
                    scope: .reopenProject)
            }

            Section("Naming") {
                TextField("From git user.name", text: $settings.branchPrefixOverride)
                    .textFieldStyle(.roundedBorder)
                LabeledContent("New branches look like") {
                    Text(branchPreview)
                        .font(Tokens.fontMono)
                        .foregroundStyle(Tokens.textSecondary)
                }
                TextField("Probe origin/main, main, master…", text: $settings.defaultBaseRefOverride)
                    .textFieldStyle(.roundedBorder)
                SettingsFootnote(
                    "Base branch new worktrees fork from. Leave empty to detect it per project.",
                    scope: .newWorktrees)
            }

            Section("On create / delete") {
                Toggle("Run the project's orchard.yaml setup script", isOn: $settings.runSetupScripts)
                Toggle("Offer to delete the branch too", isOn: $settings.deleteBranchWithWorktree)
                SettingsFootnote("A branch is the only way back once a worktree is gone, so this only presets the checkbox.")
            }

            WorkspaceStatusVocabularyEditor()
        }
        .formStyle(.grouped)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where Orchard should create worktrees."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.worktreeRoot = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Custom board columns beyond the four defaults. Persisted in the runtime
/// workspace-status vocabulary (`orchard-data.json`), same store the sidebar
/// and dashboard slots read.
struct WorkspaceStatusVocabularyEditor: View {
    @EnvironmentObject var store: AppStore
    @State private var newLabel = ""
    @State private var newColor = "amber"
    @State private var errorMessage: String?

    var body: some View {
        Section("Board statuses") {
            ForEach(store.statusVocabulary) { definition in
                HStack(spacing: 8) {
                    WorkspaceStatusSlot(definition: definition)
                    Text(definition.label)
                    Spacer()
                    if WorkspaceStatusDefinition.defaultIDs.contains(definition.id) {
                        Text("Default")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                    } else {
                        Text(definition.color ?? "")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                    }
                }
            }
            HStack {
                TextField("New column", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                Picker("Color", selection: $newColor) {
                    ForEach(WorkspaceStatusAppearance.colorTokens, id: \.self) { token in
                        Text(token.capitalized).tag(token)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button("Add") { add() }
                    .disabled(newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.red)
            }
            SettingsFootnote("Custom columns appear on workspace cards and the dashboard. Defaults cannot be removed.")
        }
    }

    private func add() {
        do {
            try store.addWorkspaceStatus(label: newLabel, color: newColor)
            newLabel = ""
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

struct ServicesSettingsTab: View {
    @ObservedObject var settings: OrchardSettings
    @EnvironmentObject var store: AppStore
    @State private var profiles: [BrowserProfile] = [BrowserProfile.defaultProfile]

    var body: some View {
        Form {
            Section("Ports") {
                Stepper(value: portsInterval, in: PortService.minimumInterval...PortService.maximumInterval, step: 1) {
                    HStack {
                        Text("Sweep interval")
                        Spacer()
                        Text("\(Int(settings.portsSweepInterval.rounded()))s")
                            .monospacedDigit()
                            .foregroundStyle(Tokens.textSecondary)
                    }
                }
                SettingsFootnote(
                    "How often Orchard attributes listening TCP ports to open workspaces. Applied to the live sweep.")
            }

            Section("Browser") {
                Picker("Default profile", selection: $settings.defaultBrowserProfileID) {
                    ForEach(profiles) { profile in
                        Text(profile.label).tag(profile.id)
                    }
                    if !profiles.contains(where: { $0.id == settings.defaultBrowserProfileID }) {
                        Text(settings.defaultBrowserProfileID).tag(settings.defaultBrowserProfileID)
                    }
                }
                SettingsFootnote(
                    "Used for new browser tabs in a workspace that has no profile binding yet.")
            }

            Section("Automations") {
                Toggle("Enable scheduled automations", isOn: $settings.automationsEnabled)
                SettingsFootnote(
                    "Master switch for the in-process scheduler. Individual automations stay in orchard-data.json.")
            }
        }
        .formStyle(.grouped)
        .task { await loadProfiles() }
    }

    private var portsInterval: Binding<Double> {
        Binding(
            get: { settings.portsSweepInterval },
            set: { settings.portsSweepInterval = PortService.clamp($0) })
    }

    private func loadProfiles() async {
        guard let service = store.runtime?.browserService else { return }
        profiles = await service.listProfiles()
        if !profiles.contains(where: { $0.id == settings.defaultBrowserProfileID }) {
            settings.defaultBrowserProfileID = BrowserProfile.defaultProfile.id
        }
    }
}

struct TerminalSettingsTab: View {
    @ObservedObject var settings: OrchardSettings
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $settings.themeName) {
                    ForEach(DamsonTheme.presets, id: \.name) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                Picker("Font", selection: $settings.fontFamily) {
                    if !families.contains(settings.fontFamily) {
                        Text(settings.fontFamily).tag(settings.fontFamily)
                    }
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Size")
                    Slider(value: $settings.fontSize, in: 9...24, step: 0.5)
                    Text(String(format: "%.1f", settings.fontSize))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                        .foregroundStyle(Tokens.textSecondary)
                }
                SettingsFootnote("Applies to every agent and shell terminal, including ones already open.")
            }

            Section("Preview") {
                TerminalPreview(theme: settings.theme,
                                fontFamily: settings.fontFamily,
                                fontSize: settings.fontSize)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if families.isEmpty { families = OrchardSettings.monospacedFamilies() }
        }
    }
}

struct TerminalPreview: View {
    let theme: DamsonTheme
    let fontFamily: String
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            line("$ swift build", color: theme.swiftForeground)
            line("● Compiling OrchardCore", color: Color(nsColor: theme.paletteColor(4)))
            line("✓ Build complete!", color: Color(nsColor: theme.paletteColor(2)))
            line("⚠ 2 warnings", color: Color(nsColor: theme.paletteColor(3)))
            line("✗ error: cannot find 'Foo' in scope", color: Color(nsColor: theme.paletteColor(1)))
        }
        .font(.custom(fontFamily, size: CGFloat(fontSize)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(theme.swiftBackground)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radius)
                .strokeBorder(Tokens.border)
        )
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text).foregroundStyle(color).lineLimit(1)
    }
}

struct SettingsFootnote: View {
    let text: String
    var scope: OrchardSettings.Scope = .immediate

    init(_ text: String, scope: OrchardSettings.Scope = .immediate) {
        self.text = text
        self.scope = scope
    }

    private var scopeNote: String? {
        switch scope {
        case .immediate: return nil
        case .newWorktrees: return "Applies to new worktrees."
        case .reopenProject: return "Applies to worktrees created after reopening the project."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
            if let scopeNote { Text(scopeNote).italic() }
        }
        .font(Tokens.fontMeta)
        .foregroundStyle(Tokens.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
