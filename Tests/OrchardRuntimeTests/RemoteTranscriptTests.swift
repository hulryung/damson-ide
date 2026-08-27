import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// T89 — the last refusal T39 left standing: `worker-read --source transcript` on a
/// remote pane.
///
/// The old answer was `remote_provider_transcript_unsupported` for every remote pane,
/// and it was right at the time: the resolver read `~/.claude/projects` on *this*
/// machine, and a remote pane's local cwd is only where `ssh` was launched from. The
/// fix is not to relax that — it is to ask the machine the file is actually on.
final class RemoteTranscriptTests: XCTestCase {
    private let host = HostRecord(name: "orchard-loopback", hostname: "127.0.0.1",
                                  user: "dkkang", port: 2222, source: .manual)
    private let limit = 2_000_000

    private func parse(_ stdout: String, maximumBytes: Int? = nil)
        -> WorkerRuntimeContext.ProviderTranscriptResolution {
        RemoteProviderTranscript.parse(stdout, maximumBytes: maximumBytes ?? limit)
    }

    private func header(_ size: Int, _ path: String) -> String {
        "ORCHARD-TX/1 ok \(size) \(path)\n"
    }

    // MARK: - The script

    func testTheScriptResolvesTheDirectoryOnTheFarSideRatherThanTrustingThePath() {
        // The provider encodes the *resolved* path into its project folder name, and on
        // the host we verified against `/tmp` resolves to `/private/tmp`. Encoding the
        // unresolved path would look for a directory that never exists.
        let script = RemoteProviderTranscript.script(
            remoteCwd: "/tmp/work", sessionID: "abc-123", maximumBytes: 4096)
        XCTAssertTrue(script.contains("cd \"$c\" 2>/dev/null && pwd -P"))
        XCTAssertTrue(script.contains("tr '/' '-'"))
        XCTAssertTrue(script.contains("$HOME/.claude/projects/$e/$s.jsonl"))
        XCTAssertTrue(script.contains("tail -c 4096"))
        // Bytes travel base64: a transcript with a non-UTF-8 byte must come back typed,
        // never as replacement characters pretending to be the agent's words.
        XCTAssertTrue(script.contains("base64"))
    }

    func testSessionIdsThatCouldNameSomethingElseAreRefusedBeforeAnySshRuns() async {
        let runner = ScriptedSSHRunner()
        let reader = RemoteProviderTranscript(host: host, runner: runner, timeout: 1)
        for bad in ["", "../../../etc/passwd", "a b", "a;rm -rf /", "a/b"] {
            let result = await reader.resolve(RemoteTranscriptRequest(
                hostName: host.name, remoteCwd: "/srv/work", sessionID: bad,
                maximumBytes: limit))
            XCTAssertEqual(result, .unavailable(reason: "provider_session_invalid"), bad)
        }
        XCTAssertTrue(runner.commandLines.isEmpty)
    }

    // MARK: - Reading what came back

    func testAResolvedTranscriptCarriesItsContentAndItsFarSidePath() {
        let body = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        let result = parse(header(body.count, "/home/ci/.claude/projects/-srv-work/s.jsonl")
            + body.base64EncodedString() + "\n")
        guard case .resolved(let content, let path, let truncated) = result else {
            return XCTFail("expected a transcript, got \(result)")
        }
        XCTAssertEqual(content, "{\"a\":1}\n{\"b\":2}\n")
        XCTAssertEqual(path, "/home/ci/.claude/projects/-srv-work/s.jsonl")
        XCTAssertFalse(truncated)
    }

    func testWrappedBase64FromEitherEncoderDecodes() {
        // GNU `base64` wraps at 76 columns and macOS's does too; neither flag spelling
        // (`-w0`, `-b 0`) is portable, so the reader tolerates the newlines instead.
        let body = Data(String(repeating: "x", count: 300).utf8)
        let wrapped = body.base64EncodedString(options: [.lineLength64Characters,
                                                         .endLineWithLineFeed])
        let result = parse(header(body.count, "/p/s.jsonl") + wrapped + "\n")
        guard case .resolved(let content, _, _) = result else {
            return XCTFail("expected a transcript, got \(result)")
        }
        XCTAssertEqual(content.count, 300)
    }

    func testATruncatedTailDropsItsPartialFirstLine() {
        // A byte-bounded tail almost always starts mid-record. A half line at the top of
        // a JSONL pin is not a smaller transcript, it is a corrupt one.
        let body = Data("d\":2}\n{\"c\":3}\n".utf8)
        let result = parse(header(9_000_000, "/p/s.jsonl") + body.base64EncodedString() + "\n",
                           maximumBytes: body.count)
        guard case .resolved(let content, _, let truncated) = result else {
            return XCTFail("expected a transcript, got \(result)")
        }
        XCTAssertTrue(truncated)
        XCTAssertEqual(content, "{\"c\":3}\n")
    }

    func testBytesThatAreNotUTF8AreTypedNeverReplacementCharacters() {
        let body = Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0xE9, 0x22, 0x7D, 0x0A])
        XCTAssertEqual(parse(header(body.count, "/p/s.jsonl") + body.base64EncodedString() + "\n"),
                       .unavailable(reason: "provider_transcript_invalid_utf8"))
    }

    func testEachFarSideRefusalKeepsItsOwnName() {
        let cases: [(String, String)] = [
            ("ORCHARD-TX/1 no-cwd\n", "remote_working_directory_unavailable"),
            ("ORCHARD-TX/1 not-found\n", "provider_transcript_not_found"),
            // Two project folders hold a file with this session id. Picking one would be
            // a coin flip presented as evidence.
            ("ORCHARD-TX/1 ambiguous\n", "provider_transcript_ambiguous"),
            ("ORCHARD-TX/1 no-encoder\n", "remote_provider_transcript_unsupported"),
        ]
        for (stdout, reason) in cases {
            XCTAssertEqual(parse(stdout), .unavailable(reason: reason), stdout)
        }
    }

    func testAnAnswerWithNoProtocolHeaderIsUnverifiableNotNotFound() {
        // A login banner, a locale warning, a host that ran something else entirely:
        // "we could not look" is never "there is nothing there".
        XCTAssertEqual(parse("Welcome to Ubuntu\n"),
                       .unavailable(reason: "remote_provider_transcript_unverifiable"))
    }

    func testLossOfContactIsUnverifiableNotAMissingTranscript() async {
        let runner = ScriptedSSHRunner()
        runner.fallback = HostCommandResult(
            exitCode: 255, stderr: "client_loop: send disconnect: Broken pipe\n")
        let result = await RemoteProviderTranscript(host: host, runner: runner, timeout: 1)
            .resolve(RemoteTranscriptRequest(hostName: host.name, remoteCwd: "/srv/work",
                                             sessionID: "abc-123", maximumBytes: limit))
        XCTAssertEqual(result, .unavailable(reason: "remote_provider_transcript_unverifiable"))
    }

    func testARelativeRemoteDirectoryIsRefusedRatherThanResolvedAgainstSomeHome() async {
        let runner = ScriptedSSHRunner()
        let result = await RemoteProviderTranscript(host: host, runner: runner, timeout: 1)
            .resolve(RemoteTranscriptRequest(hostName: host.name, remoteCwd: "work",
                                             sessionID: "abc-123", maximumBytes: limit))
        XCTAssertEqual(result, .unavailable(reason: "remote_working_directory_unavailable"))
        XCTAssertTrue(runner.commandLines.isEmpty)
    }

    func testItReadsTheWholeRoundTripOverAScriptedSsh() async {
        let runner = ScriptedSSHRunner()
        let body = Data("{\"type\":\"user\"}\n".utf8)
        runner.fallback = HostCommandResult(
            exitCode: 0,
            stdout: header(body.count, "/home/ci/.claude/projects/-srv-work/abc-123.jsonl")
                + body.base64EncodedString() + "\n")
        let result = await RemoteProviderTranscript(host: host, runner: runner, timeout: 1)
            .resolve(RemoteTranscriptRequest(hostName: host.name, remoteCwd: "/srv/work",
                                             sessionID: "abc-123", maximumBytes: limit))
        guard case .resolved(let content, let path, _) = result else {
            return XCTFail("expected a transcript, got \(result)")
        }
        XCTAssertEqual(content, "{\"type\":\"user\"}\n")
        XCTAssertTrue(path.hasSuffix("abc-123.jsonl"))
        XCTAssertTrue(runner.ran("ORCHARD-TX/1"))
    }
}
