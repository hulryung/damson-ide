import AppKit
import Combine
import DamsonTerminal
import OrchardCore
import OrchardTerminals

/// User preferences, persisted in `UserDefaults`.
///
/// Three groups match v1: how agents run, how worktrees are laid out, and how
/// the terminal looks. Per-repo concurrency is kept as a *display* concern only
/// — v2 has no scheduler (coordinators drive the loop).
@MainActor
final class OrchardSettings: ObservableObject {

    enum Scope { case immediate, newWorktrees, reopenProject }

    @Published var defaultEngineID: String {
        didSet { defaults.set(defaultEngineID, forKey: Keys.defaultEngine) }
    }

    /// `defaultEngineID` normalized to a registry id: values written by wave-2 builds
    /// pass through; pre-wave-2 picker names ("claude", "codex", …) map via the legacy
    /// `ComposerEngine` table.
    var resolvedDefaultEngineID: String {
        if AgentEngineRegistry.engine(id: defaultEngineID) != nil { return defaultEngineID }
        return ComposerEngine.from(storedDefault: defaultEngineID).resolvedEngineID
    }

    /// Display-only remnant of v1's concurrency cap. Not wired into any dispatcher.
    @Published var maxConcurrency: Int {
        didSet { defaults.set(maxConcurrency, forKey: Keys.maxConcurrency) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    @Published var notifyOnlyWhenBlocked: Bool {
        didSet { defaults.set(notifyOnlyWhenBlocked, forKey: Keys.notifyOnlyBlocked) }
    }

    @Published var worktreeRoot: String {
        didSet { defaults.set(worktreeRoot, forKey: Keys.worktreeRoot) }
    }

    @Published var branchPrefixOverride: String {
        didSet { defaults.set(branchPrefixOverride, forKey: Keys.branchPrefix) }
    }

    @Published var defaultBaseRefOverride: String {
        didSet { defaults.set(defaultBaseRefOverride, forKey: Keys.defaultBaseRef) }
    }

    @Published var runSetupScripts: Bool {
        didSet { defaults.set(runSetupScripts, forKey: Keys.runSetup) }
    }

    @Published var deleteBranchWithWorktree: Bool {
        didSet { defaults.set(deleteBranchWithWorktree, forKey: Keys.deleteBranch) }
    }

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
        static let theme = "orchard.theme"
        static let fontSize = "orchard.settings.fontSize"
        static let fontFamily = "orchard.settings.fontFamily"
    }

    init() {
        let d = UserDefaults.standard
        let fallback = DamsonConfig()

        defaultEngineID = d.string(forKey: Keys.defaultEngine)
            ?? ComposerEngine.claude.rawValue
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

    var theme: DamsonTheme {
        DamsonTheme.preset(named: themeName) ?? DamsonTheme.presets.first ?? DamsonConfig().theme
    }

    func worktreeRoot(for repo: URL) -> URL {
        let trimmed = worktreeRoot.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return WorktreeManager.defaultRoot(for: repo) }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let name = repo.lastPathComponent.replacingOccurrences(of: ".git", with: "")
        return URL(fileURLWithPath: expanded)
            .appendingPathComponent(name.isEmpty ? "repo" : name, isDirectory: true)
    }

    func terminalConfig() -> DamsonConfig {
        var config = DamsonConfig()
        config.theme = theme
        config.fontSize = CGFloat(fontSize)
        config.fontFamily = fontFamily
        return config
    }

    var defaultWorktreeRootDisplay: String {
        (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Orchard/worktrees").path as NSString)
            .abbreviatingWithTildeInPath
    }

    static func monospacedFamilies() -> [String] {
        let all = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        return all.sorted()
    }
}

/// One engine choice offered by the composer and menus — sourced from T3's engine
/// registry so the pickers can never drift from what the terminal layer can launch
/// (wave-2 seam close; the hardcoded picker enum below survives only to map legacy
/// stored defaults onto registry ids).
struct EngineOption: Identifiable, Hashable {
    let id: String
    let displayName: String

    static var all: [EngineOption] {
        AgentEngineRegistry.all.map { EngineOption(id: $0.id, displayName: $0.displayName) }
    }
}

/// Legacy composer vocabulary. Only `from(storedDefault:)`/`resolvedEngineID` remain
/// in use, translating pre-wave-2 stored defaults ("claude", "codex", …) to registry ids.
enum ComposerEngine: String, CaseIterable, Identifiable {
    case claude, codex, grok, cursor, shell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .shell: return "Shell"
        }
    }

    /// Registry id to pass to `AgentSupervisor.spawnAgent`.
    var resolvedEngineID: String {
        switch self {
        case .claude:
            return AgentEngineRegistry.engine(id: "claude-code")?.id ?? "claude-code"
        case .codex:
            return firstRegistered(["codex", "codex-cli"]) ?? "codex"
        case .grok:
            return firstRegistered(["grok"]) ?? "grok"
        case .cursor:
            return firstRegistered(["cursor-agent", "cursor"]) ?? "cursor-agent"
        case .shell:
            return "shell"
        }
    }

    var isRegistered: Bool {
        AgentEngineRegistry.engine(id: resolvedEngineID) != nil
    }

    private func firstRegistered(_ ids: [String]) -> String? {
        ids.first { AgentEngineRegistry.engine(id: $0) != nil }
    }

    static func from(storedDefault id: String) -> ComposerEngine {
        if let match = ComposerEngine(rawValue: id) { return match }
        if id == "claude-code" { return .claude }
        return .claude
    }
}
