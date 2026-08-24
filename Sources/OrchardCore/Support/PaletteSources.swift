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
public enum PaletteCommand: String, CaseIterable, Sendable, Identifiable {
    case newWorktree
    case toggleChat
    case openDashboard
    case openAutomations
    case settings

    public var id: String { "cmd:\(rawValue)" }

    public var title: String {
        switch self {
        case .newWorktree: return "New Worktree"
        case .toggleChat: return "Toggle Chat"
        case .openDashboard: return "Open Dashboard"
        case .openAutomations: return "Open Automations"
        case .settings: return "Settings"
        }
    }

    public var subtitle: String { "Command" }

    public var symbol: String {
        switch self {
        case .newWorktree: return "plus.square"
        case .toggleChat: return "bubble.left.and.bubble.right"
        case .openDashboard: return "rectangle.split.3x1"
        case .openAutomations: return "clock.arrow.2.circlepath"
        case .settings: return "gearshape"
        }
    }

    public var keywords: [String] {
        switch self {
        case .newWorktree: return ["new worktree", "create", "compose", "command-n"]
        case .toggleChat: return ["toggle chat", "chat view", "terminal overlay"]
        case .openDashboard: return ["open dashboard", "agents", "kanban"]
        case .openAutomations: return ["automations", "schedule", "cron", "scheduled"]
        case .settings: return ["settings", "preferences", "ports", "browser"]
        }
    }
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
}
