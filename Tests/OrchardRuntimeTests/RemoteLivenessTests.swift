import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// T89 — the producer `HostLiveness.live` never had, and the fence that keeps a
/// relaunch from answering for the connection it replaced.
///
/// `live` requires a positive answer *from the owning host*. Nothing on this side of a
/// remote pane can give one: the PTY holds `ssh`, hooks are a channel and not a process
/// table, and a probe that answers is only telling us the host was reachable. So the
/// pane writes an identity on the far side at launch and the question goes there.
final class RemotePaneLivenessTests: XCTestCase {
    private let host = HostRecord(name: "orchard-loopback", hostname: "127.0.0.1",
                                  user: "dkkang", port: 2222, source: .manual)

    // MARK: - Identity record

    func testTokensAreLowercaseHexAndNothingElse() {
        XCTAssertTrue(RemotePaneIdentity.isValidToken(RemotePaneIdentity.mintToken()))
        for bad in ["", "../../etc/passwd", "ABCDEF", "abc def", "abc/def", "abc;rm -rf /",
                    String(repeating: "a", count: 65)] {
            XCTAssertFalse(RemotePaneIdentity.isValidToken(bad), bad)
        }
    }

    func testThePreludeCannotBreakTheLaunchItPrecedes() {
        let prelude = RemotePaneIdentity.recordPrelude(token: "abc123", generation: "h#1.aa11bb22")
        // Output and status are both discarded, and it ends with `;` rather than `&&`:
        // a read-only $HOME or a host without `ps` costs the pane nothing.
        XCTAssertTrue(prelude.contains(">/dev/null 2>&1 || true;"))
        XCTAssertFalse(prelude.contains("&& cd"))
        XCTAssertTrue(prelude.hasSuffix("; "))
        // `$$` is written by the shell that will BECOME the remote command — `exec`
        // preserves the pid — so what is recorded is the pid worth asking about.
        XCTAssertTrue(prelude.contains("\"$$\""))
        XCTAssertTrue(prelude.contains("abc123.pane"))
        XCTAssertTrue(prelude.contains("__opg=\"h#1.aa11bb22\""))
    }

    func testTheRecordAndTheCheckUseLiterallyTheSamePsCommand() {
        // The start-time marker is never parsed, only compared. That is only sound if
        // both sides produce it identically — so they share one string.
        let prelude = RemotePaneIdentity.recordPrelude(token: "abc123", generation: "h#1.aa11bb22")
        let query = RemotePaneIdentity.queryScript(token: "abc123")
        XCTAssertTrue(prelude.contains(RemotePaneIdentity.startMarkerCommand))
        XCTAssertTrue(query.contains("ps -o lstart= -p \"$p\" 2>/dev/null | tr -s ' '"))
    }

    // MARK: - Reading the host's answer

    private func parse(_ line: String, expecting: String? = nil) -> RemoteProcessAnswer {
        RemotePaneIdentity.parse(line + "\n", expecting: expecting)
    }

    func testTheHostConfirmingAProcessIsTheOnlyThingThatProducesLive() {
        let answer = parse("ORCHARD-PANE/1 live h#1.aa11bb22 41207", expecting: "h#1.aa11bb22")
        XCTAssertEqual(answer, .live(pid: 41207))
        XCTAssertEqual(HostLiveness.verdict(forRemoteProcess: answer), .live)
    }

    func testAHostThatLookedAndFoundNothingIsExited() {
        let answer = parse("ORCHARD-PANE/1 exited h#1.aa11bb22 41207", expecting: "h#1.aa11bb22")
        XCTAssertEqual(answer, .exited(pid: 41207))
        XCTAssertEqual(HostLiveness.verdict(forRemoteProcess: answer), .exited)
    }

    func testAReusedPidIsExitedNotLive() {
        // The trap the start-time marker exists to close: on a busy host the number
        // comes back around, and `kill -0` alone would report a finished agent as live.
        let answer = parse("ORCHARD-PANE/1 reused h#1.aa11bb22 41207", expecting: "h#1.aa11bb22")
        XCTAssertEqual(answer, .pidReused(pid: 41207))
        XCTAssertEqual(HostLiveness.verdict(forRemoteProcess: answer), .exited)
        XCTAssertTrue(RemoteProcessLiveness.describe(host: "h", answer: answer)
            .contains("different process"))
    }

    func testNoRecordIsUnverifiableNotADeathCertificate() {
        let answer = parse("ORCHARD-PANE/1 no-record -")
        guard case .noRecord = answer else { return XCTFail("expected no-record") }
        let verdict = HostLiveness.verdict(forRemoteProcess: answer)
        XCTAssertEqual(verdict.status, "unverifiable")
        XCTAssertTrue(RemoteProcessLiveness.describe(host: "orchard-loopback", answer: answer)
            .contains("Loss of contact is not evidence that anything on orchard-loopback stopped."))
    }

    func testAGarbledAnswerIsUnverifiableRatherThanGuessed() {
        for line in ["", "totally unrelated banner", "ORCHARD-PANE/1", "ORCHARD-PANE/1 maybe g"] {
            XCTAssertEqual(HostLiveness.verdict(forRemoteProcess: parse(line)).status,
                           "unverifiable", line)
        }
    }

    func testAnAnswerFromALaterGenerationIsRefusedNotReported() {
        // The reconnect trap. The pane relaunched, the far side's record now names the
        // NEW connection's process, and reporting it as the old one's would be a
        // relaunch passing for continuity — with a pid attached to make it convincing.
        let answer = parse("ORCHARD-PANE/1 live h#2.bb22cc33 88991", expecting: "h#1.aa11bb22")
        XCTAssertEqual(answer, .superseded(asked: "h#1.aa11bb22", found: "h#2.bb22cc33"))
        let verdict = HostLiveness.verdict(forRemoteProcess: answer)
        XCTAssertEqual(verdict.status, "unverifiable")
        let note = RemoteProcessLiveness.describe(host: "h", answer: answer)
        XCTAssertTrue(note.contains("h#2.bb22cc33"))
        XCTAssertTrue(note.contains(HostLiveness.generationRefusalReminder))
    }

    func testAnUnstampedRecordStillAnswersSoOlderPanesAreNotBroken() {
        // A record written before generations existed reports `-`, which must not read
        // as a mismatch: the pane is answerable, it just cannot be fenced.
        let answer = parse("ORCHARD-PANE/1 live - 41207", expecting: "h#1.aa11bb22")
        XCTAssertEqual(answer, .live(pid: 41207))
    }

    // MARK: - Over a scripted ssh

    func testLossOfContactWhileAskingIsUnverifiable() async {
        let runner = ScriptedSSHRunner()
        runner.fallback = HostCommandResult(
            exitCode: 255, stderr: "ssh: connect to host 127.0.0.1 port 2222: Connection refused\n")
        let report = await RemoteProcessLiveness(host: host, runner: runner, timeout: 1)
            .report(paneKey: "pane_1", token: "abc123", paneGeneration: "h#1.aa11bb22")
        XCTAssertEqual(report.status, "unverifiable")
        XCTAssertTrue(report.note.contains("Loss of contact is not evidence"))
        XCTAssertNil(report.pid)
    }

    func testAPaneWithNoIdentityIsUnverifiableAndNothingIsRun() async {
        let runner = ScriptedSSHRunner()
        let report = await RemoteProcessLiveness(host: host, runner: runner, timeout: 1)
            .report(paneKey: "pane_1", token: nil)
        XCTAssertEqual(report.status, "unverifiable")
        XCTAssertTrue(runner.commandLines.isEmpty)
    }

    func testALiveAnswerCarriesThePidAndTheVerdict() async {
        let runner = ScriptedSSHRunner()
        runner.fallback = HostCommandResult(
            exitCode: 0, stdout: "ORCHARD-PANE/1 live h#1.aa11bb22 41207\n")
        let report = await RemoteProcessLiveness(host: host, runner: runner, timeout: 1)
            .report(paneKey: "pane_1", token: "abc123", paneGeneration: "h#1.aa11bb22")
        XCTAssertEqual(report.status, "live")
        XCTAssertEqual(report.pid, 41207)
        XCTAssertEqual(report.note, "orchard-loopback confirms process 41207 is running.")
    }
}

/// The pane-side generation label and the surgery that re-stamps it.
final class RemotePaneGenerationTests: XCTestCase {
    func testMintedLabelsAreValidAndCarryTheIncarnation() {
        let label = RemotePaneGeneration.mint(executionHostId: "ssh:build", incarnation: 4)
        XCTAssertTrue(RemotePaneGeneration.isValidLabel(label), label)
        XCTAssertTrue(label.hasPrefix("build#4."), label)
        XCTAssertNotEqual(label, RemotePaneGeneration.mint(executionHostId: "ssh:build",
                                                           incarnation: 4))
    }

    func testInvalidLabelsAreRejected() {
        for bad in ["", "build", "build#0.aa", "build#1.", "build#1.ZZ", "#1.aa",
                    "bu ild#1.aa", "build#x.aa"] {
            XCTAssertFalse(RemotePaneGeneration.isValidLabel(bad), bad)
        }
    }

    func testRewriteOnlyTouchesTheAssignmentWeWrote() {
        let ours = "{ __opd=\"$HOME/.orchard/panes\"; __opg=\"build#1.aaaaaaaa\"; }"
        XCTAssertEqual(RemotePaneGeneration.label(in: ours), "build#1.aaaaaaaa")
        let rewritten = RemotePaneGeneration.rewrite(ours, to: "build#2.bbbbbbbb")
        XCTAssertEqual(RemotePaneGeneration.label(in: rewritten), "build#2.bbbbbbbb")

        // Somebody else's script is not ours to rewrite — that is how another tool's
        // command quietly acquires our semantics.
        let foreign = "OPG=\"build#1.aaaaaaaa\"; echo hi"
        XCTAssertEqual(RemotePaneGeneration.rewrite(foreign, to: "build#2.bbbbbbbb"), foreign)
        XCTAssertNil(RemotePaneGeneration.label(in: foreign))
    }

    func testRewriteRefusesAnInvalidReplacement() {
        let ours = "__opg=\"build#1.aaaaaaaa\";"
        XCTAssertEqual(RemotePaneGeneration.rewrite(ours, to: "not a label"), ours)
    }

    func testTheLabelSurvivesBothLayersOfShellQuotingAPaneLaunchGoesThrough() {
        // A remote shell pane's launch is quoted twice: the remote command is one argv
        // element, and the whole `ssh` line is re-quoted as the shell engine's prompt.
        // The label's characters are untouched by either, which is what makes a plain
        // substring rewrite safe.
        let host = HostRecord(name: "build", hostname: "build.internal", user: "ci",
                              source: .manual)
        let label = RemotePaneGeneration.mint(executionHostId: "ssh:build", incarnation: 1)
        let remote = SSHCommand.cdAndLoginShellCommand(
            directory: "/srv/work/orchard", identityToken: "abc123", generation: label)
        let line = SSHCommand.remoteShellCommandLine(for: host, command: remote)
        XCTAssertEqual(RemotePaneGeneration.label(in: line), label)
        let next = RemotePaneGeneration.mint(executionHostId: "ssh:build", incarnation: 2)
        XCTAssertEqual(RemotePaneGeneration.label(in: RemotePaneGeneration.rewrite(line, to: next)),
                       next)
    }

    func testAPaneWithNoTokenGetsNoPreludeAtAll() {
        XCTAssertEqual(SSHCommand.cdAndLoginShellCommand(directory: "/srv/x"),
                       "cd /srv/x && exec \"${SHELL:-/bin/sh}\" -l")
        XCTAssertEqual(SSHCommand.prelude(nil, "build#1.aaaaaaaa"), "")
        XCTAssertEqual(SSHCommand.prelude("abc123", nil), "")
    }
}
