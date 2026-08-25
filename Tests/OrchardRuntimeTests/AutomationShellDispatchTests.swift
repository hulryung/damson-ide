import XCTest
import OrchardProtocol
@testable import OrchardRuntime

/// T60 (dogfood-4 finding 3): the shell-provider dispatch line executes the prompt,
/// reports worker_done with the exit status, and exits — and is quote-balanced for
/// any prompt, so no fire can leave the capability in un-submitted pane input.
final class AutomationShellDispatchTests: XCTestCase {
    private func line(prompt: String, capability: String? = "dcap_secret-1") -> String {
        AutomationShellDispatch.commandLine(
            prompt: prompt, cliCommand: "/Applications/Orchard.app/Contents/Helpers/orchard",
            workerHandle: "term_1", capability: capability, taskID: "task_1", dispatchID: "ctx_1")
    }

    func testCommandLineRunsPromptReportsStatusAndExits() {
        let text = line(prompt: "swift test")
        XCTAssertTrue(text.contains("eval 'swift test'"))
        XCTAssertTrue(text.contains("--type worker_done"))
        XCTAssertTrue(text.contains("--dispatch-capability 'dcap_secret-1'"))
        XCTAssertTrue(text.contains("--task-id 'task_1' --dispatch-id 'ctx_1'"))
        XCTAssertTrue(text.contains("'/Applications/Orchard.app/Contents/Helpers/orchard' send --from 'term_1'"))
        XCTAssertTrue(text.contains("orchard_automation_outcome=succeeded"))
        XCTAssertTrue(text.contains("orchard_automation_outcome=failed"))
        XCTAssertTrue(text.hasSuffix("exit \"$orchard_automation_status\""))
        XCTAssertFalse(text.contains("=== TASK ==="), "the agent preamble must not be typed into a shell")
        XCTAssertFalse(text.contains("\n"), "a single-line prompt yields a single submitted line")
    }

    func testQuotingKeepsAnyPromptInsideOneQuotedArgument() {
        let hostile = "echo 'it''s' \"done\" $(date) `id` && printf '%s\\n' \\\n  line2 # it's"
        let text = line(prompt: hostile)
        let quoted = AutomationShellDispatch.singleQuoted(hostile)
        XCTAssertTrue(text.contains("eval \(quoted);"))
        // Every apostrophe in the prompt becomes the '\'' idiom, so the quote count
        // outside the idiom stays balanced and zsh never waits at a `quote>` prompt.
        XCTAssertEqual(quoted, "'echo '\\''it'\\'''\\''s'\\'' \"done\" $(date) `id` && printf '\\''%s\\n'\\'' \\\n  line2 # it'\\''s'")
        // The proof that matters: zsh parses the whole line without executing it —
        // no `quote>` continuation, nothing left pending.
        XCTAssertEqual(try Self.zshParseStatus(text), 0, "zsh could not parse: \(text)")
        XCTAssertNotEqual(try Self.zshParseStatus("echo 'unterminated"), 0, "sanity: zsh -n reports parse errors")
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

    func testCapabilityIsOptionalAndProviderDetectionIsExact() {
        let text = line(prompt: "true", capability: nil)
        XCTAssertFalse(text.contains("--dispatch-capability"))
        XCTAssertTrue(AutomationShellDispatch.isShellProvider("shell"))
        XCTAssertTrue(AutomationShellDispatch.isShellProvider(" Shell "))
        XCTAssertFalse(AutomationShellDispatch.isShellProvider("claude-code"))
    }

    func testWorkerStartParamIsValidatedAgainstTheEngine() throws {
        XCTAssertFalse(try AutomationShellDispatch.wantsShellCommand([:], agentID: "shell"))
        XCTAssertFalse(try AutomationShellDispatch.wantsShellCommand(
            ["dispatch-input": .string("preamble")], agentID: "claude-code"))
        XCTAssertTrue(try AutomationShellDispatch.wantsShellCommand(
            ["dispatch-input": .string("shell-command")], agentID: "shell"))
        XCTAssertThrowsError(try AutomationShellDispatch.wantsShellCommand(
            ["dispatch-input": .string("shell-command")], agentID: "claude-code")) { error in
            XCTAssertEqual((error as? RPCServiceError)?.rpcError.code, "invalid_argument")
        }
        XCTAssertThrowsError(try AutomationShellDispatch.wantsShellCommand(
            ["dispatch-input": .string("shell-command")], agentID: nil))
        XCTAssertThrowsError(try AutomationShellDispatch.wantsShellCommand(
            ["dispatch-input": .string("paste")], agentID: "shell"))
    }

    /// The line really executes: run it through zsh with a stub `orchard` that records
    /// its argv, and check the prompt ran, worker_done carried the exit status, and the
    /// shell exited with that status.
    func testCommandLineExecutesUnderZshWithAStubCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("orchard stub")   // a space, on purpose
        try #"#!/bin/sh\nprintf '%s\n' "$@" > "$(dirname "$0")/argv.txt"\n"#
            .replacingOccurrences(of: "\\n", with: "\n")
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        for (prompt, expectedStatus, expectedOutcome) in [
            ("printf 'ran %s\\n' \"it's\" > \"$PWD/out.txt\"", 0, "succeeded"),
            ("echo 'unterminated", 1, "failed"),
            ("exit 7", 7, "failed"),
        ] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("argv.txt"))
            let text = AutomationShellDispatch.commandLine(
                prompt: prompt, cliCommand: stub.path, workerHandle: "term_z",
                capability: "dcap_z", taskID: "task_z", dispatchID: "ctx_z")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", text]
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if prompt.hasPrefix("exit") {
                // The prompt itself left the shell: no worker_done, but the PTY ended
                // (the T11 reconciler settles that case) and the status is honest.
                XCTAssertEqual(process.terminationStatus, Int32(expectedStatus))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("argv.txt").path))
                continue
            }
            XCTAssertEqual(process.terminationStatus, Int32(expectedStatus), prompt)
            let argv = try String(contentsOf: root.appendingPathComponent("argv.txt"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            XCTAssertEqual(argv.first, "send", prompt)
            XCTAssertTrue(argv.contains("worker_done"), prompt)
            XCTAssertTrue(argv.contains("dcap_z"), prompt)
            XCTAssertEqual(argv[argv.firstIndex(of: "--outcome")! + 1], expectedOutcome, prompt)
            XCTAssertEqual(argv[argv.firstIndex(of: "--subject")! + 1],
                           "automation command exited \(expectedStatus)", prompt)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8),
                       "ran it's\n")
    }
}
