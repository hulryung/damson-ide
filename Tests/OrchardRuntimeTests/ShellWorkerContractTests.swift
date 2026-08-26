import XCTest
import OrchardOrchestration
import OrchardProtocol
@testable import OrchardRuntime

/// T82: a supervised shell worker's contract arrives as one submitted line that leaves
/// the pane at a usable prompt — never as prose typed into zsh, which is what stranded
/// both the local and the remote shell worker in T80's live verification.
final class ShellWorkerContractTests: XCTestCase {
    private static let cli = "/Applications/Orchard.app/Contents/Helpers/orchard"

    /// A real preamble, with a task spec chosen to break naive quoting.
    private func preamble(spec: String = "Fix it: don't `eval` $USER's 100% \\ path\nsecond line 'quoted'",
                          capability: String? = "dcap_secret-1") -> String {
        DispatchPreamble.build(DispatchPreamble.Params(
            taskID: "task_1", dispatchID: "ctx_1", dispatchCapability: capability,
            taskSpec: spec, coordinatorHandle: "term_coord", workerHandle: "term_worker",
            cliCommand: Self.cli, workerKind: .bareShell))
    }

    private func line(capability: String? = "dcap_secret-1") -> String {
        ShellWorkerContract.commandLine(
            preamble: preamble(capability: capability), cliCommand: Self.cli,
            workerHandle: "term_worker", capability: capability,
            taskID: "task_1", dispatchID: "ctx_1", deliveryNonce: "nonce123")
    }

    // MARK: - Shape

    func testDeliveredLineIsASingleLineZshCanParse() throws {
        let text = line()
        XCTAssertFalse(text.contains("\n"),
                       "a newline would submit a partial command and open a `quote>` prompt")
        XCTAssertEqual(try Self.zshParseStatus(text), 0, "zsh could not parse the delivered line")
        XCTAssertNotEqual(try Self.zshParseStatus("echo 'unterminated"), 0,
                          "sanity: zsh -n reports parse errors")
        // The contract is data the line writes, never work the line runs.
        XCTAssertFalse(text.contains("eval "), "a supervised spec is prose, not a command line")
        XCTAssertTrue(text.contains("unset orchard_dispatch_text orchard_dispatch_file"),
                      "the line must leave no scratch variables behind")
        XCTAssertTrue(text.hasSuffix(ShellWorkerContract.readinessProbe(nonce: "nonce123")),
                      "the delivery marker must be the last thing the line does")
        XCTAssertFalse(text.contains(ShellWorkerContract.marker(nonce: "nonce123")),
                       "an echo of the line must never look like the line having run")
    }

    func testEngineDecidesTheDeliveryShapeNotTheCallersSpelling() {
        XCTAssertTrue(ShellWorkerContract.needsShellContract(engineID: "shell"))
        XCTAssertTrue(ShellWorkerContract.needsShellContract(engineID: " Shell "))
        XCTAssertFalse(ShellWorkerContract.needsShellContract(engineID: "claude-code"))
        XCTAssertFalse(ShellWorkerContract.needsShellContract(engineID: "claude"),
                       "an alias resolves to the TUI engine it names")
        XCTAssertFalse(ShellWorkerContract.needsShellContract(engineID: "codex"))
        XCTAssertFalse(ShellWorkerContract.needsShellContract(engineID: "not-an-engine"),
                       "an unresolvable id keeps today's behavior rather than guessing")
    }

    func testCapabilityIsOptionalAndNeverLeftUnquoted() {
        let withNone = line(capability: nil)
        XCTAssertFalse(withNone.contains("ORCHARD_DISPATCH_CAPABILITY='"),
                       "nothing to export when no capability was minted")
        XCTAssertTrue(line().contains("export ORCHARD_DISPATCH_CAPABILITY='dcap_secret-1'"))
    }

    func testContractPathIsOneShellWordWhateverTheDispatchIdLooksLike() {
        XCTAssertEqual(ShellWorkerContract.contractPath(dispatchID: "ctx_abc-1"),
                       "${TMPDIR:-/tmp}/orchard-dispatch-ctx_abc-1.txt")
        XCTAssertEqual(ShellWorkerContract.contractPath(dispatchID: "../../etc/pas'swd"),
                       "${TMPDIR:-/tmp}/orchard-dispatch-etcpasswd.txt")
        XCTAssertEqual(ShellWorkerContract.contractPath(dispatchID: "///"),
                       "${TMPDIR:-/tmp}/orchard-dispatch-worker.txt")
    }

    func testPrintfEscapingRoundTripsBackslashesBeforeNewlines() {
        // `\n` typed literally in a task spec must stay two characters, and the real
        // newline around it must become the escape — the order of the two replacements
        // is the whole correctness argument.
        XCTAssertEqual(ShellWorkerContract.printfEscaped("a\\nb\nc"), "a\\\\nb\\nc")
        XCTAssertEqual(ShellWorkerContract.printfEscaped("\\c"), "\\\\c",
                       "%b would truncate the output at a surviving \\c")
    }

    // MARK: - Behavior under a real zsh

    /// The line really runs: under zsh it prints the contract, saves a private copy,
    /// exports the dispatch identity, and comes back with a zero status and a clean
    /// environment — the "usable prompt" half of the acceptance, in a unit test.
    func testLineExecutesUnderZshPrintingAndSavingTheContract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = ["ORCHARD_CLI_COMMAND", "ORCHARD_WORKER_HANDLE", "ORCHARD_TASK_ID",
                     "ORCHARD_DISPATCH_ID", "ORCHARD_DISPATCH_CAPABILITY",
                     "ORCHARD_DISPATCH_CONTRACT", "orchard_dispatch_text"]
            .map { "printf '%s=%s\\n' \($0) \"$\($0)\" >> \"$TMPDIR/env.txt\"" }
            .joined(separator: "; ")

        let out = root.appendingPathComponent("stdout.txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "\(line()); \(probe)"]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = root.path
        process.environment = environment
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let printed = try String(contentsOf: out, encoding: .utf8)
        let document = ShellWorkerContract.document(preamble: preamble())
        XCTAssertEqual(printed, document + "\n" + ShellWorkerContract.marker(nonce: "nonce123") + "\n",
                       "the pane must show the contract verbatim, then the delivery marker")
        XCTAssertTrue(printed.contains("=== TASK ==="))
        XCTAssertTrue(printed.contains("Fix it: don't `eval` $USER's 100% \\ path"),
                      "a hostile spec survives the round trip unexpanded")
        XCTAssertTrue(printed.contains("--dispatch-capability dcap_secret-1"))

        let environmentRows = try String(contentsOf: root.appendingPathComponent("env.txt"),
                                         encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertTrue(environmentRows.contains("ORCHARD_CLI_COMMAND=\(Self.cli)"), environmentRows.description)
        XCTAssertTrue(environmentRows.contains("ORCHARD_WORKER_HANDLE=term_worker"))
        XCTAssertTrue(environmentRows.contains("ORCHARD_TASK_ID=task_1"))
        XCTAssertTrue(environmentRows.contains("ORCHARD_DISPATCH_ID=ctx_1"))
        XCTAssertTrue(environmentRows.contains("ORCHARD_DISPATCH_CAPABILITY=dcap_secret-1"))
        XCTAssertTrue(environmentRows.contains("orchard_dispatch_text="),
                      "the scratch variable must be unset, not left holding the capability")

        let saved = root.appendingPathComponent("orchard-dispatch-ctx_1.txt")
        XCTAssertTrue(environmentRows.contains("ORCHARD_DISPATCH_CONTRACT=\(saved.path)"))
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), document + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "the saved contract carries a live capability")
    }

    /// The exported identity is enough on its own: the one-liner the header advertises
    /// reaches the CLI with the right argv, so a worker never has to retype a
    /// capability out of the scrollback.
    func testExportedIdentityMakesWorkerDoneAOneLiner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("orchard stub")   // a space, on purpose
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv.txt\"\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let delivered = ShellWorkerContract.commandLine(
            preamble: preamble(), cliCommand: stub.path, workerHandle: "term_worker",
            capability: "dcap_secret-1", taskID: "task_1", dispatchID: "ctx_1",
            deliveryNonce: "nonce123")
        let report = """
        "$ORCHARD_CLI_COMMAND" send --from "$ORCHARD_WORKER_HANDLE" \
        --dispatch-capability "$ORCHARD_DISPATCH_CAPABILITY" --type worker_done \
        --subject done --body body --task-id "$ORCHARD_TASK_ID" \
        --dispatch-id "$ORCHARD_DISPATCH_ID" --outcome succeeded
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "\(delivered) >/dev/null; \(report)"]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = root.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let argv = try String(contentsOf: root.appendingPathComponent("argv.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(argv.first, "send")
        XCTAssertEqual(argv[argv.firstIndex(of: "--from")! + 1], "term_worker")
        XCTAssertEqual(argv[argv.firstIndex(of: "--dispatch-capability")! + 1], "dcap_secret-1")
        XCTAssertEqual(argv[argv.firstIndex(of: "--task-id")! + 1], "task_1")
        XCTAssertEqual(argv[argv.firstIndex(of: "--dispatch-id")! + 1], "ctx_1")
        XCTAssertEqual(argv[argv.firstIndex(of: "--outcome")! + 1], "succeeded")
    }

    /// The readiness protocol's one invariant: the probe's echo and the probe's output
    /// are different strings, so a pane that merely *received* the probe can never be
    /// mistaken for one that ran it.
    func testReadinessProbeOutputCannotBeConfusedWithItsEcho() throws {
        let probe = ShellWorkerContract.readinessProbe(nonce: "abc12345")
        let marker = ShellWorkerContract.marker(nonce: "abc12345")
        XCTAssertFalse(probe.contains(marker))
        XCTAssertFalse(probe.contains("\n"), "the probe must fit in one canonical-mode line")
        XCTAssertLessThan(probe.utf8.count, 128,
                          "the probe has to survive a tty that is still in canonical mode")
        XCTAssertEqual(try Self.zshParseStatus(probe), 0)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out.txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", probe]
        process.standardOutput = try FileHandle(forWritingTo: out)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), marker + "\n")
    }

    /// Nonces are per-probe: two starts (or two probes inside one start) can never have
    /// one answer satisfy the other.
    func testNoncesAreDistinctAndShellSafe() {
        let nonces = (0..<32).map { _ in ShellWorkerContract.nonce() }
        XCTAssertEqual(Set(nonces).count, nonces.count)
        for nonce in nonces {
            XCTAssertEqual(nonce.count, 8)
            XCTAssertTrue(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase }, nonce)
        }
    }

    private static func zshParseStatus(_ line: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", "-c", line]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
