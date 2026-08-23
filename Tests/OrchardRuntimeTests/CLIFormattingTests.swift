import XCTest
import OrchardProtocol

final class CLIFormattingTests: XCTestCase {
    func testLeafHelpRendersUsageValueHintsAndRequiredMarkers() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "run-create" })
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("Usage:\n  orchard run-create [options]"), help)
        XCTAssertTrue(help.contains("--objective <text>"), help)
        XCTAssertTrue(help.contains("Run objective (required)"), help)
        XCTAssertTrue(help.contains("-h, --help"), help)
    }

    func testGroupHelpListsSubcommands() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "terminal" })
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("Positionals:"), help)
        XCTAssertTrue(help.contains("list|create|read|send|wait|split|close|rename"), help)
        XCTAssertTrue(help.contains("--terminal <handle>"), help)
    }

    func testBareGuideTopicListingFormat() {
        XCTAssertEqual(GuideTopicFormatter.render(["orchestration"]), "orchestration")
    }

    func testWorktreeListFormatsRemoteHostAndLastKnownWarning() {
        let fixture: JSONValue = .object([
            "worktrees": .array([.object([
                "displayName": .string("apricot"),
                "branch": .string("ci/apricot"),
                "hostId": .string("ssh:build"),
                "path": .string("/home/ci/worktrees/apricot"),
            ])]),
            "warning": .string("ssh:build: unreachable. Showing the last known worktrees."),
            "totalCount": .number(1),
            "truncated": .bool(false),
        ])
        let output = OrchardHumanFormatter.worktreeList(fixture)
        XCTAssertTrue(output.contains("HOST"), output)
        XCTAssertTrue(output.contains("ssh:build"), output)
        XCTAssertTrue(output.contains("/home/ci/worktrees/apricot"), output)
        XCTAssertTrue(output.contains("Warning: ssh:build: unreachable. Showing the last known worktrees."), output)
    }
}
