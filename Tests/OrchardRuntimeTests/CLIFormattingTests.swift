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
        XCTAssertTrue(help.contains("rmdirs"), help)
    }

    func testWorktreeSetStatusFlagIsBoardColumnWithWorkspaceStatusAlias() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "worktree" })
        let flag = try XCTUnwrap(spec.flag(named: "status"))
        XCTAssertEqual(flag.name, "status")
        XCTAssertEqual(flag.aliases, ["workspace-status"])
        XCTAssertEqual(spec.flag(named: "workspace-status")?.name, "status")
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("--status"), help)
        XCTAssertTrue(help.contains("--workspace-status"), help)
        XCTAssertTrue(help.contains("board column"), help.lowercased())
        XCTAssertTrue(help.contains("distinct from derived live status"), help)
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
        XCTAssertTrue(help.contains("automation_not_found"), help)
        XCTAssertTrue(help.contains("automation_invalid_input"), help)
        XCTAssertTrue(help.contains("automation_disabled"), help)
        XCTAssertTrue(help.contains("automation_fire_in_flight"), help)
    }

    func testWorkerReadHelpDocumentsDefaultLimit() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "worker-read" })
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("--limit"), help)
        XCTAssertTrue(help.contains("default \(WorkerReadPaging.defaultLimit)"), help)
        XCTAssertTrue(help.contains("newest \(WorkerReadPaging.defaultLimit) lines"), help)
        XCTAssertTrue(help.contains("hasOlder"), help)
        XCTAssertTrue(help.contains("truncated means the requested cursor was below the retained ring"), help)
        XCTAssertTrue(WorkerReadPaging.hasOlder(startCursor: 31, oldestCursor: 0))
        XCTAssertFalse(WorkerReadPaging.hasOlder(startCursor: 0, oldestCursor: 0))
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
        XCTAssertFalse(spec.positionalArgs.contains { $0.contains("forget") },
                      "forget is a flag on remove, not a subverb: \(spec.positionalArgs)")
        XCTAssertFalse(spec.flags.map(\.name).contains("force"), spec.flags.map(\.name).joined(separator: ","))
        XCTAssertNotNil(spec.flag(named: "forget"))
        XCTAssertNil(spec.flag(named: "forget")?.valueHint)
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("list|add|show|remove"), help)
        XCTAssertTrue(help.contains("--forget"), help)
        XCTAssertTrue(help.contains("repo_in_use") || help.contains("no --force"), help)
        XCTAssertTrue(help.contains("forget_local_refused"), help)
        XCTAssertTrue(help.contains("rmdirs"), help)
        XCTAssertTrue(help.contains("repo remove --repo <selector> --forget"), help)
        XCTAssertTrue(RepoGuide.content.contains("repo remove --repo <selector> --forget"),
                      RepoGuide.content)
        XCTAssertTrue(RepoGuide.content.contains("forget_local_refused"), RepoGuide.content)
        XCTAssertTrue(RepoGuide.content.contains("not a `repo forget` subverb"), RepoGuide.content)
        XCTAssertEqual(RepoGuide.topic, "repo")
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
        let forgotten: JSONValue = .object([
            "removed": .bool(true),
            "forgotten": .bool(true),
            "hostUntouched": .bool(true),
            "displayName": .string("RemoteOrchard"),
        ])
        XCTAssertEqual(
            OrchardHumanFormatter.repoRemove(forgotten),
            "Forgot repo 'RemoteOrchard' (registry only; host untouched).")
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

    func testConflictsHelpEnumeratesSidesChoicesAndTypedErrors() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "conflicts" })
        XCTAssertEqual(spec.positionalArgs, ["list|show|take|resolve|stage"])
        XCTAssertEqual(spec.flag(named: "side")?.allowedValues, ["ours", "theirs"])
        XCTAssertEqual(spec.flag(named: "choice")?.allowedValues, ["ours", "theirs", "both"])
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("list|show|take|resolve|stage"), help)
        XCTAssertTrue(help.contains("conflict_markers_remain"), help)
        XCTAssertTrue(help.contains("not_conflicted"), help)
        XCTAssertTrue(help.contains("hunk_not_found"), help)
        XCTAssertTrue(help.contains("never stages a lie"), help)
        XCTAssertTrue(ConflictsGuide.content.contains("conflicts list"), ConflictsGuide.content)
        XCTAssertTrue(ConflictsGuide.content.contains("conflict_markers_remain"), ConflictsGuide.content)
    }

    func testConflictsHumanFaces() {
        let listed: JSONValue = .object([
            "headline": .string("Merge in progress — 1 conflicted file"),
            "files": .array([.object([
                "kindCode": .string("UU"),
                "path": .string("file.txt"),
                "kindLabel": .string("Both modified"),
            ])]),
        ])
        let listOut = OrchardHumanFormatter.conflictsList(listed)
        XCTAssertTrue(listOut.contains("Merge in progress — 1 conflicted file"), listOut)
        XCTAssertTrue(listOut.contains("UU  file.txt  Both modified"), listOut)

        let shown: JSONValue = .object([
            "path": .string("file.txt"),
            "kindLabel": .string("Both modified"),
            "kindCode": .string("UU"),
            "hunks": .array([.object([
                "index": .number(0),
                "startLine": .number(2),
                "oursLabel": .string("HEAD"),
                "theirsLabel": .string("feature"),
                "ours": .array([.string("main line")]),
                "theirs": .array([.string("feature line")]),
            ])]),
        ])
        let showOut = OrchardHumanFormatter.conflictsShow(shown)
        XCTAssertTrue(showOut.contains("file.txt  Both modified (UU)"), showOut)
        XCTAssertTrue(showOut.contains("hunk 0  line 2"), showOut)
        XCTAssertTrue(showOut.contains("ours (HEAD):"), showOut)
        XCTAssertTrue(showOut.contains("feature line"), showOut)

        XCTAssertEqual(
            OrchardHumanFormatter.conflictsTake(.object([
                "path": .string("file.txt"), "side": .string("ours"), "deleted": .bool(false),
            ])),
            "Took ours for file.txt (staged).")
        XCTAssertEqual(
            OrchardHumanFormatter.conflictsTake(.object([
                "path": .string("doomed.txt"), "side": .string("theirs"), "deleted": .bool(true),
            ])),
            "Took theirs for doomed.txt (deleted, staged).")
        XCTAssertEqual(
            OrchardHumanFormatter.conflictsResolve(.object([
                "path": .string("file.txt"), "hunk": .number(0), "choice": .string("theirs"),
                "staged": .bool(true), "remainingHunks": .number(0),
            ])),
            "Resolved hunk 0 of file.txt as theirs (staged).")
        XCTAssertEqual(
            OrchardHumanFormatter.conflictsResolve(.object([
                "path": .string("f.txt"), "hunk": .number(0), "choice": .string("ours"),
                "staged": .bool(false), "remainingHunks": .number(1),
            ])),
            "Resolved hunk 0 of f.txt as ours (1 hunk remaining, not staged).")
        XCTAssertEqual(
            OrchardHumanFormatter.conflictsStage(.object(["path": .string("file.txt")])),
            "Staged file.txt.")
    }

    func testWorktreeHelpEnumeratesSubverbsAndCreateFlags() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "worktree" })
        XCTAssertEqual(spec.positionalArgs, ["list|show|current|create|set|rm|ps"])
        XCTAssertEqual(spec.usage, "orchard worktree list|show|current|create|set|rm|ps [options]")
        for verb in WorktreeSubcommands.all {
            XCTAssertTrue(spec.positionalArgs.contains { $0.contains(verb) }, verb)
            XCTAssertTrue(spec.examples.contains { $0.contains("worktree \(verb)") },
                          spec.examples.joined(separator: "\n"))
        }
        XCTAssertNotNil(spec.flag(named: "agent")?.allowedValues)
        XCTAssertEqual(spec.flag(named: "agent")?.allowedValues, OrchardAgentEngines.acceptedIdentifiers)
        XCTAssertNotNil(spec.flag(named: "prompt"))
        XCTAssertNotNil(spec.flag(named: "run-hooks"))
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("aliases: remove, delete"), help)
        XCTAssertTrue(help.contains("create infers --repo"), help)
        XCTAssertTrue(WorktreeGuide.content.contains("worktree current"), WorktreeGuide.content)
        XCTAssertTrue(WorktreeGuide.content.contains("worktree ps"), WorktreeGuide.content)
    }

    func testWorktreeShowAndCreateHumanFaces() {
        let shown: JSONValue = .object([
            "worktree": .object([
                "displayName": .string("apricot"),
                "branch": .string("ci/apricot"),
                "hostId": .string("local"),
                "path": .string("/home/ci/worktrees/apricot"),
                "id": .string("repo::/home/ci/worktrees/apricot"),
                "workspaceStatus": .string("in-review"),
                "comment": .string("from rpc"),
            ]),
        ])
        let showOut = OrchardHumanFormatter.worktreeShow(shown)
        XCTAssertTrue(showOut.contains("apricot  ci/apricot  local"), showOut)
        XCTAssertTrue(showOut.contains("/home/ci/worktrees/apricot"), showOut)
        XCTAssertTrue(showOut.contains("status  in-review"), showOut)
        XCTAssertTrue(showOut.contains("comment  from rpc"), showOut)

        let created: JSONValue = .object([
            "worktree": .object([
                "displayName": .string("rpc-one"),
                "branch": .string("daekeun-kang/rpc-one"),
                "path": .string("/tmp/wt/rpc-one"),
            ]),
            "agentTerminalHandle": .string("term_instant"),
        ])
        let createOut = OrchardHumanFormatter.worktreeCreate(created)
        XCTAssertTrue(createOut.contains("Created worktree 'rpc-one'"), createOut)
        XCTAssertTrue(createOut.contains("on daekeun-kang/rpc-one"), createOut)
        XCTAssertTrue(createOut.contains("Agent terminal term_instant"), createOut)
    }

    func testProjectHelpAndHumanFaces() throws {
        let spec = try XCTUnwrap(OrchardCommands.all.first { $0.name == "project" })
        XCTAssertEqual(spec.positionalArgs, ["list|show|current"])
        XCTAssertEqual(spec.flag(named: "repo")?.name, "project")
        for verb in ProjectSubcommands.all {
            XCTAssertTrue(spec.examples.contains { $0.contains("project \(verb)") },
                          spec.examples.joined(separator: "\n"))
        }
        let help = CommandHelpRenderer.render(spec)
        XCTAssertTrue(help.contains("list|show|current"), help)
        XCTAssertTrue(help.contains("Host-setup verbs"), help)
        XCTAssertTrue(ProjectGuide.content.contains("project list"), ProjectGuide.content)
        XCTAssertTrue(ProjectGuide.content.contains("setup-clone"), ProjectGuide.content)

        let listed: JSONValue = .object([
            "projects": .array([.object([
                "displayName": .string("Apricot"),
                "hostId": .string("local"),
                "kind": .string("git"),
                "worktreeCount": .number(2),
                "path": .string("/tmp/apricot"),
            ])]),
            "count": .number(1),
        ])
        let listOut = OrchardHumanFormatter.projectList(listed)
        XCTAssertTrue(listOut.contains("Apricot"), listOut)
        XCTAssertTrue(listOut.contains("2"), listOut)
        XCTAssertTrue(listOut.contains("/tmp/apricot"), listOut)

        let shown: JSONValue = .object([
            "project": .object([
                "displayName": .string("Apricot"),
                "kind": .string("git"),
                "hostId": .string("local"),
                "path": .string("/tmp/apricot"),
                "id": .string("abc"),
                "baseRef": .string("main"),
            ]),
            "worktrees": .array([
                .object(["displayName": .string("Apricot"), "branch": .string("main")]),
                .object(["displayName": .string("child"), "branch": .string("topic")]),
            ]),
        ])
        let showOut = OrchardHumanFormatter.projectShow(shown)
        XCTAssertTrue(showOut.contains("Apricot  git  local"), showOut)
        XCTAssertTrue(showOut.contains("base  main"), showOut)
        XCTAssertTrue(showOut.contains("child  topic"), showOut)
    }

    func testGuideTopicsIncludeWorktreeAndProject() {
        XCTAssertEqual(WorktreeGuide.topic, "worktree")
        XCTAssertEqual(ProjectGuide.topic, "project")
        XCTAssertTrue(CommandGroup.allCases.contains(.project))
        XCTAssertTrue(CommandGroup.allCases.contains(.worktree))
        XCTAssertTrue(OrchardCommands.all.contains { $0.name == "project" })
        XCTAssertTrue(OrchardCommands.all.contains { $0.name == "worktree" })
    }
}
