import XCTest
@testable import OrchardCore

final class PaletteSourcesTests: XCTestCase {
    func testCommandsAreStableAndRankable() {
        let commands = PaletteSources.commands()
        XCTAssertEqual(commands.map(\.id), PaletteCommand.allCases.map(\.id))
        XCTAssertEqual(Set(commands.map(\.kind)), [.command])

        let ranked = PaletteSources.rank(query: "dash", candidates: commands)
        XCTAssertEqual(ranked.first?.id, PaletteCommand.openDashboard.id)

        let settings = PaletteSources.rank(query: "pref", candidates: commands)
        XCTAssertEqual(settings.first?.id, PaletteCommand.settings.id)

        let automations = PaletteSources.rank(query: "cron", candidates: commands)
        XCTAssertEqual(automations.first?.id, PaletteCommand.openAutomations.id)
    }

    func testCatalogPutsWorkspacesAgentsCommandsThenFiles() {
        let ws = PaletteWorkspaceSeed(id: UUID(), title: "fix-parser",
                                      branch: "orchard/fix-parser", repo: "damson-ide")
        let agent = PaletteAgentSeed(id: UUID(), title: "Fix the parser",
                                     engine: "Claude", branch: "orchard/fix-parser",
                                     repo: "damson-ide", state: "Working")
        let catalog = PaletteSources.catalog(
            workspaces: [ws],
            agents: [agent],
            files: ["Sources/OrchardApp/AppStore.swift", "README.md"],
            workspaceTitle: "fix-parser",
            includeFiles: true)
        let commandCount = PaletteCommand.allCases.count
        XCTAssertEqual(catalog.map(\.kind),
                       [.workspace, .agent]
                       + Array(repeating: PaletteKind.command, count: commandCount)
                       + [.file, .file])
        XCTAssertGreaterThanOrEqual(commandCount, PaletteCommand.goMenuSurface.count)
    }

    func testGoMenuSurfaceIsCoveredAndRankable() {
        let commands = PaletteSources.commands()
        let ids = Set(commands.map(\.id))
        XCTAssertEqual(PaletteCommand.goMenuSurface.count, 10)
        for command in PaletteCommand.goMenuSurface {
            XCTAssertTrue(ids.contains(command.id), "missing Go-menu command \(command.rawValue)")
            XCTAssertTrue(command.isGoMenu)
            XCTAssertEqual(command.subtitle, "Go")
            let ranked = PaletteSources.rank(query: command.title, candidates: commands)
            XCTAssertEqual(ranked.first?.id, command.id, "title \(command.title) should rank first")
        }
        XCTAssertFalse(PaletteCommand.settings.isGoMenu)
        XCTAssertFalse(PaletteCommand.newWorktree.isGoMenu)
        XCTAssertFalse(PaletteCommand.toggleChat.isGoMenu)

        let orch = PaletteSources.rank(query: "orch", candidates: commands)
        XCTAssertEqual(orch.first?.id, PaletteCommand.openOrchestration.id)
        let vault = PaletteSources.rank(query: "vault", candidates: commands)
        XCTAssertEqual(vault.first?.id, PaletteCommand.openVault.id)
        let space = PaletteSources.rank(query: "disk", candidates: commands)
        XCTAssertEqual(space.first?.id, PaletteCommand.openSpace.id)
        let editor = PaletteSources.rank(query: "editor", candidates: commands)
        XCTAssertEqual(editor.first?.id, PaletteCommand.showEditor.id)
        let refresh = PaletteSources.rank(query: "refresh diff", candidates: commands)
        XCTAssertEqual(refresh.first?.id, PaletteCommand.refreshDiff.id)
    }

    func testActivationRoutesFourKinds() {
        let workspaceID = UUID()
        let agentID = UUID()
        let ws = PaletteSources.workspaces([
            PaletteWorkspaceSeed(id: workspaceID, title: "fix-parser",
                                 branch: "orchard/fix-parser", repo: "damson-ide"),
        ])[0]
        let ag = PaletteSources.agents([
            PaletteAgentSeed(id: agentID, title: "Fix the parser",
                             engine: "Claude", branch: "orchard/fix-parser",
                             repo: "damson-ide", state: "Working"),
        ])[0]
        let file = PaletteSources.files(
            ["Sources/OrchardApp/JumpPalette.swift"], workspaceTitle: "fix-parser")[0]
        let command = PaletteSources.commands().first { $0.id == PaletteCommand.showTerminal.id }!

        XCTAssertEqual(PaletteSources.activation(for: ws), .selectWorkspace(workspaceID))
        XCTAssertEqual(PaletteSources.activation(for: ag), .focusAgent(agentID))
        XCTAssertEqual(PaletteSources.activation(for: file),
                       .openFile("Sources/OrchardApp/JumpPalette.swift"))
        XCTAssertEqual(PaletteSources.activation(for: command), .execute(.showTerminal))
        XCTAssertNil(PaletteSources.activation(for: "nope"))
        XCTAssertNil(PaletteSources.activation(for: "file"))
        for command in PaletteCommand.goMenuSurface {
            XCTAssertEqual(PaletteSources.activation(for: command.id), .execute(command))
        }
    }

    func testMixedCatalogRanksEachKind() {
        let ws = PaletteWorkspaceSeed(id: UUID(), title: "fix-parser",
                                      branch: "orchard/fix-parser", repo: "damson-ide")
        let agent = PaletteAgentSeed(id: UUID(), title: "Review the diff",
                                     engine: "Claude", branch: "orchard/fix-parser",
                                     repo: "damson-ide", state: "Working")
        let catalog = PaletteSources.catalog(
            workspaces: [ws],
            agents: [agent],
            files: ["Sources/OrchardApp/JumpPalette.swift", "README.md"],
            workspaceTitle: "fix-parser",
            includeFiles: true)

        let workspaceHit = PaletteSources.rank(query: "fix-parser", candidates: catalog)
        XCTAssertEqual(workspaceHit.first?.kind, .workspace)
        XCTAssertEqual(PaletteSources.activation(for: workspaceHit[0]), .selectWorkspace(ws.id))

        let agentHit = PaletteSources.rank(query: "claude", candidates: catalog)
        XCTAssertEqual(agentHit.first?.kind, .agent)
        XCTAssertEqual(PaletteSources.activation(for: agentHit[0]), .focusAgent(agent.id))

        let fileHit = PaletteSources.rank(query: "JumpPalette", candidates: catalog)
        XCTAssertEqual(fileHit.first?.kind, .file)
        XCTAssertEqual(PaletteSources.activation(for: fileHit[0]),
                       .openFile("Sources/OrchardApp/JumpPalette.swift"))

        let commandHit = PaletteSources.rank(query: "dashboard", candidates: catalog)
        XCTAssertEqual(commandHit.first?.kind, .command)
        XCTAssertEqual(PaletteSources.activation(for: commandHit[0]), .execute(.openDashboard))
    }

    func testEmptyQueryKeepsCallerOrder() {
        let catalog = PaletteSources.catalog(
            workspaces: [
                PaletteWorkspaceSeed(id: UUID(), title: "alpha", branch: "a", repo: "r"),
                PaletteWorkspaceSeed(id: UUID(), title: "beta", branch: "b", repo: "r"),
            ],
            agents: [],
            files: ["z.swift", "a.swift"],
            workspaceTitle: "alpha",
            includeFiles: false)
        let ranked = PaletteSources.rank(query: "  ", candidates: catalog)
        XCTAssertEqual(ranked.map(\.title), catalog.map(\.title))
    }

    func testFilesRankByBasenameThenPath() {
        let files = PaletteSources.files(
            ["Sources/OrchardApp/JumpPalette.swift", "docs/REBUILD-PLAN.md"],
            workspaceTitle: "v6")
        let hit = PaletteSources.rank(query: "jump", candidates: files)
        XCTAssertEqual(hit.first?.title, "JumpPalette.swift")
        XCTAssertEqual(PaletteSources.parseFilePath(hit[0].id),
                       "Sources/OrchardApp/JumpPalette.swift")
    }

    func testIncludeFilesFalseOmitsQuickOpenPaths() {
        let catalog = PaletteSources.catalog(
            workspaces: [],
            agents: [],
            files: ["a.swift"],
            workspaceTitle: "ws",
            includeFiles: false)
        XCTAssertFalse(catalog.contains { $0.kind == .file })
        XCTAssertTrue(catalog.contains { $0.kind == .command })
    }

    func testParseHelpersRoundTrip() {
        let workspaceID = UUID()
        let agentID = UUID()
        let ws = PaletteSources.workspaces([
            PaletteWorkspaceSeed(id: workspaceID, title: "t", branch: "b", repo: "r"),
        ])[0]
        let ag = PaletteSources.agents([
            PaletteAgentSeed(id: agentID, title: "t", engine: "e",
                             branch: "b", repo: "r", state: "Idle"),
        ])[0]
        XCTAssertEqual(PaletteSources.parseWorkspaceID(ws.id), workspaceID)
        XCTAssertEqual(PaletteSources.parseAgentID(ag.id), agentID)
        XCTAssertEqual(PaletteSources.parseCommand(PaletteCommand.toggleChat.id), .toggleChat)
        XCTAssertEqual(PaletteSources.parseCommand(PaletteCommand.openVault.id), .openVault)
        XCTAssertEqual(PaletteSources.parseCommand(PaletteCommand.showBrowser.id), .showBrowser)
        XCTAssertNil(PaletteSources.parseWorkspaceID("nope"))
        XCTAssertNil(PaletteSources.parseFilePath("ws:abc"))
    }
}

final class PaletteRankingTests: XCTestCase {
    func testSubsequencePrefersContiguousWordBoundary() {
        let items = ["orchard-fix-parser", "offer-char", "fx"]
        let ranked = PaletteRanking.rank(query: "fxp", items: items) { [($0, 100)] }
        XCTAssertEqual(ranked.first, "orchard-fix-parser")
        XCTAssertFalse(ranked.contains("offer-char"))
    }

    func testEmptyQueryIsIdentity() {
        let items = ["b", "a"]
        XCTAssertEqual(PaletteRanking.rank(query: "", items: items) { [($0, 1)] }, items)
    }

    func testHeavierFieldWinsWhenBothMatch() {
        struct Row { var title: String; var repo: String }
        let rows = [
            Row(title: "notes", repo: "parser"),
            Row(title: "parser", repo: "notes"),
        ]
        let ranked = PaletteRanking.rank(query: "parser", items: rows) {
            [($0.title, 300), ($0.repo, 100)]
        }
        XCTAssertEqual(ranked.first?.title, "parser")
    }

    func testMidWordSubsequenceLosesToWordStart() {
        // "cron" is a subsequence of "orchestration"; without the first-char
        // penalty it outranked the Automations keyword.
        XCTAssertNotNil(PaletteRanking.matchScore(query: "cron", in: "orchestration"))
        XCTAssertGreaterThan(
            PaletteRanking.matchScore(query: "cron", in: "cron") ?? 0,
            PaletteRanking.matchScore(query: "cron", in: "orchestration") ?? 0)
        let hay = "agent dashboard"
        XCTAssertTrue(PaletteRanking.isWordStart(hay.firstIndex(of: "d")!, in: hay))
    }

    /// A repo whose only workspace is its primary checkout was unreachable from ⌘J:
    /// the catalog seeded from worktree records only, and the sidebar renders the
    /// primary checkout as its own row.
    func testProjectRootIsReachable() {
        let projectID = UUID()
        let catalog = PaletteSources.catalog(
            workspaces: [], agents: [], files: [], workspaceTitle: "",
            includeFiles: false,
            projectRoots: [PaletteProjectSeed(id: projectID, name: "damson-ide", branch: "main")])

        let hits = PaletteSources.rank(query: "damson", candidates: catalog)
        XCTAssertEqual(hits.first?.title, "damson-ide")
        XCTAssertEqual(hits.first?.kind, .workspace)
        XCTAssertEqual(PaletteSources.activation(for: hits.first!), .selectProjectRoot(projectID))
        XCTAssertEqual(PaletteSources.parseProjectRootID("root:\(projectID.uuidString)"), projectID)
        XCTAssertNil(PaletteSources.parseWorkspaceID("root:\(projectID.uuidString)"))
    }
}
