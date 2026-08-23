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
        XCTAssertEqual(catalog.map(\.kind), [
            .workspace, .agent, .command, .command, .command, .command, .file, .file,
        ])
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
}
