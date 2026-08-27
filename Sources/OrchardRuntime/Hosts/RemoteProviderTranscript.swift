import Foundation

/// What a remote pane needs to have its provider transcript resolved on the far side.
///
/// Every field is read off the pane, never re-derived: the directory is the one the
/// pane's `ssh` actually `cd`s into, and the session id is the one the agent itself
/// reported through its hook channel. Guessing either is how a worker's evidence ends
/// up being some unrelated session's file.
public struct RemoteTranscriptRequest: Sendable, Equatable {
    public let hostName: String
    /// The worktree directory **on the far side**.
    public let remoteCwd: String
    /// The provider's own session id, as hook-attested.
    public let sessionID: String
    public let maximumBytes: Int

    public init(hostName: String, remoteCwd: String, sessionID: String, maximumBytes: Int) {
        self.hostName = hostName
        self.remoteCwd = remoteCwd
        self.sessionID = sessionID
        self.maximumBytes = maximumBytes
    }
}

/// Reads a remote agent's provider transcript over the host connection.
///
/// This closes the last refusal T39 left standing. `worker-read --source transcript`
/// answered `remote_provider_transcript_unsupported` for every remote pane, for a good
/// reason: the resolver read `~/.claude/projects` on *this* machine, and a remote pane's
/// local cwd is only where `ssh` was launched from — so it would have found nothing, or
/// worse, pinned an unrelated local session's transcript and labelled it this worker's
/// evidence. T85 built the transport that makes the honest version possible; this is
/// the same idea at a path that is not under the worktree root.
///
/// Three properties are kept exactly as the local resolver has them, because a
/// transcript that means something different depending on which machine it came from
/// would be worse than none:
///
/// - **Bytes, not text.** The far side base64-encodes the tail, so a transcript with a
///   byte sequence that is not UTF-8 comes back as `provider_transcript_invalid_utf8`
///   rather than as replacement characters pretending to be the agent's words.
/// - **A whole first line.** A byte-bounded tail almost always starts mid-record; the
///   partial line is dropped, here as locally, so the pin is parseable JSONL.
/// - **Rule 2.** A host that does not answer is `remote_provider_transcript_unverifiable`,
///   never `provider_transcript_not_found`. "We could not look" is not "there is
///   nothing there", and for a worker's evidence that difference is the whole point.
public struct RemoteProviderTranscript: Sendable {
    private let runner: SSHRunner

    /// Bounded well below `SSHRunner.defaultTimeout`: this is a `tail` and a base64 of
    /// at most a couple of megabytes, and `worker-release` must not sit on it.
    public static let defaultTimeout: TimeInterval = 30

    public init(runner: SSHRunner) {
        self.runner = runner
    }

    public init(host: HostRecord, runner: HostCommandRunner = ProcessHostCommandRunner(),
                connection: RemoteConnection? = nil,
                timeout: TimeInterval = RemoteProviderTranscript.defaultTimeout) {
        self.init(runner: SSHRunner(host: host, runner: runner, timeout: timeout,
                                    connection: connection))
    }

    /// Provider session ids name a file; the vocabulary is restricted for the same
    /// reason it is locally, and checked *before* anything is sent to a shell.
    public static func isValidSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200
            && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    public func resolve(_ request: RemoteTranscriptRequest)
        async -> WorkerRuntimeContext.ProviderTranscriptResolution {
        guard Self.isValidSessionID(request.sessionID) else {
            return .unavailable(reason: "provider_session_invalid")
        }
        guard request.remoteCwd.hasPrefix("/") else {
            return .unavailable(reason: "remote_working_directory_unavailable")
        }
        let maximum = max(1, request.maximumBytes)
        let script = Self.script(remoteCwd: request.remoteCwd, sessionID: request.sessionID,
                                 maximumBytes: maximum)
        let outcome = await runner.run(SSHRunner.commandLine(["sh", "-c", script]))
        switch outcome {
        case .unverifiable:
            return .unavailable(reason: "remote_provider_transcript_unverifiable")
        case .answered(let code, let stdout, _):
            guard code == 0 else {
                return .unavailable(reason: "remote_provider_transcript_unverifiable")
            }
            return Self.parse(stdout, maximumBytes: maximum)
        }
    }

    /// The far-side script. POSIX `sh`, one ASCII header line, then base64.
    ///
    /// `cd … && pwd -P` rather than the recorded path verbatim: the provider encodes
    /// the *resolved* directory into its project folder name, and on the host we
    /// verified against, `/tmp` resolves to `/private/tmp`. Encoding the unresolved
    /// path would have looked for a directory that never exists.
    static func script(remoteCwd: String, sessionID: String, maximumBytes: Int) -> String {
        let cwd = SSHCommand.shellQuote(remoteCwd)
        let session = SSHCommand.shellQuote(sessionID)
        return """
        c=\(cwd)
        s=\(session)
        d=`cd "$c" 2>/dev/null && pwd -P`
        if [ -z "$d" ]; then printf 'ORCHARD-TX/1 no-cwd\\n'; exit 0; fi
        e=`printf '%s' "$d" | tr '/' '-'`
        f="$HOME/.claude/projects/$e/$s.jsonl"
        if [ ! -r "$f" ]; then
          set -- "$HOME/.claude/projects"/*/"$s.jsonl"
          if [ "$#" -eq 1 ] && [ -r "$1" ]; then f="$1"
          elif [ "$#" -gt 1 ]; then printf 'ORCHARD-TX/1 ambiguous\\n'; exit 0
          else printf 'ORCHARD-TX/1 not-found\\n'; exit 0; fi
        fi
        z=`wc -c < "$f" 2>/dev/null | tr -d ' '`
        if command -v base64 >/dev/null 2>&1; then
          printf 'ORCHARD-TX/1 ok %s %s\\n' "$z" "$f"
          tail -c \(maximumBytes) "$f" | base64
        elif command -v openssl >/dev/null 2>&1; then
          printf 'ORCHARD-TX/1 ok %s %s\\n' "$z" "$f"
          tail -c \(maximumBytes) "$f" | openssl base64
        else
          printf 'ORCHARD-TX/1 no-encoder\\n'
        fi
        """
    }

    /// Read the header, then the body. Every failure is a *named* reason — the caller
    /// stores it as the pin's `unavailableReason`, and a coordinator reading one has to
    /// be able to tell "the host did not answer" from "the agent never had a session".
    static func parse(_ stdout: String, maximumBytes: Int)
        -> WorkerRuntimeContext.ProviderTranscriptResolution {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("ORCHARD-TX/1") }) else {
            return .unavailable(reason: "remote_provider_transcript_unverifiable")
        }
        let header = String(lines[headerIndex])
        let fields = header.split(separator: " ", maxSplits: 3).map(String.init)
        guard fields.count >= 2 else {
            return .unavailable(reason: "remote_provider_transcript_unverifiable")
        }
        switch fields[1] {
        case "no-cwd":
            return .unavailable(reason: "remote_working_directory_unavailable")
        case "not-found":
            return .unavailable(reason: "provider_transcript_not_found")
        case "ambiguous":
            // Two project folders hold a file with this session id. Picking one would
            // be a coin flip presented as evidence.
            return .unavailable(reason: "provider_transcript_ambiguous")
        case "no-encoder":
            return .unavailable(reason: "remote_provider_transcript_unsupported")
        case "ok":
            break
        default:
            return .unavailable(reason: "remote_provider_transcript_unverifiable")
        }
        guard fields.count >= 4, let totalBytes = Int(fields[2]) else {
            return .unavailable(reason: "remote_provider_transcript_unverifiable")
        }
        let path = fields[3]
        let body = lines[lines.index(after: headerIndex)...].joined()
        guard let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters),
              !data.isEmpty else {
            return .unavailable(reason: "provider_transcript_not_found")
        }
        let truncated = totalBytes > maximumBytes
        var bounded = data
        // Same trim as the local resolver: a byte-bounded tail starts mid-record, and a
        // half line at the top of a JSONL pin is not a smaller transcript, it is a
        // corrupt one.
        if truncated, let newline = bounded.firstIndex(of: 0x0A),
           newline < bounded.index(before: bounded.endIndex) {
            bounded.removeSubrange(bounded.startIndex...newline)
        }
        guard let content = String(data: bounded, encoding: .utf8) else {
            return .unavailable(reason: "provider_transcript_invalid_utf8")
        }
        return .resolved(content: content, path: path, truncated: truncated)
    }
}
