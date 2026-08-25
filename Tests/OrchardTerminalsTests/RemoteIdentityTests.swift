import XCTest
import OrchardCore
@testable import OrchardTerminals

/// T78 — the five `ORCHARD_*` facts have to reach a remote pane's far-side process,
/// not just the local `ssh` client. Pure wrapping plus the factory's launchConfig,
/// so nothing here forks a real transport.
@MainActor
final class RemoteIdentityTests: XCTestCase {
    private let context = TerminalHostContext(cliCommand: "orchard", dataPath: "/tmp/data")
    private let bindings: [(String, String)] = [
        ("ORCHARD_TERMINAL_HANDLE", "term_abc"),
        ("ORCHARD_PANE_KEY", "tab_1:leaf_1"),
        ("ORCHARD_WORKTREE_ID", "repo1::/tmp/wt"),
        ("ORCHARD_CLI_COMMAND", "orchard"),
        ("ORCHARD_DATA_PATH", "/tmp/data"),
    ]

    private func remoteSpec(handle: String = "term_abc",
                            paneKey: String = "tab_1:leaf_1",
                            prompt: String = "",
                            launchArgv: [String]? = nil) -> TerminalCreateSpec {
        TerminalCreateSpec(
            handle: handle, paneKey: paneKey,
            worktreeId: "repo1::/tmp/wt", cwd: nil, engineID: "shell",
            prompt: prompt, title: nil, executionHostId: "ssh:build",
            launchArgv: launchArgv)
    }

    // MARK: - wrapCommand

    func testWrapCommandPrefixesExportsAndKeepsTheFarSide() {
        let wrapped = OrchardIdentity.wrapCommand("cd /srv && exec claude", bindings: bindings)
        XCTAssertTrue(wrapped.hasPrefix("export ORCHARD_TERMINAL_HANDLE=term_abc; "), wrapped)
        XCTAssertTrue(wrapped.contains("export ORCHARD_PANE_KEY=tab_1:leaf_1"), wrapped)
        XCTAssertTrue(wrapped.contains("export ORCHARD_WORKTREE_ID=repo1::/tmp/wt"), wrapped)
        XCTAssertTrue(wrapped.contains("export ORCHARD_CLI_COMMAND=orchard"), wrapped)
        XCTAssertTrue(wrapped.contains("export ORCHARD_DATA_PATH=/tmp/data"), wrapped)
        XCTAssertTrue(wrapped.hasSuffix("; cd /srv && exec claude"), wrapped)
    }

    func testWrapCommandTurnsABareLoginIntoAnExportingLoginShell() {
        XCTAssertEqual(
            OrchardIdentity.wrapCommand(nil, bindings: [("ORCHARD_PANE_KEY", "p")]),
            "export ORCHARD_PANE_KEY=p; exec \"${SHELL:-/bin/sh}\" -l")
        XCTAssertEqual(
            OrchardIdentity.wrapCommand("  ", bindings: [("ORCHARD_PANE_KEY", "p")]),
            "export ORCHARD_PANE_KEY=p; exec \"${SHELL:-/bin/sh}\" -l")
    }

    func testWrapCommandQuotesValuesThatNeedIt() {
        let wrapped = OrchardIdentity.wrapCommand(
            "true",
            bindings: [("ORCHARD_DATA_PATH", "/tmp/Application Support/Orchard"),
                       ("ORCHARD_WORKTREE_ID", "repo::/tmp/o'hara")])
        XCTAssertTrue(
            wrapped.contains("export ORCHARD_DATA_PATH='/tmp/Application Support/Orchard'"),
            wrapped)
        XCTAssertTrue(
            wrapped.contains("export ORCHARD_WORKTREE_ID='repo::/tmp/o'\\''hara'"),
            wrapped)
    }

    func testWrapCommandIsIdempotentAndTheNewHandleWins() {
        let first = OrchardIdentity.wrapCommand("exec claude", bindings: bindings)
        let again = OrchardIdentity.wrapCommand(
            first, bindings: [("ORCHARD_TERMINAL_HANDLE", "term_new")])
        XCTAssertEqual(again, "export ORCHARD_TERMINAL_HANDLE=term_new; exec claude")
        XCTAssertFalse(again.contains("term_abc"), again)
        XCTAssertEqual(again.components(separatedBy: "export ORCHARD_").count - 1, 1)
    }

    // MARK: - carryThroughSSH

    func testAgentArgvWrapsTheRemoteCommandAndLeavesTheTunnelAlone() {
        let argv = ["/usr/bin/ssh", "-tt", "-R", "47110:127.0.0.1:9091",
                    "ci@build.internal", "cd /tmp/wt && unset CLAUDECODE && exec claude"]
        let out = OrchardIdentity.carryThroughSSH(argv: argv, bindings: bindings)
        XCTAssertEqual(Array(out.dropLast()), Array(argv.dropLast()))
        XCTAssertTrue(out.last?.hasPrefix("export ORCHARD_TERMINAL_HANDLE=term_abc; ") ?? false,
                      out.last ?? "")
        XCTAssertTrue(out.last?.hasSuffix("cd /tmp/wt && unset CLAUDECODE && exec claude") ?? false,
                      out.last ?? "")
    }

    func testDestOnlySSHAppendsAnExportingLoginShell() {
        let out = OrchardIdentity.carryThroughSSH(
            argv: ["/usr/bin/ssh", "-tt", "-p", "2222", "dkkang@127.0.0.1"],
            bindings: [("ORCHARD_PANE_KEY", "p")])
        XCTAssertEqual(Array(out.dropLast()),
                       ["/usr/bin/ssh", "-tt", "-p", "2222", "dkkang@127.0.0.1"])
        XCTAssertEqual(out.last, "export ORCHARD_PANE_KEY=p; exec \"${SHELL:-/bin/sh}\" -l")
    }

    func testCombinedFlagsAndAttachedOptionsDoNotStealTheDestination() {
        let argv = ["/usr/bin/ssh", "-tt", "-p2200", "-oBatchMode=yes",
                    "dk@10.0.0.5", "uptime -p"]
        let out = OrchardIdentity.carryThroughSSH(
            argv: argv, bindings: [("ORCHARD_PANE_KEY", "p")])
        XCTAssertEqual(out.last, "export ORCHARD_PANE_KEY=p; uptime -p")
        XCTAssertEqual(out[4], "dk@10.0.0.5")
    }

    func testLoginShellDashCLineWrapsTheQuotedRemoteCommand() throws {
        let line = "/usr/bin/ssh -tt dest 'cd /srv && exec \"${SHELL:-/bin/sh}\" -l'"
        let out = OrchardIdentity.carryThroughSSH(
            argv: ["/bin/zsh", "-l", "-c", line],
            bindings: [("ORCHARD_TERMINAL_HANDLE", "term_abc")])
        XCTAssertEqual(Array(out.dropLast()), ["/bin/zsh", "-l", "-c"])
        let rewritten = try XCTUnwrap(out.last)
        XCTAssertTrue(rewritten.hasPrefix("/usr/bin/ssh -tt dest "), rewritten)
        XCTAssertTrue(rewritten.contains("export ORCHARD_TERMINAL_HANDLE=term_abc"), rewritten)
        XCTAssertTrue(rewritten.contains("cd /srv && exec \"${SHELL:-/bin/sh}\" -l"), rewritten)
        // Re-quoted as a single ssh argument, so the far side still sees one command.
        XCTAssertTrue(rewritten.contains("'export ORCHARD_TERMINAL_HANDLE=term_abc; "), rewritten)
    }

    func testLocalArgvIsUntouched() {
        XCTAssertEqual(
            OrchardIdentity.carryThroughSSH(argv: ["/bin/cat"], bindings: bindings),
            ["/bin/cat"])
    }

    func testReconnectRetargetThenWrapKeepsTheFarSideAndMovesOnlyTheLocalPort() {
        let argv = ["/usr/bin/ssh", "-tt", "-R", "47110:127.0.0.1:9091",
                    "ci@build.internal", "cd /x && exec claude"]
        let retargeted = KeeperRemoteRestoration.retargetTunnel(argv: argv, localPort: 55055)
        let wrapped = OrchardIdentity.carryThroughSSH(
            argv: retargeted,
            bindings: [("ORCHARD_TERMINAL_HANDLE", "term_re")])
        XCTAssertTrue(wrapped.contains("47110:127.0.0.1:55055"), wrapped.joined(separator: " "))
        XCTAssertFalse(wrapped.contains("47110:127.0.0.1:9091"))
        XCTAssertEqual(wrapped.last, "export ORCHARD_TERMINAL_HANDLE=term_re; cd /x && exec claude")
    }

    // MARK: - factory launchConfig

    func testFactoryRemoteAgentArgvCarriesAllFiveVariables() throws {
        let spec = remoteSpec(launchArgv: [
            "/usr/bin/ssh", "-tt", "-R", "47110:127.0.0.1:9091",
            "ci@build.internal", "cd /tmp/wt && exec claude",
        ])
        let config = DamsonTerminalFactory.launchConfig(
            spec: spec, engine: GenericShellEngine(), context: context)
        XCTAssertEqual(config.env["ORCHARD_TERMINAL_HANDLE"], "term_abc")
        XCTAssertEqual(config.env["ORCHARD_PANE_KEY"], "tab_1:leaf_1")
        XCTAssertEqual(config.env["ORCHARD_WORKTREE_ID"], "repo1::/tmp/wt")
        XCTAssertEqual(config.env["ORCHARD_CLI_COMMAND"], "orchard")
        XCTAssertEqual(config.env["ORCHARD_DATA_PATH"], "/tmp/data")
        let remote = try XCTUnwrap(config.argv.last)
        for name in OrchardIdentity.variableNames {
            XCTAssertTrue(remote.contains("export \(name)="), "\(name) missing from \(remote)")
        }
        XCTAssertTrue(remote.hasSuffix("cd /tmp/wt && exec claude"), remote)
        XCTAssertEqual(config.argv.first, "/usr/bin/ssh")
        XCTAssertTrue(config.argv.contains("47110:127.0.0.1:9091"))
    }

    func testFactoryRemoteShellPromptLineCarriesIdentity() throws {
        let prompt = "/usr/bin/ssh -tt dest 'cd /srv && exec \"${SHELL:-/bin/sh}\" -l'"
        let config = DamsonTerminalFactory.launchConfig(
            spec: remoteSpec(prompt: prompt),
            engine: GenericShellEngine(), context: context)
        let line = try XCTUnwrap(config.argv.last)
        XCTAssertTrue(line.contains("export ORCHARD_TERMINAL_HANDLE=term_abc"), line)
        XCTAssertTrue(line.contains("export ORCHARD_PANE_KEY=tab_1:leaf_1"), line)
        XCTAssertTrue(line.contains("cd /srv && exec \"${SHELL:-/bin/sh}\" -l"), line)
    }

    func testFactoryBareRemoteSSHGainsAnExportingLoginShell() throws {
        let config = DamsonTerminalFactory.launchConfig(
            spec: remoteSpec(prompt: "/usr/bin/ssh -tt dest"),
            engine: GenericShellEngine(), context: context)
        let line = try XCTUnwrap(config.argv.last)
        XCTAssertTrue(line.contains("export ORCHARD_TERMINAL_HANDLE=term_abc"), line)
        XCTAssertTrue(line.contains("exec \"${SHELL:-/bin/sh}\" -l"), line)
    }

    func testFactoryLocalPaneDoesNotRewriteArgv() {
        let spec = TerminalCreateSpec(
            handle: "term_abc", paneKey: "tab_1:leaf_1",
            worktreeId: "repo1::/tmp/wt", cwd: "/tmp", engineID: "shell",
            prompt: "", title: nil)
        let config = DamsonTerminalFactory.launchConfig(
            spec: spec, engine: GenericShellEngine(), context: context)
        XCTAssertEqual(config.env["ORCHARD_TERMINAL_HANDLE"], "term_abc")
        XCTAssertFalse((config.argv.last ?? "").contains("export ORCHARD_"),
                       config.argv.joined(separator: " "))
    }

    func testFactoryReconnectSpecRewrapsWithTheNewHandle() {
        let recorded = ["cd /x && exec claude"]
        let first = remoteSpec(handle: "term_old", launchArgv: [
            "/usr/bin/ssh", "-tt", "-R", "47110:127.0.0.1:9091",
            "ci@build.internal"] + recorded)
        let plan = KeeperRemoteRestoration.reconnectPlan(
            spec: first, boundLocalPort: 55055)
        let reconnectSpec = TerminalCreateSpec(
            handle: "term_new", paneKey: first.paneKey,
            worktreeId: first.worktreeId, cwd: first.cwd, engineID: first.engineID,
            prompt: plan.prompt, title: nil, executionHostId: first.executionHostId,
            launchArgv: plan.launchArgv, remoteCwd: first.remoteCwd)
        let config = DamsonTerminalFactory.launchConfig(
            spec: reconnectSpec, engine: GenericShellEngine(), context: context)
        XCTAssertTrue(config.argv.contains("47110:127.0.0.1:55055"))
        let expected = OrchardIdentity.wrapCommand(
            "cd /x && exec claude",
            bindings: OrchardIdentity.bindings(spec: reconnectSpec, context: context))
        XCTAssertEqual(config.argv.last, expected)
        // The recorded spec the keeper would persist is still the unwrapped far side.
        XCTAssertEqual(reconnectSpec.launchArgv?.last, "cd /x && exec claude")
    }
}
