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

    func testWorktreeRmAdvertisesDeleteBranchFlags() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "worktree" })
        let names = spec.flags.map(\.name)
        XCTAssertTrue(names.contains("delete-branch"), names.joined(separator: ","))
        XCTAssertTrue(names.contains("force-branch"), names.joined(separator: ","))
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("--delete-branch"), help)
        XCTAssertTrue(help.contains("--force-branch"), help)
    }

    /// Dogfood-2: `orchard send` without `--json` printed a Swift debug dump of
    /// `JSONValue`. The human face is a compact receipt; anything else is JSON.
    func testSendHumanOutputIsAReceiptNotASwiftDump() {
        let result: JSONValue = .object([
            "type": .string("worker_done"),
            "count": .number(1),
            "runId": .string("run_abc"),
            "messageIds": .array([.string("msg_1")]),
            "lifecycle": .object([
                "status": .string("settled"),
                "outcome": .string("succeeded"),
                "taskId": .string("task_abc"),
                "dispatchId": .string("ctx_abc"),
            ]),
        ])
        let output = OrchardHumanFormatter.send(result)
        XCTAssertTrue(output.contains("sent worker_done"), output)
        XCTAssertTrue(output.contains("settled"), output)
        XCTAssertTrue(output.contains("succeeded"), output)
        XCTAssertTrue(output.contains("task:task_abc"), output)
        XCTAssertFalse(output.contains("OrchardProtocol.JSONValue"), output)
        XCTAssertFalse(output.contains("object(["), output)
    }

    func testHostListShowsLiveStatusAndAge() {
        let fixture: JSONValue = .object([
            "hosts": .array([.object([
                "name": .string("build"),
                "target": .string("build"),
                "source": .string("ssh-config"),
                "executionHostId": .string("ssh:build"),
                "status": .string("reachable"),
                "ageSeconds": .number(12),
                "latencyMs": .number(42),
            ])]),
            "totalCount": .number(1),
        ])
        let output = OrchardHumanFormatter.hostList(fixture)
        XCTAssertTrue(output.contains("build"), output)
        XCTAssertTrue(output.contains("ssh:build"), output)
        XCTAssertTrue(output.contains("reachable"), output)
        XCTAssertTrue(output.contains("12s ago"), output)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("stopped"), output)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("died"), output)
    }

    func testHostListWithoutStatusStaysARegistryRow() {
        let fixture: JSONValue = .object([
            "hosts": .array([.object([
                "name": .string("build"),
                "target": .string("build"),
                "source": .string("ssh-config"),
                "executionHostId": .string("ssh:build"),
            ])]),
        ])
        let output = OrchardHumanFormatter.hostList(fixture)
        XCTAssertEqual(output, "build  build  ssh-config  ssh:build")
    }

    func testJSONFallbackIsJSONNotASwiftDump() throws {
        let result: JSONValue = .object([
            "type": .string("worker_done"),
            "count": .number(1),
        ])
        let output = OrchardHumanFormatter.json(result)
        XCTAssertTrue(output.contains("\"type\""), output)
        XCTAssertTrue(output.contains("worker_done"), output)
        XCTAssertFalse(output.contains("OrchardProtocol.JSONValue"), output)
        XCTAssertFalse(output.contains("object(["), output)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(parsed.objectValue?["type"]?.stringValue, "worker_done")
    }
}
