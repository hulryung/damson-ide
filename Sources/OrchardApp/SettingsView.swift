import SwiftUI
import AppKit
import DamsonTerminal
import OrchardCore

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
        }
        .frame(width: 520, height: 400)
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var settings: OrchardSettings

    var body: some View {
        Form {
            Section {
                Picker("Default agent", selection: $settings.defaultEngineID) {
                    ForEach(ComposerEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine.rawValue)
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
