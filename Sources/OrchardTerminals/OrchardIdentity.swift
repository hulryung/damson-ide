import Foundation

/// The five `ORCHARD_*` facts a managed pane's far-side process needs in order to
/// find itself and call the runtime back (docs/REBUILD-PLAN.md).
///
/// Locally these land in the PTY child's environment. For a remote pane that child
/// is `ssh`, which does not forward arbitrary variables (that would need `SendEnv`
/// plus a matching `AcceptEnv` on sshd). The identity therefore has to travel in
/// the remote command line: `ssh … dest 'export ORCHARD_…=…; <far-side command>'`.
/// Wrapping lives here — not in the host/SSH builders — because the handle and
/// pane key are minted at spawn, after those builders have already produced argv.
public enum OrchardIdentity {
    public static let variableNames = [
        "ORCHARD_TERMINAL_HANDLE",
        "ORCHARD_PANE_KEY",
        "ORCHARD_WORKTREE_ID",
        "ORCHARD_CLI_COMMAND",
        "ORCHARD_DATA_PATH",
    ]

    /// A login shell that inherits the exports above. Same `${SHELL:-/bin/sh}`
    /// fallback `SSHCommand.cdAndLoginShellCommand` uses, so a host with no `SHELL`
    /// still has something to exec.
    public static let loginShell = "exec \"${SHELL:-/bin/sh}\" -l"

    public static func bindings(handle: String, paneKey: String, worktreeId: String?,
                                context: TerminalHostContext) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("ORCHARD_TERMINAL_HANDLE", handle),
            ("ORCHARD_PANE_KEY", paneKey),
        ]
        if let worktreeId { rows.append(("ORCHARD_WORKTREE_ID", worktreeId)) }
        if let cli = context.cliCommand { rows.append(("ORCHARD_CLI_COMMAND", cli)) }
        if let dataPath = context.dataPath { rows.append(("ORCHARD_DATA_PATH", dataPath)) }
        return rows
    }

    public static func bindings(spec: TerminalCreateSpec,
                                context: TerminalHostContext) -> [(String, String)] {
        bindings(handle: spec.handle, paneKey: spec.paneKey,
                 worktreeId: spec.worktreeId, context: context)
    }

    public static func apply(_ bindings: [(String, String)],
                             to env: inout [String: String]) {
        for (key, value) in bindings { env[key] = value }
    }

    /// `export NAME=value; export NAME=value` — values quoted with the same rules
    /// `EngineLaunch` uses so a space in `ORCHARD_DATA_PATH` cannot split the command.
    public static func exportAssignments(_ bindings: [(String, String)]) -> String {
        bindings.map { "export \($0.0)=\(EngineLaunch.shellQuote($0.1))" }
            .joined(separator: "; ")
    }

    /// Prefix `command` with the exports. `nil` / empty becomes a login shell, which
    /// is the far-side of a bare `ssh dest` pane (T29).
    ///
    /// Idempotent: a command that already starts with our `export ORCHARD_*=` run is
    /// stripped and rewritten, so a reconnect or respawn that somehow recorded a
    /// previously wrapped argv does not accumulate prefixes. The new handle wins.
    public static func wrapCommand(_ command: String?,
                                   bindings: [(String, String)]) -> String {
        let body = strippingExistingExports(
            command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let farSide = body.isEmpty ? loginShell : body
        guard !bindings.isEmpty else { return farSide }
        return "\(exportAssignments(bindings)); \(farSide)"
    }

    /// Rewrite a local argv so the remote command carries the identity.
    ///
    /// Two shapes the factory actually produces:
    ///
    /// - a remote *agent* pane: `[/usr/bin/ssh, -tt, (-R …), dest, <remote command>]`
    /// - a remote *shell* pane: `[<login-shell>, -l, -c, "/usr/bin/ssh -tt dest '…'"]`
    ///
    /// A dest-only `ssh` (no remote command) gets one appended — otherwise there is
    /// nowhere to put the exports, and sshd would start a login shell that never
    /// sees them.
    public static func carryThroughSSH(argv: [String],
                                       bindings: [(String, String)]) -> [String] {
        guard !bindings.isEmpty, !argv.isEmpty else { return argv }
        if isSSHBinary(argv[0]) {
            return injectIntoSSHArgv(argv, bindings: bindings)
        }
        if let flag = commandFlagIndex(argv), argv.indices.contains(flag + 1),
           looksLikeSSHCommandLine(argv[flag + 1]) {
            var out = argv
            out[flag + 1] = injectIntoSSHCommandLine(argv[flag + 1], bindings: bindings)
            return out
        }
        return argv
    }

    // MARK: - Export-prefix surgery

    public static func strippingExistingExports(_ command: String) -> String {
        var rest = command
        while let next = dropOneLeadingExport(rest) {
            rest = next
        }
        return rest
    }

    /// `export ORCHARD_NAME=value;` plus following whitespace. Quoted values use the
    /// same `'\''` encoding `EngineLaunch.shellQuote` writes.
    private static func dropOneLeadingExport(_ command: String) -> String? {
        guard command.hasPrefix("export ORCHARD_") else { return nil }
        var i = command.index(command.startIndex, offsetBy: "export ".count)
        guard let eq = command[i...].firstIndex(of: "=") else { return nil }
        i = command.index(after: eq)
        if i < command.endIndex, command[i] == "'" {
            i = command.index(after: i)
            while i < command.endIndex {
                if command[i] == "'" {
                    let afterQuote = command.index(after: i)
                    // `'\''` — close, escaped quote, reopen.
                    if afterQuote < command.endIndex, command[afterQuote] == "\\",
                       command.index(after: afterQuote) < command.endIndex,
                       command[command.index(after: afterQuote)] == "'" {
                        i = command.index(after: command.index(after: afterQuote))
                        continue
                    }
                    i = afterQuote
                    break
                }
                i = command.index(after: i)
            }
        } else {
            while i < command.endIndex, command[i] != ";" {
                i = command.index(after: i)
            }
        }
        guard i < command.endIndex, command[i] == ";" else { return nil }
        i = command.index(after: i)
        while i < command.endIndex, command[i].isWhitespace {
            i = command.index(after: i)
        }
        return String(command[i...])
    }

    // MARK: - ssh argv / command-line

    private static func injectIntoSSHArgv(_ argv: [String],
                                          bindings: [(String, String)]) -> [String] {
        if let index = sshRemoteCommandIndex(argv) {
            var out = argv
            out[index] = wrapCommand(argv[index], bindings: bindings)
            return out
        }
        return argv + [wrapCommand(nil, bindings: bindings)]
    }

    private static func injectIntoSSHCommandLine(_ line: String,
                                                 bindings: [(String, String)]) -> String {
        injectIntoSSHArgv(tokenizeCommandLine(line), bindings: bindings)
            .map(EngineLaunch.shellQuote)
            .joined(separator: " ")
    }

    static func isSSHBinary(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "ssh"
    }

    /// Index of the remote command in an OpenSSH argv, or nil when the last
    /// non-option is the destination (a bare login).
    ///
    /// Mirrors how we build argv (`ssh -tt [options…] dest [command]`). Combined
    /// flags (`-tt`) and attached arguments (`-p2200`, `-oBatchMode=yes`) are
    /// walked the way OpenSSH itself splits them, so a `-R` we inserted is not
    /// mistaken for the destination.
    static func sshRemoteCommandIndex(_ argv: [String]) -> Int? {
        var i = 1
        while i < argv.count {
            let token = argv[i]
            if token == "--" {
                let dest = i + 1
                return dest + 1 < argv.count ? dest + 1 : nil
            }
            if token.hasPrefix("-"), token.count >= 2, !token.hasPrefix("--") {
                i += sshOptionStride(token)
                continue
            }
            if token.hasPrefix("--") {
                i += 1
                continue
            }
            return i + 1 < argv.count ? i + 1 : nil
        }
        return nil
    }

    /// How many argv slots this option token occupies, including itself.
    private static func sshOptionStride(_ token: String) -> Int {
        let flags = token.dropFirst()
        for (offset, ch) in flags.enumerated() {
            guard sshOptionsWithArgument.contains(ch) else { continue }
            // Attached argument (`-p2200`) lives in this token.
            if offset < flags.count - 1 { return 1 }
            return 2
        }
        return 1
    }

    /// OpenSSH single-letter options that consume the next argv word.
    private static let sshOptionsWithArgument: Set<Character> = [
        "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l",
        "m", "O", "o", "p", "Q", "R", "S", "W", "w",
    ]

    private static func commandFlagIndex(_ argv: [String]) -> Int? {
        argv.firstIndex(where: { $0 == "-c" || $0 == "-lc" || $0 == "-cl" })
    }

    static func looksLikeSSHCommandLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = tokenizeCommandLine(trimmed).first else { return false }
        return isSSHBinary(first)
    }

    /// Split a command line the way `EngineLaunch.shellQuote` / `SSHCommand.shellQuote`
    /// produce one: whitespace, single quotes, and the `'\''` embedding for a literal
    /// quote. Enough to take our own ssh command lines apart and put them back.
    static func tokenizeCommandLine(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var i = line.startIndex
        var inSingle = false
        var inDouble = false
        while i < line.endIndex {
            let ch = line[i]
            if inSingle {
                if ch == "'" { inSingle = false }
                else { current.append(ch) }
                i = line.index(after: i)
                continue
            }
            if inDouble {
                if ch == "\"" {
                    inDouble = false
                    i = line.index(after: i)
                    continue
                }
                if ch == "\\" {
                    let next = line.index(after: i)
                    if next < line.endIndex {
                        current.append(line[next])
                        i = line.index(after: next)
                        continue
                    }
                }
                current.append(ch)
                i = line.index(after: i)
                continue
            }
            if ch == "'" { inSingle = true; i = line.index(after: i); continue }
            if ch == "\"" { inDouble = true; i = line.index(after: i); continue }
            if ch == "\\" {
                let next = line.index(after: i)
                if next < line.endIndex {
                    current.append(line[next])
                    i = line.index(after: next)
                    continue
                }
            }
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                i = line.index(after: i)
                continue
            }
            current.append(ch)
            i = line.index(after: i)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
