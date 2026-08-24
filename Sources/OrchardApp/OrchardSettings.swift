import AppKit
import Combine
import DamsonTerminal
import OrchardCore
import OrchardRuntime
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

    /// Seconds between T20 port sweeps. Applied live via `PortService.setInterval`.
    @Published var portsSweepInterval: Double {
        didSet {
            defaults.set(portsSweepInterval, forKey: Keys.portsSweep)
            onSubsystemSettingsChange?()
        }
    }

    /// Browser profile id (or label) used for new unbound workspace tabs.
    @Published var defaultBrowserProfileID: String {
        didSet {
            defaults.set(defaultBrowserProfileID, forKey: Keys.defaultBrowserProfile)
            onSubsystemSettingsChange?()
        }
    }

    /// Master switch for the automation scheduler. Off stops the in-process loop.
    @Published var automationsEnabled: Bool {
        didSet {
            defaults.set(automationsEnabled, forKey: Keys.automationsEnabled)
            onSubsystemSettingsChange?()
        }
    }

    /// Vault retention (T49): total megabytes of pinned worker output to keep.
    /// 0 keeps everything forever. Nothing enforces this on a timer — the Vault
    /// window previews and applies it on request.
    @Published var archiveMaxTotalMB: Int {
        didSet { defaults.set(archiveMaxTotalMB, forKey: Keys.archiveMaxTotalMB) }
    }

    /// Vault retention: age ceiling in days for a pinned archive. 0 = keep forever.
    @Published var archiveMaxAgeDays: Int {
        didSet { defaults.set(archiveMaxAgeDays, forKey: Keys.archiveMaxAgeDays) }
    }

    /// The two caps as the runtime's retention rule sees them.
    var archiveRetentionPolicy: ArchiveRetentionPolicy {
        ArchiveRetentionPolicy(
            maxTotalBytes: archiveMaxTotalMB * 1024 * 1024,
            maxAgeDays: archiveMaxAgeDays)
    }

    var onTerminalConfigChange: (() -> Void)?
    var onSubsystemSettingsChange: (() -> Void)?

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
        static let portsSweep = "orchard.settings.portsSweepInterval"
        static let defaultBrowserProfile = "orchard.settings.defaultBrowserProfile"
        static let automationsEnabled = "orchard.settings.automationsEnabled"
        static let archiveMaxTotalMB = "orchard.settings.archiveMaxTotalMB"
        static let archiveMaxAgeDays = "orchard.settings.archiveMaxAgeDays"
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

        if let stored = d.object(forKey: Keys.portsSweep) as? Double {
            portsSweepInterval = PortService.clamp(stored)
        } else {
            portsSweepInterval = PortService.defaultInterval
        }
        defaultBrowserProfileID = d.string(forKey: Keys.defaultBrowserProfile)
            ?? BrowserProfile.defaultProfile.id
        automationsEnabled = (d.object(forKey: Keys.automationsEnabled) as? Bool) ?? true
        archiveMaxTotalMB = (d.object(forKey: Keys.archiveMaxTotalMB) as? Int)
            ?? ArchiveRetentionPolicy.defaultMaxTotalBytes / (1024 * 1024)
        archiveMaxAgeDays = (d.object(forKey: Keys.archiveMaxAgeDays) as? Int)
            ?? ArchiveRetentionPolicy.defaultMaxAgeDays
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
/// registry so the pickers can never drift from what the terminal layer can launch.
/// Labels are the planner's alias-once form (`claude (claude-code)`), not the
/// engine's marketing `displayName`, so the picker matches the ids agents type.
struct EngineOption: Identifiable, Hashable {
    let id: String
    let displayName: String

    static var all: [EngineOption] {
        ComposerPlanning.engineListing(
            engines: AgentEngineRegistry.all.map { (id: $0.id, aliases: $0.aliases) }
        ).map { EngineOption(id: $0.id, displayName: $0.label) }
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
