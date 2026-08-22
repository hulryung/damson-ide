import AppKit
import Combine
import DamsonTerminal
import DamsonOrchestrator

/// User preferences, persisted in `UserDefaults` under Orchard's own domain.
///
/// Every value here has to actually change behavior — a settings pane full of controls that
/// only take effect on the next launch, or not at all, is worse than no settings pane. So
/// each property either feeds new work as it's created (worktree root, base ref) or pushes
/// into live objects on change (concurrency, theme, font).
@MainActor
final class OrchardSettings: ObservableObject {

    /// Where a setting takes effect, so the UI can say so honestly rather than implying
    /// everything is live.
    enum Scope { case immediate, newWorktrees, reopenProject }

    // MARK: - General

    /// Engine the composer pre-selects.
    @Published var defaultEngineID: String {
        didSet { defaults.set(defaultEngineID, forKey: Keys.defaultEngine) }
    }

    /// How many agents may run at once per project.
    @Published var maxConcurrency: Int {
        didSet {
            defaults.set(maxConcurrency, forKey: Keys.maxConcurrency)
            onConcurrencyChange?(maxConcurrency)
        }
    }

    /// Whether an agent finishing a turn or hitting an approval gate posts a notification.
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    /// Only notify for states that actually block progress, rather than every finished turn.
    @Published var notifyOnlyWhenBlocked: Bool {
        didSet { defaults.set(notifyOnlyWhenBlocked, forKey: Keys.notifyOnlyBlocked) }
    }

    // MARK: - Worktrees

    /// Parent directory for every project's worktrees. Empty means the built-in default
    /// (`~/Orchard/worktrees`); each project still gets its own subdirectory beneath it.
    @Published var worktreeRoot: String {
        didSet { defaults.set(worktreeRoot, forKey: Keys.worktreeRoot) }
    }

    /// Branch namespace. Empty means "derive from `git config user.name`", which is what
    /// makes `dkkang/fix-parser` read like a branch a person made.
    @Published var branchPrefixOverride: String {
        didSet { defaults.set(branchPrefixOverride, forKey: Keys.branchPrefix) }
    }

    /// Ref new worktrees fork from. Empty means the probed default
    /// (`origin/main` → `origin/master` → `main` → `master`).
    @Published var defaultBaseRefOverride: String {
        didSet { defaults.set(defaultBaseRefOverride, forKey: Keys.defaultBaseRef) }
    }

    /// Run the project's `orchard.yaml` setup script in each new worktree.
    @Published var runSetupScripts: Bool {
        didSet { defaults.set(runSetupScripts, forKey: Keys.runSetup) }
    }

    /// Offer to delete the branch alongside the worktree by default. Off, because a branch
    /// is the only recovery path once the checkout is gone.
    @Published var deleteBranchWithWorktree: Bool {
        didSet { defaults.set(deleteBranchWithWorktree, forKey: Keys.deleteBranch) }
    }

    // MARK: - Terminal

    @Published var themeName: String {
        didSet {
            defaults.set(themeName, forKey: Keys.theme)
            onTerminalConfigChange?()
        }
    }

    @Published var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Keys.fontSize)
            onTerminalConfigChange?()
        }
    }

    @Published var fontFamily: String {
        didSet {
            defaults.set(fontFamily, forKey: Keys.fontFamily)
            onTerminalConfigChange?()
        }
    }

    // MARK: - Hooks into live objects

    /// Push a new concurrency limit into every open project.
    var onConcurrencyChange: ((Int) -> Void)?
    /// Re-theme / re-font every live terminal.
    var onTerminalConfigChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let defaultEngine = "orchard.settings.defaultEngine"
        static let maxConcurrency = "orchard.settings.maxConcurrency"
        static let notifications = "orchard.settings.notifications"
        static let notifyOnlyBlocked = "orchard.settings.notifyOnlyBlocked"
        static let worktreeRoot = "orchard.settings.worktreeRoot"
        static let branchPrefix = "orchard.settings.branchPrefix"
        static let defaultBaseRef = "orchard.settings.defaultBaseRef"
        static let runSetup = "orchard.settings.runSetup"
        static let deleteBranch = "orchard.settings.deleteBranchWithWorktree"
        // Kept on the legacy key so an existing install doesn't lose its theme.
        static let theme = "orchard.theme"
        static let fontSize = "orchard.settings.fontSize"
        static let fontFamily = "orchard.settings.fontFamily"
    }

    init() {
        let d = UserDefaults.standard
        let fallback = DamsonConfig()

        defaultEngineID = d.string(forKey: Keys.defaultEngine)
            ?? AgentEngineRegistry.all.first?.id ?? "claude-code"
        // `integer(forKey:)` returns 0 for an unset key, which would mean "no agents may run".
        let storedConcurrency = d.object(forKey: Keys.maxConcurrency) as? Int
        maxConcurrency = storedConcurrency.map { max(1, $0) } ?? 3
        notificationsEnabled = (d.object(forKey: Keys.notifications) as? Bool) ?? true
        notifyOnlyWhenBlocked = (d.object(forKey: Keys.notifyOnlyBlocked) as? Bool) ?? false

        worktreeRoot = d.string(forKey: Keys.worktreeRoot) ?? ""
        branchPrefixOverride = d.string(forKey: Keys.branchPrefix) ?? ""
        defaultBaseRefOverride = d.string(forKey: Keys.defaultBaseRef) ?? ""
        runSetupScripts = (d.object(forKey: Keys.runSetup) as? Bool) ?? true
        deleteBranchWithWorktree = (d.object(forKey: Keys.deleteBranch) as? Bool) ?? false

        themeName = d.string(forKey: Keys.theme)
            ?? DamsonTheme.presets.first?.name ?? fallback.theme.name
        fontSize = (d.object(forKey: Keys.fontSize) as? Double) ?? Double(fallback.fontSize)
        fontFamily = d.string(forKey: Keys.fontFamily) ?? fallback.fontFamily
    }

    // MARK: - Derived

    var theme: DamsonTheme {
        DamsonTheme.preset(named: themeName) ?? DamsonTheme.presets.first ?? DamsonConfig().theme
    }

    /// Worktree parent for a repo, honoring the override.
    func worktreeRoot(for repo: URL) -> URL {
        let trimmed = worktreeRoot.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return WorktreeManager.defaultRoot(for: repo) }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let name = repo.lastPathComponent.replacingOccurrences(of: ".git", with: "")
        return URL(fileURLWithPath: expanded)
            .appendingPathComponent(name.isEmpty ? "repo" : name, isDirectory: true)
    }

    /// Terminal config new sessions are built from.
    func terminalConfig() -> DamsonConfig {
        var config = DamsonConfig()
        config.theme = theme
        config.fontSize = CGFloat(fontSize)
        config.fontFamily = fontFamily
        return config
    }

    /// The default worktree root as a display string, for the placeholder in the field.
    var defaultWorktreeRootDisplay: String {
        (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Orchard/worktrees").path as NSString)
            .abbreviatingWithTildeInPath
    }

    /// Monospaced font families installed on this machine, for the font picker.
    static func monospacedFamilies() -> [String] {
        let all = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        return all.sorted()
    }
}
