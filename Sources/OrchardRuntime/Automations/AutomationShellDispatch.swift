import Foundation
import OrchardProtocol

/// T60 (dogfood-4 findings 3 and 5): how an automation with a **shell provider**
/// is dispatched, and how the worker it starts settles.
///
/// The agent preamble is prose for an LLM. Typed into an interactive zsh it never
/// executes: the first apostrophe opens a quote, zsh sits at its `>` continuation
/// prompt, and the whole paste — including the live dispatch capability — stays in
/// the pane's pending input. So a shell-provider fire asks `worker-start` for
/// `dispatch-input shell-command` instead, and the pane receives **one executable
/// command line** built here:
///
///   1. the automation prompt runs as a shell command (inside `eval`, so a prompt
///      with a syntax error fails with a status instead of stranding the shell at
///      a continuation prompt), in the fresh worktree the fire created;
///   2. the exit status is reported back as this dispatch's `worker_done`
///      (`--outcome succeeded` for 0, `failed` otherwise) through the same
///      capability-bound CLI path an agent worker uses;
///   3. the shell exits.
///
/// Settlement semantics (the decided story for automation-fired workers):
///
/// - The dispatch settles on step 2 — identity-proven, before the PTY ends. The
///   T11 exit reconciler then sees an already-settled dispatch and does nothing.
/// - If step 2 cannot reach the runtime (CLI missing, socket gone) or the prompt
///   itself `exit`s the shell, the PTY still ends and the T11 reconciler fails the
///   dispatch (`worker_process_exited`), with the usual escalation into the Run's
///   mailbox. Either way **a shell worker settles on process exit**; it can never
///   stay `dispatched` forever the way an unsubmitted paste did.
/// - Nothing is auto-released: the exited pane keeps the command's output until
///   `worker-release --dispatch <id>` archives the tail and closes it
///   (`closed_exited_terminal`), and `worktree rm` removes the worktree. The
///   automation's history row carries `dispatchId` / `orchestrationRunId` so both
///   are one command away.
/// - Agent providers (claude-code, codex, …) are unchanged: they get the ordinary
///   preamble and settle when the agent sends `worker_done`.
///
/// The capability appears only inside the submitted line (as it appears inside a
/// submitted agent preamble); it is never left in un-submitted input, because the
/// line is quote-balanced by construction (`singleQuoted`) whatever the prompt is.
public enum AutomationShellDispatch {
    /// `worker-start` param naming the dispatch-input mode.
    public static let workerStartParam = "dispatch-input"
    /// The ordinary agent preamble (default).
    public static let preambleMode = "preamble"
    /// One executable command line (shell providers only).
    public static let shellCommandMode = "shell-command"

    /// Whether an automation `provider` names the bare shell engine.
    public static func isShellProvider(_ provider: String) -> Bool {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "shell"
    }

    /// Read + validate the `worker-start` param. `nil`/`preamble` → false;
    /// `shell-command` → true, but only for `--agent shell` — any other engine would
    /// receive a shell line as a chat prompt, so it is refused typed before a
    /// worktree or terminal exists.
    static func wantsShellCommand(_ p: [String: JSONValue], agentID: String?) throws -> Bool {
        guard let mode = p[workerStartParam]?.stringValue else { return false }
        switch mode {
        case preambleMode:
            return false
        case shellCommandMode:
            guard let agentID, isShellProvider(agentID) else {
                throw RPCServiceError(
                    code: "invalid_argument",
                    message: "--\(workerStartParam) \(shellCommandMode) requires --agent shell (got '\(agentID ?? "terminal")').")
            }
            return true
        default:
            throw RPCServiceError(
                code: "invalid_argument",
                message: "--\(workerStartParam) must be \(preambleMode)|\(shellCommandMode) (got '\(mode)').")
        }
    }

    /// The self-settling command line. Quote-balanced for any `prompt` (a
    /// multi-line prompt stays inside one single-quoted `eval` argument).
    public static func commandLine(prompt: String, cliCommand: String, workerHandle: String,
                                   capability: String?, taskID: String, dispatchID: String) -> String {
        let capabilityFlag = capability.map { " --dispatch-capability \(singleQuoted($0))" } ?? ""
        let body = "The automation prompt ran as a shell command in $PWD and exited with status "
            + "$orchard_automation_status. Its output stayed in this terminal; worker-release "
            + "archives the tail and closes the pane. The shell exits now."
        return "orchard_automation_command() { eval \(singleQuoted(prompt)); }; "
            + "orchard_automation_command; orchard_automation_status=$?; "
            + "unset -f orchard_automation_command; "
            + "if [ \"$orchard_automation_status\" -eq 0 ]; then orchard_automation_outcome=succeeded; "
            + "else orchard_automation_outcome=failed; fi; "
            + "\(singleQuoted(cliCommand)) send --from \(singleQuoted(workerHandle))\(capabilityFlag) "
            + "--type worker_done --subject \"automation command exited $orchard_automation_status\" "
            + "--body \"\(body)\" "
            + "--task-id \(singleQuoted(taskID)) --dispatch-id \(singleQuoted(dispatchID)) "
            + "--outcome \"$orchard_automation_outcome\"; "
            + "exit \"$orchard_automation_status\""
    }

    /// POSIX single-quoting: every `'` becomes `'\''`. Safe for any text in sh,
    /// bash, and zsh — no expansion, no continuation, newlines carried literally.
    public static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
