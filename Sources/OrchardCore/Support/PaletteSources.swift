import Foundation

/// Kind of a jump-palette row. Ranking is kind-agnostic — `PaletteRanking` sees
/// only the weighted fields.
public enum PaletteKind: String, Sendable, Hashable {
    case workspace, agent, file, command
}

public struct PaletteField: Equatable, Sendable {
    public var text: String
    public var weight: Int

    public init(text: String, weight: Int) {
        self.text = text
        self.weight = weight
    }
}

/// One rankable palette row. Activation payloads stay with the caller (ids);
/// this type is UI-free so the catalog can be unit-tested.
public struct PaletteCandidate: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: PaletteKind
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var fields: [PaletteField]

    public init(id: String, kind: PaletteKind, title: String, subtitle: String,
                symbol: String, fields: [PaletteField]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.fields = fields
    }
}

public struct PaletteWorkspaceSeed: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var branch: String
    public var repo: String

    public init(id: UUID, title: String, branch: String, repo: String) {
        self.id = id
        self.title = title
        self.branch = branch
        self.repo = repo
    }
}

public struct PaletteAgentSeed: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var engine: String
    public var branch: String
    public var repo: String
    public var state: String

    public init(id: UUID, title: String, engine: String, branch: String,
                repo: String, state: String) {
        self.id = id
        self.title = title
        self.engine = engine
        self.branch = branch
        self.repo = repo
        self.state = state
    }
}

/// Built-in palette commands. Ids are stable so the app can switch on them.
///
/// T65: the Go-menu surface is the minimum command set (`goMenuSurface`). Extra
/// File/View/App-menu verbs stay available so ⌘J remains a single jump target.
public enum PaletteCommand: String, CaseIterable, Sendable, Identifiable {
    // Go menu (inventory §6 / T65 minimum).
    case openDashboard
    case openOrchestration
    case openAutomations
    case openVault
    case showTerminal
    case showDiff
    case showEditor
    case showBrowser
    case refreshDiff
    // File / View / App extras (kept from T26).
    case newWorktree
    case toggleChat
    case settings

    public var id: String { "cmd:\(rawValue)" }

    /// Go-menu items the palette must execute. Order matches `buildMenu()` in
    /// `OrchardAppDelegate` (Jump itself is the palette, so it is omitted).
    public static let goMenuSurface: [PaletteCommand] = [
        .openDashboard, .openOrchestration, .openAutomations, .openVault,
        .showTerminal, .showDiff, .showEditor, .showBrowser, .refreshDiff,
    ]

    public var isGoMenu: Bool { Self.goMenuSurface.contains(self) }

    public var title: String {
        switch self {
        case .openDashboard: return "Agent Dashboard"
        case .openOrchestration: return "Orchestration"
        case .openAutomations: return "Automations"
        case .openVault: return "Vault"
        case .showTerminal: return "Terminal"
        case .showDiff: return "Diff"
        case .showEditor: return "Editor"
        case .showBrowser: return "Browser"
        case .refreshDiff: return "Refresh Diff"
        case .newWorktree: return "New Worktree"
        case .toggleChat: return "Toggle Chat"
        case .settings: return "Settings"
        }
    }

    public var subtitle: String { isGoMenu ? "Go" : "Command" }

    public var symbol: String {
        switch self {
        case .openDashboard: return "rectangle.split.3x1"
        case .openOrchestration: return "list.bullet.indent"
        case .openAutomations: return "clock.arrow.2.circlepath"
        case .openVault: return "archivebox"
        case .showTerminal: return "terminal"
        case .showDiff: return "plusminus"
        case .showEditor: return "doc.text"
        case .showBrowser: return "globe"
        case .refreshDiff: return "arrow.clockwise"
        case .newWorktree: return "plus.square"
        case .toggleChat: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }

    /// Optional menubar chord shown on the row; nil when the Go item has none.
    public var shortcut: String? {
        switch self {
        case .openDashboard: return "⇧⌘D"
        case .showTerminal: return "⌘1"
        case .showDiff: return "⌘2"
        case .showEditor: return "⌘3"
        case .showBrowser: return "⌘4"
        case .refreshDiff: return "⌘R"
        case .newWorktree: return "⌘N"
        case .toggleChat: return "⇧⌘J"
        case .settings: return "⌘,"
        case .openOrchestration, .openAutomations, .openVault: return nil
        }
    }

    public var keywords: [String] {
        switch self {
        case .openDashboard: return ["open dashboard", "agents", "kanban", "go"]
        case .openOrchestration: return ["orchestration", "tasks", "run", "dispatch", "go"]
        case .openAutomations: return ["automations", "schedule", "cron", "scheduled", "go"]
        case .openVault: return ["vault", "archives", "transcripts", "go"]
        case .showTerminal: return ["terminal", "shell", "pty", "go 1"]
        case .showDiff: return ["diff", "changes", "git diff", "go 2"]
        case .showEditor: return ["editor", "edit file", "go 3"]
        case .showBrowser: return ["browser", "web", "go 4"]
        case .refreshDiff: return ["refresh diff", "reload diff", "git status"]
        case .newWorktree: return ["new worktree", "create", "compose", "command-n"]
        case .toggleChat: return ["toggle chat", "chat view", "terminal overlay"]
        case .settings: return ["settings", "preferences", "ports", "browser"]
        }
    }
}

/// What activating a ranked row should do. Classification lives here so routing
/// can be unit-tested without AppKit; the app executes the cases.
public enum PaletteActivation: Equatable, Sendable {
    /// Select that worktree as the current workspace.
    case selectWorkspace(UUID)
    /// Focus the agent's pane (select its worktree and bind its tab).
    case focusAgent(UUID)
    /// Open the worktree-relative path in the editor (Option still maps to diff
    /// in the view; this case is the default file route).
    case openFile(String)
    /// Run a built-in command (Go-menu surface at minimum).
    case execute(PaletteCommand)
}

/// Builds the ⌘J catalog. Workspaces, agents, files (quickOpen paths), and
/// commands all go through `PaletteRanking` — there is no kind-specific matcher.
public enum PaletteSources {
    public static func commands() -> [PaletteCandidate] {
        PaletteCommand.allCases.map { command in
            var fields = [PaletteField(text: command.title, weight: 300)]
            for word in command.keywords {
                fields.append(PaletteField(text: word, weight: 180))
            }
            fields.append(PaletteField(text: "command", weight: 80))
            return PaletteCandidate(
                id: command.id,
                kind: .command,
                title: command.title,
                subtitle: command.subtitle,
                symbol: command.symbol,
                fields: fields)
        }
    }

    public static func workspaces(_ seeds: [PaletteWorkspaceSeed]) -> [PaletteCandidate] {
        seeds.map { seed in
            PaletteCandidate(
                id: "ws:\(seed.id.uuidString)",
                kind: .workspace,
                title: seed.title,
                subtitle: "\(seed.repo) · \(seed.branch)",
                symbol: "arrow.triangle.branch",
                fields: [
                    PaletteField(text: seed.title, weight: 300),
                    PaletteField(text: seed.branch, weight: 200),
                    PaletteField(text: seed.repo, weight: 100),
                ])
        }
    }

    public static func agents(_ seeds: [PaletteAgentSeed]) -> [PaletteCandidate] {
        seeds.map { seed in
            PaletteCandidate(
                id: "ag:\(seed.id.uuidString)",
                kind: .agent,
                title: seed.title,
                subtitle: "\(seed.repo) · \(seed.engine) · \(seed.state)",
                symbol: "cpu",
                fields: [
                    PaletteField(text: seed.title, weight: 300),
                    PaletteField(text: seed.engine, weight: 220),
                    PaletteField(text: seed.branch, weight: 180),
                    PaletteField(text: seed.repo, weight: 100),
                ])
        }
    }

    /// `paths` are worktree-relative quickOpen paths from `FileService.list`.
    public static func files(_ paths: [String], workspaceTitle: String) -> [PaletteCandidate] {
        paths.map { path in
            let name = (path as NSString).lastPathComponent
            let directory = (path as NSString).deletingLastPathComponent
            let subtitle = directory.isEmpty
                ? workspaceTitle
                : "\(workspaceTitle) · \(directory)"
            return PaletteCandidate(
                id: "file:\(path)",
                kind: .file,
                title: name,
                subtitle: subtitle,
                symbol: "doc",
                fields: [
                    PaletteField(text: name, weight: 300),
                    PaletteField(text: path, weight: 220),
                    PaletteField(text: workspaceTitle, weight: 80),
                ])
        }
    }

    public static func catalog(
        workspaces seeds: [PaletteWorkspaceSeed],
        agents agentSeeds: [PaletteAgentSeed],
        files paths: [String],
        workspaceTitle: String,
        includeFiles: Bool,
        includeCommands: Bool = true
    ) -> [PaletteCandidate] {
        var items: [PaletteCandidate] = []
        items.append(contentsOf: workspaces(seeds))
        items.append(contentsOf: agents(agentSeeds))
        if includeCommands {
            items.append(contentsOf: commands())
        }
        if includeFiles {
            items.append(contentsOf: files(paths, workspaceTitle: workspaceTitle))
        }
        return items
    }

    public static func rank(query: String, candidates: [PaletteCandidate]) -> [PaletteCandidate] {
        PaletteRanking.rank(query: query, items: candidates) { candidate in
            candidate.fields.map { ($0.text, $0.weight) }
        }
    }

    public static func parseWorkspaceID(_ id: String) -> UUID? {
        guard id.hasPrefix("ws:") else { return nil }
        return UUID(uuidString: String(id.dropFirst(3)))
    }

    public static func parseAgentID(_ id: String) -> UUID? {
        guard id.hasPrefix("ag:") else { return nil }
        return UUID(uuidString: String(id.dropFirst(3)))
    }

    public static func parseFilePath(_ id: String) -> String? {
        guard id.hasPrefix("file:") else { return nil }
        return String(id.dropFirst(5))
    }

    public static func parseCommand(_ id: String) -> PaletteCommand? {
        guard id.hasPrefix("cmd:") else { return nil }
        return PaletteCommand(rawValue: String(id.dropFirst(4)))
    }

    /// Map a catalog row id onto the T65 activation: worktree → select workspace,
    /// file → open in editor, agent → focus its pane, command → execute.
    public static func activation(for id: String) -> PaletteActivation? {
        if let workspaceID = parseWorkspaceID(id) { return .selectWorkspace(workspaceID) }
        if let agentID = parseAgentID(id) { return .focusAgent(agentID) }
        if let path = parseFilePath(id) { return .openFile(path) }
        if let command = parseCommand(id) { return .execute(command) }
        return nil
    }

    public static func activation(for candidate: PaletteCandidate) -> PaletteActivation? {
        activation(for: candidate.id)
    }
}
