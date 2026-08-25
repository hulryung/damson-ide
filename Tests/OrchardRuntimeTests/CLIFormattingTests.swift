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
        XCTAssertTrue(output.contains("Warning (stale): ssh:build: unreachable. Showing the last known worktrees."), output)
        XCTAssertFalse(output.contains("OrchardProtocol.JSONValue"), output)
    }

    func testWorktreeListIgnoresExtraWorkspaceFieldsAndOmitsEmptyWarning() {
        let fixture: JSONValue = .object([
            "worktrees": .array([.object([
                "displayName": .string("apricot"),
                "name": .string("ignored-when-displayName-present"),
                "branch": .string("ci/apricot"),
                "hostId": .string("ssh:build"),
                "path": .string("/home/ci/worktrees/apricot"),
                "instanceId": .string("11111111-1111-1111-1111-111111111111"),
                "lastActivityAt": .number(1_724_000_000),
                "kind": .string("worktree"),
            ])]),
            "totalCount": .number(1),
        ])
        let output = OrchardHumanFormatter.worktreeList(fixture)
        XCTAssertTrue(output.contains("apricot"), output)
        XCTAssertFalse(output.contains("Warning"), output)
        XCTAssertFalse(output.contains("ignored-when-displayName-present"), output)
    }

    func testWorktreeRmFormatsBranchDeletedResult() {
        let deleted: JSONValue = .object([
            "removed": .bool(true),
            "branch": .string("orchard/wt"),
            "branchMerged": .bool(true),
            "branchDeleted": .bool(true),
        ])
        XCTAssertEqual(
            OrchardHumanFormatter.worktreeRm(deleted),
            "Removed worktree. Deleted branch 'orchard/wt'.")
        let kept: JSONValue = .object([
            "removed": .bool(true),
            "branch": .string("orchard/wt"),
            "branchDeleted": .bool(false),
        ])
        XCTAssertEqual(
            OrchardHumanFormatter.worktreeRm(kept),
            "Removed worktree. Branch 'orchard/wt' was kept.")
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

    func testSendVerboseIsPrettyJSONNotASwiftDump() throws {
        let result: JSONValue = .object([
            "type": .string("worker_done"),
            "count": .number(1),
            "lifecycle": .object(["status": .string("settled")]),
        ])
        let output = OrchardHumanFormatter.send(result, verbose: true)
        XCTAssertTrue(output.contains("\"type\""), output)
        XCTAssertTrue(output.contains("worker_done"), output)
        XCTAssertFalse(output.contains("sent worker_done"), output)
        XCTAssertFalse(output.contains("OrchardProtocol.JSONValue"), output)
        XCTAssertFalse(output.contains("object(["), output)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(parsed.objectValue?["type"]?.stringValue, "worker_done")
    }

    func testSendAdvertisesVerboseFlag() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "send" })
        XCTAssertTrue(spec.flags.map(\.name).contains("verbose"), spec.flags.map(\.name).joined(separator: ","))
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("--verbose"), help)
        XCTAssertTrue(help.contains("compact receipt"), help)
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

    // MARK: - T61 dogfood-4 help / flag nits + typed-error exit

    func testAutomationsHelpListsDueAndFireDue() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "automations" })
        XCTAssertTrue(spec.positionalArgs.contains { $0.contains("due") && $0.contains("fire-due") },
                      spec.positionalArgs.joined(separator: ","))
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("due"), help)
        XCTAssertTrue(help.contains("fire-due"), help)
    }

    func testDispatchShowAcceptsDispatchAsAliasOfId() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "dispatch-show" })
        let id = try XCTUnwrap(spec.flag(named: "id"))
        XCTAssertEqual(id.name, "id")
        XCTAssertTrue(id.required)
        XCTAssertEqual(spec.flag(named: "dispatch")?.name, "id")
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("--id <id>"), help)
        XCTAssertTrue(help.contains("alias: --dispatch"), help)
        XCTAssertFalse(spec.flags.map(\.name).contains("force"))
    }

    func testRepoHelpAdvertisesRemoveAndRefusesForce() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "repo" })
        XCTAssertTrue(spec.positionalArgs.contains { $0.contains("remove") },
                      spec.positionalArgs.joined(separator: ","))
        XCTAssertFalse(spec.flags.map(\.name).contains("force"), spec.flags.map(\.name).joined(separator: ","))
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("list|add|show|remove"), help)
        XCTAssertTrue(help.contains("repo_in_use") || help.contains("no --force"), help)
    }

    func testRepoRemoveHumanFace() {
        let removed: JSONValue = .object([
            "removed": .bool(true),
            "displayName": .string("Named"),
            "id": .string("abc"),
        ])
        XCTAssertEqual(OrchardHumanFormatter.repoRemove(removed), "Removed repo 'Named'.")
        let nested: JSONValue = .object([
            "removed": .bool(true),
            "repo": .object(["displayName": .string("Nested")]),
        ])
        XCTAssertEqual(OrchardHumanFormatter.repoRemove(nested), "Removed repo 'Nested'.")
        let kept: JSONValue = .object([
            "removed": .bool(false),
            "displayName": .string("Named"),
        ])
        XCTAssertEqual(OrchardHumanFormatter.repoRemove(kept), "Repo 'Named' was not removed.")
    }

    func testTypedErrorEnvelopeExitsNonZeroEvenWhenJSONPrinted() {
        let ok = RPCResponse.success(id: "1", result: .object(["removed": .bool(true)]))
        XCTAssertEqual(CLIEnvelopeExit.status(for: ok), 0)
        let typed = RPCResponse.failure(
            id: "1",
            error: RPCError(code: "transcript_unavailable", message: "provider_session_unavailable"))
        XCTAssertEqual(CLIEnvelopeExit.status(for: typed), 1)
        XCTAssertEqual(CLIEnvelopeExit.usage, 64)
    }

    func testFlagSpecDecodesWithoutAliases() throws {
        let json = #"{"name":"id","summary":"Dispatch identifier","valueHint":"id","required":true}"#
        let flag = try JSONDecoder().decode(FlagSpec.self, from: Data(json.utf8))
        XCTAssertEqual(flag.name, "id")
        XCTAssertEqual(flag.aliases, [])
        XCTAssertTrue(flag.matches("id"))
        XCTAssertFalse(flag.matches("dispatch"))
    }
}
