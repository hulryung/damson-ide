import Foundation
import OrchardTerminals

/// T82 (found while verifying T80): how a **supervised** worker whose engine is the
/// bare shell receives its dispatch contract.
///
/// `worker-start` used to type the agent preamble into the pane for every engine. In an
/// agent TUI that text is a prompt; in zsh it is *input*. The preamble's first
/// apostrophe opens a quote, zsh drops to its `quote>` continuation prompt, and the
/// whole paste — the live dispatch capability with it — sits in pending input: the
/// worker can never run its task, never send `worker_done`, and only a manual
/// `terminal send --interrupt` gets the shell back. Reproduced on a local *and* a
/// remote pane in docs/reports/t80-remote-dispatch-verification.md.
///
/// T60 solved the same shape for automation fires (`AutomationShellDispatch`), where
/// the task spec *is* a command line, so the fix could be "run it and report the exit
/// status". A supervised shell worker is the other half: its spec is prose for whoever
/// drives the pane, so the contract has to arrive as a **document**, not as work to
/// execute. This builds the one quote-balanced line that delivers it:
///
///   1. export the facts a lifecycle call needs — `ORCHARD_CLI_COMMAND`,
///      `ORCHARD_WORKER_HANDLE`, `ORCHARD_TASK_ID`, `ORCHARD_DISPATCH_ID`,
///      `ORCHARD_DISPATCH_CAPABILITY` — so `worker_done` is a one-liner that needs
///      nothing retyped out of the scrollback;
///   2. write the contract to `$ORCHARD_DISPATCH_CONTRACT` (mode 600 — it carries the
///      capability) so it outlives the pane's scroll ring and can be re-read;
///   3. print it, so the pane shows the contract the way an agent pane would;
///   4. return to a usable prompt with nothing pending.
///
/// The capability appears only inside the *submitted* line and the file that line
/// writes. The line is quote-balanced by construction for any contract text
/// (`AutomationShellDispatch.singleQuoted`, shared with T60's fire path), so there is
/// no input state in which it can be left dangling.
public enum ShellWorkerContract {
    /// The `dispatch_input` effect's `mode` for this delivery. The other two are
    /// `preamble` (typed into an agent TUI) and `shell-command` (T60's automation fire).
    public static let mode = "shell-contract"

    /// A fresh handshake nonce. Short on purpose: it rides in a probe line that has to
    /// stay far below the tty's canonical-mode line limit.
    public static func nonce() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// One short command whose **output differs from its echo**: the format holds `%s`
    /// and the nonce rides in the argument, so seeing `marker(nonce:)` in the pane's
    /// stream is proof the shell *ran* the line, not merely proof it was typed.
    ///
    /// This is the whole readiness protocol for a bare shell. The generic detector can
    /// only answer "has this pane stopped painting", which a shell satisfies while its
    /// startup files are still running — and input typed then is read by the tty in
    /// **canonical mode**, which drops everything past `MAX_CANON` (1024 bytes on
    /// Darwin) and would leave a contract's closing quote in the bit bucket.
    public static func readinessProbe(nonce: String) -> String {
        "printf 'orchard-shell-ready %s\\n' '\(nonce)'"
    }

    /// The output `readinessProbe(nonce:)` produces when it actually runs.
    public static func marker(nonce: String) -> String { "orchard-shell-ready \(nonce)" }

    /// Whether this engine needs the contract as a document instead of a typed prompt.
    ///
    /// Keyed on the engine's own answer (`usesLongRunningTUI`), not on a name list: an
    /// engine with no long-running TUI has a shell prompt behind it, and a shell prompt
    /// is exactly what prose cannot be typed into. An id the registry cannot resolve
    /// keeps the old behavior — `worker-start` could not have created that pane, so
    /// nothing is known about what lives there and inventing a shell line for it would
    /// be a guess.
    public static func needsShellContract(engineID: String) -> Bool {
        guard let engine = AgentEngineRegistry.engine(id: engineID) else { return false }
        return !engine.usesLongRunningTUI
    }

    /// The `ORCHARD_*` bindings the delivered line exports, in write order. These are
    /// the dispatch-scoped half of the pane identity: `OrchardIdentity` already put the
    /// pane-scoped half (handle, pane key, worktree, CLI, data path) in the PTY's
    /// environment at spawn, but a capability is minted per dispatch, after the pane
    /// exists, and can only reach it through the pane.
    public static func exports(cliCommand: String, workerHandle: String, taskID: String,
                               dispatchID: String, capability: String?) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("ORCHARD_CLI_COMMAND", cliCommand),
            ("ORCHARD_WORKER_HANDLE", workerHandle),
            ("ORCHARD_TASK_ID", taskID),
            ("ORCHARD_DISPATCH_ID", dispatchID),
        ]
        if let capability { rows.append(("ORCHARD_DISPATCH_CAPABILITY", capability)) }
        return rows
    }

    /// Where the contract is saved in the pane, as a shell word (`$TMPDIR` is resolved
    /// on the far side, which is the only machine that knows its own temp directory).
    /// The dispatch id is filtered to the characters it is actually minted from, so a
    /// hand-made id can never smuggle a path component or a quote into the word.
    public static func contractPath(dispatchID: String) -> String {
        let safe = String(dispatchID.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        return "${TMPDIR:-/tmp}/orchard-dispatch-\(safe.isEmpty ? "worker" : safe).txt"
    }

    /// The contract as the shell worker reads it: a short header saying how it arrived
    /// and what is already in the environment, then the ordinary worker preamble.
    ///
    /// The header is not decoration. A shell worker's first question after a 200-line
    /// paste is "is my prompt usable, or am I inside something?", and its second is
    /// "where did the capability go?" — both answered before the contract it must obey.
    public static func document(preamble: String) -> String {
        """
        === ORCHARD SHELL WORKER ===
        This contract reached you as one executable line: it exported your dispatch
        identity, saved this text, and printed it. Your shell is at a normal prompt with
        nothing pending — start work whenever you are ready.

          Saved at:  $ORCHARD_DISPATCH_CONTRACT  (re-read with: cat "$ORCHARD_DISPATCH_CONTRACT")
          Exported:  ORCHARD_CLI_COMMAND, ORCHARD_WORKER_HANDLE, ORCHARD_TASK_ID,
                     ORCHARD_DISPATCH_ID, ORCHARD_DISPATCH_CAPABILITY

        Every CLI example below is a real command line you can run as written. The same
        calls work from the exported variables, which is the shorter way to report:

          "$ORCHARD_CLI_COMMAND" send --from "$ORCHARD_WORKER_HANDLE" \\
            --dispatch-capability "$ORCHARD_DISPATCH_CAPABILITY" \\
            --type worker_done --subject "<short status>" \\
            --body "<3-sentence summary: what you did, what you found, what's left>" \\
            --task-id "$ORCHARD_TASK_ID" --dispatch-id "$ORCHARD_DISPATCH_ID" \\
            --outcome succeeded

        \(preamble)
        """
    }

    /// `printf '%b'` source for a multi-line document: escape every backslash, then
    /// every newline. Escaping backslashes *first* is what makes the round trip exact —
    /// after it, no `\n` / `\c` / `\0` sequence can survive from the document itself,
    /// so the only escapes `%b` can act on are the newlines put in deliberately.
    ///
    /// This is what keeps the delivered line a *single* line. A document embedded with
    /// its real newlines would still be quote-balanced, but a pane without bracketed
    /// paste would submit it line by line and sit at `quote>` until the closing quote
    /// arrived — the exact state T82 exists to make impossible, even transiently.
    static func printfEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The single submitted line that delivers `document(preamble:)` into a shell pane.
    ///
    /// Quote-balanced *and* newline-free for any contract text: the document travels
    /// inside one single-quoted assignment with every apostrophe rewritten to the
    /// `'\''` idiom and every newline encoded for `%b`.
    ///
    /// The file write is best-effort — `ORCHARD_DISPATCH_CONTRACT` is exported only if
    /// it succeeded, and the contract is printed from the variable either way, so a
    /// read-only `$TMPDIR` costs the worker a re-readable copy and nothing else.
    public static func commandLine(preamble: String, cliCommand: String,
                                   workerHandle: String, capability: String?,
                                   taskID: String, dispatchID: String,
                                   deliveryNonce: String) -> String {
        let quote = AutomationShellDispatch.singleQuoted
        var parts = [
            "orchard_dispatch_text=\(quote(printfEscaped(document(preamble: preamble))))",
            "orchard_dispatch_file=\"\(contractPath(dispatchID: dispatchID))\"",
        ]
        parts += exports(cliCommand: cliCommand, workerHandle: workerHandle, taskID: taskID,
                         dispatchID: dispatchID, capability: capability)
            .map { "export \($0.0)=\(quote($0.1))" }
        parts.append(
            "(umask 077; printf '%b\\n' \"$orchard_dispatch_text\" > \"$orchard_dispatch_file\") "
                + "&& export ORCHARD_DISPATCH_CONTRACT=\"$orchard_dispatch_file\"")
        parts.append("printf '%b\\n' \"$orchard_dispatch_text\"")
        parts.append("unset orchard_dispatch_text orchard_dispatch_file")
        // Last, and load-bearing: this marker only prints if the shell reached the end
        // of the line, so `worker-start` can prove the contract was delivered whole and
        // the prompt came back — instead of reporting `ready` for a pane that swallowed
        // a truncated paste and is sitting at a `quote>` continuation.
        parts.append(readinessProbe(nonce: deliveryNonce))
        return parts.joined(separator: "; ")
    }
}
