import Foundation

/// Runs a project's `orchard.yaml` setup script inside a freshly-created worktree.
///
/// The script is written to a file and executed rather than passed with `bash -c`: setup
/// scripts are multi-line, frequently contain quotes and `$(…)`, and inlining them into an
/// argument is where quoting bugs live. A real file also means `set -e` behaves the way the
/// author expects and the failing line number in the output means something.
public enum SetupRunner {
    public struct Result: Sendable {
        public let succeeded: Bool
        /// Combined stdout+stderr, trimmed — surfaced verbatim when setup fails, because a
        /// failed install is only actionable if the user can see what the installer said.
        public let output: String
    }

    /// Wall-clock ceiling. A dependency install can legitimately take minutes; an unbounded
    /// wait would leave the worktree stuck in `.running` forever if the script hangs waiting
    /// on input that will never come.
    public static let timeout: TimeInterval = 600

    public static func run(script: String, in worktree: URL,
                           environment: [String: String]) -> Result {
        let scriptURL = worktree.appendingPathComponent(".orchard-setup.sh")
        // `set -e` so the first failing command aborts instead of letting a broken setup
        // report success from whatever ran last.
        let body = "#!/usr/bin/env bash\nset -eo pipefail\n\(script)\n"

        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptURL.path)
        } catch {
            return Result(succeeded: false, output: "could not write setup script: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-l", scriptURL.path]
        proc.currentDirectoryURL = worktree

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        // A setup script is unattended automation: never let a git operation inside it pop a
        // credential dialog the user isn't there to answer.
        env["GIT_TERMINAL_PROMPT"] = "0"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // Nothing is going to type at this script; give it EOF immediately rather than
        // letting a stray `read` block until the timeout.
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return Result(succeeded: false, output: "could not launch setup script: \(error)")
        }

        // Drain on a worker so a script that outputs more than the pipe buffer can't deadlock.
        var collected = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if drained.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if drained.wait(timeout: .now() + 3) == .timedOut, proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                _ = drained.wait(timeout: .now() + 3)
            }
            return Result(succeeded: false,
                          output: "setup script timed out after \(Int(timeout))s")
        }
        proc.waitUntilExit()

        let output = String(decoding: collected, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(succeeded: proc.terminationStatus == 0, output: output)
    }
}
