import XCTest
@testable import OrchardCore

/// Fan-out naming, engine listing, and the two inline composer validations.
/// These are the UI-free bits of ⌘N — the sheet only displays what this plans.
final class ComposerPlanningTests: XCTestCase {

    func testFanOutUsesUnsuffixedThenDash2Dash3() {
        XCTAssertEqual(
            ComposerPlanning.fanOutNames(name: "fix-parser", count: 3, taken: []),
            ["fix-parser", "fix-parser-2", "fix-parser-3"])
    }

    func testFanOutSkipsTakenLeavesIncludingGaps() {
        // Existing `-2` is occupied; first free is unsuffixed, then we jump to `-3`.
        XCTAssertEqual(
            ComposerPlanning.fanOutNames(
                name: "fix-parser", count: 3,
                taken: ["fix-parser-2"]),
            ["fix-parser", "fix-parser-3", "fix-parser-4"])
        XCTAssertEqual(
            ComposerPlanning.fanOutNames(
                name: "fix-parser", count: 2,
                taken: ["fix-parser", "fix-parser-2"]),
            ["fix-parser-3", "fix-parser-4"])
    }

    func testFanOutSanitizesBeforeColliding() {
        XCTAssertEqual(
            ComposerPlanning.fanOutNames(name: "Fix the parser!", count: 2, taken: []),
            ["fix-the-parser", "fix-the-parser-2"])
    }

    func testFanOutNeverEmitsNameMinusOne() {
        let names = ComposerPlanning.fanOutNames(name: "apricot", count: 4, taken: ["apricot"])
        XCTAssertEqual(names, ["apricot-2", "apricot-3", "apricot-4", "apricot-5"])
        XCTAssertFalse(names.contains("apricot-1"))
    }

    func testUniqueNameMatchesWorktreeManagerSuffixRule() {
        XCTAssertEqual(ComposerPlanning.uniqueName("leaf", taken: []), "leaf")
        XCTAssertEqual(ComposerPlanning.uniqueName("leaf", taken: ["leaf"]), "leaf-2")
        XCTAssertEqual(ComposerPlanning.uniqueName("leaf", taken: ["leaf", "leaf-2"]), "leaf-3")
        // A requested `-2` that is itself taken suffixes the whole desired string.
        XCTAssertEqual(ComposerPlanning.uniqueName("leaf-2", taken: ["leaf-2"]), "leaf-2-2")
    }

    func testValidationRejectsEmptyNameAndBadFanOut() {
        XCTAssertNotNil(ComposerPlanning.validationError(name: "", count: 1))
        XCTAssertNotNil(ComposerPlanning.validationError(name: "!!!", count: 1))
        XCTAssertNotNil(ComposerPlanning.validationError(name: "   ", count: 1))
        XCTAssertNotNil(ComposerPlanning.validationError(name: "ok", count: 0))
        XCTAssertNotNil(ComposerPlanning.validationError(name: "ok", count: 9))
        XCTAssertNotNil(ComposerPlanning.validationError(name: "ok", count: -1))
        XCTAssertNil(ComposerPlanning.validationError(name: "ok", count: 1))
        XCTAssertNil(ComposerPlanning.validationError(name: "fix-parser", count: 8))
    }

    func testSeedBaseRefsPutsResolvedDefaultFirstAndDedupes() {
        XCTAssertEqual(
            ComposerPlanning.seedBaseRefs(
                resolvedDefault: "origin/main",
                localBranches: ["feature", "main", "origin/main"]),
            ["origin/main", "feature", "main"])
        XCTAssertEqual(
            ComposerPlanning.seedBaseRefs(
                resolvedDefault: "main",
                localBranches: ["main", "other"]),
            ["main", "other"])
        XCTAssertEqual(
            ComposerPlanning.seedBaseRefs(resolvedDefault: "", localBranches: ["dev"]),
            ["dev"])
    }

    func testEngineListingShowsAliasOnceAndDropsDuplicateIds() {
        let items = ComposerPlanning.engineListing(engines: [
            (id: "claude-code", aliases: ["claude", "claude-code", "claude"]),
            (id: "codex", aliases: []),
            (id: "cursor-agent", aliases: ["cursor"]),
            (id: "claude-code", aliases: ["again"]),
        ])
        XCTAssertEqual(items.map(\.id), ["claude-code", "codex", "cursor-agent"])
        XCTAssertEqual(items.map(\.label),
                       ["claude (claude-code)", "codex", "cursor (cursor-agent)"])
        XCTAssertEqual(items[0].aliases, ["claude"])
    }
}
