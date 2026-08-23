import XCTest
@testable import OrchardRuntime

/// A `HostCommandRunner` that answers from a script instead of spawning `ssh`, so the
/// probe's *classification* is testable without a server, a network, or a key.
private struct FakeRunner: HostCommandRunner {
    let result: HostCommandResult
    /// Set when the caller wants to assert on the argv the probe built.
    let observed = Observed()

    final class Observed: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        var argv: [String] {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func record(_ argv: [String]) {
            lock.lock(); value = argv; lock.unlock()
        }
    }

    func run(_ argv: [String], timeout: TimeInterval) async -> HostCommandResult {
        observed.record(argv)
        return result
    }
}

/// T29 connectivity probe: `reachable | auth-required | unreachable`, and the rule that
/// loss of contact is never evidence that anything on the host stopped.
final class HostProbeTests: XCTestCase {
    private let host = HostRecord(name: "build", hostname: "build.internal",
                                  user: "ci", source: .sshConfig)

    private func check(_ result: HostCommandResult) async -> HostProbeResult {
        await HostProbe.check(host: host, runner: FakeRunner(result: result), timeout: 1)
    }

    func testExitZeroIsReachable() async {
        let probe = await check(HostCommandResult(exitCode: 0))
        XCTAssertEqual(probe.status, .reachable)
        XCTAssertEqual(probe.executionHostId, "ssh:build")
        XCTAssertNil(probe.note)
    }

    func testPermissionDeniedIsAuthRequiredNotUnreachable() async {
        let probe = await check(HostCommandResult(
            exitCode: 255, stderr: "ci@build.internal: Permission denied (publickey).\n"))
        // The host answered — only the credential is missing. Calling this
        // "unreachable" would tell a user to debug the network instead of their key.
        XCTAssertEqual(probe.status, .authRequired)
        XCTAssertEqual(probe.detail, "ci@build.internal: Permission denied (publickey).")
    }

    func testChangedHostKeyIsAuthRequired() async {
        let probe = await check(HostCommandResult(
            exitCode: 255, stderr: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\n"))
        XCTAssertEqual(probe.status, .authRequired)
    }

    func testNetworkFailuresAreUnreachableAndSayLossOfContactIsNotDeath() async {
        for stderr in ["ssh: Could not resolve hostname build.internal: nodename nor servname provided",
                       "ssh: connect to host build.internal port 22: Connection refused",
                       "ssh: connect to host build.internal port 22: Operation timed out",
                       "kex_exchange_identification: read: Connection reset by peer"] {
            let probe = await check(HostCommandResult(exitCode: 255, stderr: stderr + "\n"))
            XCTAssertEqual(probe.status, .unreachable, stderr)
            XCTAssertEqual(probe.note,
                           "Unreachable is loss of contact, not evidence that anything on build stopped.")
        }
    }

    func testTimeoutIsUnreachableAndNeverHangs() async {
        let probe = await check(HostCommandResult(exitCode: nil, timedOut: true))
        XCTAssertEqual(probe.status, .unreachable)
        XCTAssertTrue(probe.timedOut)
        XCTAssertEqual(probe.detail, "the probe hit its deadline with no answer")
    }

    func testNonTransportExitStatusMeansTheHostAnswered() async {
        // 127 came back *through* an authenticated connection (the remote shell could
        // not find `true`); only 255 is OpenSSH's own failure.
        let probe = await check(HostCommandResult(exitCode: 127, stderr: "bash: true: command not found\n"))
        XCTAssertEqual(probe.status, .reachable)
    }

    func testProbeRunsBatchModeWithABoundedConnectTimeout() async {
        let runner = FakeRunner(result: HostCommandResult(exitCode: 0))
        let probe = await HostProbe.check(host: host, runner: runner, timeout: 1)
        // BatchMode is what makes the probe safe to run unattended: OpenSSH fails
        // instead of prompting, so `host check` can never block on a human.
        XCTAssertEqual(runner.observed.argv,
                       ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                        "build", "true"])
        XCTAssertEqual(probe.command,
                       "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=5 build true")
    }

    func testRealRunnerReturnsWithinItsDeadline() async throws {
        // The bound is the runner's own, not OpenSSH's: a child that never exits must
        // still be killed. `sleep 30` stands in for a wedged connection.
        let started = Date()
        let result = await ProcessHostCommandRunner().run(["/bin/sleep", "30"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.exitCode)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testRealRunnerReportsExitStatusAndStderr() async {
        // End-to-end plumbing with a real child: the wording below is what OpenSSH
        // actually prints for an unresolvable host (verified against /usr/bin/ssh).
        let result = await ProcessHostCommandRunner().run(
            ["/bin/sh", "-c",
             "echo 'ssh: Could not resolve hostname build.internal: nodename nor servname provided' >&2; exit 255"],
            timeout: 5)
        XCTAssertEqual(result.exitCode, 255)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(HostProbe.classify(result).0, .unreachable)
    }

    // MARK: - Liveness verdicts

    func testPTYEndVerdicts() {
        let remote = ExecutionHostId(rawValue: "ssh:build")!
        // 255 is OpenSSH's transport failure: the connection died, which says nothing
        // about the remote shell. Never `exited`.
        XCTAssertEqual(HostLiveness.verdictForPTYEnd(host: remote, exitCode: 255).status,
                       "unverifiable")
        XCTAssertEqual(HostLiveness.verdictForPTYEnd(host: remote, exitCode: nil).status,
                       "unverifiable")
        // Any other status was propagated from the far side, so it is real evidence.
        XCTAssertEqual(HostLiveness.verdictForPTYEnd(host: remote, exitCode: 0), .exited)
        XCTAssertEqual(HostLiveness.verdictForPTYEnd(host: remote, exitCode: 1), .exited)
        // Locally the PTY *is* the process.
        XCTAssertEqual(HostLiveness.verdictForPTYEnd(host: .local, exitCode: 1), .exited)
        XCTAssertEqual(HostLiveness.verdictForPTYEnd(host: .local, exitCode: nil).status,
                       "unverifiable")
    }

    func testConnectionEndCopyNeverClaimsARemoteDeath() {
        let remote = ExecutionHostId(rawValue: "ssh:build")!
        let dropped = HostLiveness.describeConnectionEnd(host: remote, exitCode: 255)
        XCTAssertTrue(dropped.contains("unverifiable"), dropped)
        XCTAssertFalse(dropped.lowercased().contains("exited"), dropped)

        let clean = HostLiveness.describeConnectionEnd(host: remote, exitCode: 0)
        XCTAssertTrue(clean.contains("remote shell exited"), clean)
    }
}
