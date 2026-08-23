import XCTest
@testable import OrchardRuntime

/// T32 — the bounded SSH command runner and the one rule everything remote rests on:
/// OpenSSH's 255 is *its own* transport failure, so it maps to `unverifiable`, while
/// every other status came back through a working connection and is a real answer.
final class SSHRunnerTests: XCTestCase {
    private let host = HostRecord(name: "build", hostname: "build.internal",
                                  user: "ci", port: 2222, source: .manual)
    private let configHost = HostRecord(name: "build", hostname: "build.internal",
                                        user: "ci", port: 2222, source: .sshConfig)

    private func classify(_ result: HostCommandResult) -> RemoteCommandOutcome {
        SSHRunner.classify(result, host: host)
    }

    func testExitZeroIsAnAnswer() {
        XCTAssertEqual(classify(HostCommandResult(exitCode: 0, stdout: "ok\n")),
                       .answered(exitCode: 0, stdout: "ok\n", stderr: ""))
    }

    func testNonTransportFailureIsTheRemoteCommandsOwnAnswer() {
        // `git worktree remove` refusing a dirty worktree is a *result*, not a lost
        // connection: the status travelled back through an authenticated session.
        let outcome = classify(HostCommandResult(
            exitCode: 128, stderr: "fatal: not a git repository\n"))
        guard case .answered(let code, _, let stderr) = outcome else {
            return XCTFail("expected an answer, got \(outcome)")
        }
        XCTAssertEqual(code, 128)
        XCTAssertTrue(stderr.contains("not a git repository"))
    }

    func testTransportFailureIsUnverifiableNotAFailedCommand() {
        for stderr in ["ssh: connect to host build.internal port 2222: Connection refused",
                       "ssh: Could not resolve hostname build.internal: nodename nor servname provided",
                       "ci@build.internal: Permission denied (publickey)."] {
            let outcome = classify(HostCommandResult(exitCode: 255, stderr: stderr + "\n"))
            XCTAssertTrue(outcome.isUnverifiable, stderr)
            // The reason is OpenSSH's own words, reused from the probe's classifier so
            // "wrong key" and "no route" read the same here as in `host check`.
            XCTAssertEqual(outcome.reasonForTest, stderr)
        }
    }

    func testDeadlineAndLaunchFailureAreUnverifiable() {
        XCTAssertTrue(classify(HostCommandResult(exitCode: nil, timedOut: true)).isUnverifiable)
        XCTAssertTrue(classify(HostCommandResult(exitCode: nil, stderr: "could not run ssh"))
            .isUnverifiable)
    }

    func testRequireTurnsLossOfContactIntoATypedRefusalThatSaysSo() {
        let runner = SSHRunner(host: host)
        XCTAssertThrowsError(try runner.require(.unverifiable(reason: "connection refused"),
                                                doing: "listing worktrees")) { error in
            guard let error = error as? RemoteHostError else { return XCTFail("wrong type") }
            XCTAssertEqual(error.code, "host_unverifiable")
            // The reminder is verbatim on every one of these, so no surface can quietly
            // reword loss of contact into a death certificate.
            XCTAssertTrue(error.message.contains(
                "Loss of contact is not evidence that anything on build changed."), error.message)
        }
    }

    func testRequireDistinguishesTheHostsOwnRefusal() {
        let runner = SSHRunner(host: host)
        XCTAssertThrowsError(try runner.require(
            .answered(exitCode: 1, stdout: "", stderr: "fatal: no such ref\n"),
            doing: "resolving main")) { error in
            XCTAssertEqual((error as? RemoteHostError)?.code, "remote_git_failed")
        }
    }

    func testArgvCarriesBothBoundsAndTheManualPort() {
        let argv = SSHRunner(host: host).argv(for: "git -C /srv status")
        XCTAssertEqual(argv, ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                              "-p", "2222", "ci@build.internal", "git -C /srv status"])
    }

    func testAnSSHConfigHostConnectsByAliasSoTheUsersOwnConfigStillApplies() {
        // Rewriting the alias into its hostname would silently drop ProxyJump,
        // IdentityFile and everything else Orchard deliberately does not model.
        let argv = SSHRunner(host: configHost).argv(for: "true")
        XCTAssertEqual(argv.dropLast().suffix(1).first, "build")
        XCTAssertFalse(argv.contains("-p"))
    }

    func testRemoteGitArgumentsAreQuotedForTheFarSidesShell() {
        let line = SSHRunner.commandLine(["git", "-C", "/srv/my repo", "status", "--porcelain"])
        XCTAssertEqual(line, "git -C '/srv/my repo' status --porcelain")
    }

    func testCdAndLoginShellSurvivesAHostWithNoSHELLSet() {
        let command = SSHCommand.cdAndLoginShellCommand(directory: "/home/ci/wt/apricot")
        XCTAssertEqual(command, "cd /home/ci/wt/apricot && exec \"${SHELL:-/bin/sh}\" -l")
        XCTAssertTrue(SSHCommand.cdAndLoginShellCommand(directory: "/home/ci/my wt")
            .hasPrefix("cd '/home/ci/my wt' &&"))
    }

    // MARK: - Remote path safety

    func testRemovalRefusesPathsThatWouldTakeTheRepoOrTheRootWithThem() {
        // `git worktree remove --force` deletes recursively, on a machine nothing local
        // can inspect afterwards, so these checks depend on the path alone.
        XCTAssertThrowsError(try RemoteWorktreeService.assertRemovable(
            path: "/", repoPath: "/srv/repo"))
        XCTAssertThrowsError(try RemoteWorktreeService.assertRemovable(
            path: "/srv/repo", repoPath: "/srv/repo"))
        XCTAssertThrowsError(try RemoteWorktreeService.assertRemovable(
            path: "/srv", repoPath: "/srv/repo"))
        XCTAssertNoThrow(try RemoteWorktreeService.assertRemovable(
            path: "/home/ci/Orchard/worktrees/repo/apricot", repoPath: "/srv/repo"))
    }

    func testComputedPathsMustLandInsideTheResolvedBase() {
        XCTAssertNoThrow(try RemoteWorktreeService.assertInside(
            "/home/ci/Orchard/worktrees/repo/apricot", base: "/home/ci/Orchard/worktrees/repo"))
        XCTAssertThrowsError(try RemoteWorktreeService.assertInside(
            "/home/ci/elsewhere", base: "/home/ci/Orchard/worktrees/repo"))
        XCTAssertThrowsError(try RemoteWorktreeService.assertInside(
            "/home/ci/Orchard/worktrees/repo", base: "/home/ci/Orchard/worktrees/repo"))
    }

    func testRelativeAndDotDotRemotePathsAreRejected() {
        XCTAssertThrowsError(try RemoteWorktreeService.requireAbsolute("srv/repo", what: "repo path"))
        XCTAssertThrowsError(try RemoteWorktreeService.requireAbsolute("/srv/../etc", what: "repo path"))
        XCTAssertEqual(try RemoteWorktreeService.requireAbsolute("/srv/repo/", what: "repo path"),
                       "/srv/repo")
    }
}

private extension RemoteCommandOutcome {
    var reasonForTest: String? {
        if case .unverifiable(let reason) = self { return reason }
        return nil
    }
}
