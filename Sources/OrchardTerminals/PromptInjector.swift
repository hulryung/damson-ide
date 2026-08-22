import Foundation
import OrchardCore

/// Tuning for the verified prompt-injection pipeline. Production defaults match Orca's
/// measured values; tests shrink them so the pipeline runs in milliseconds.
public struct SendPipelineConfig: Sendable {
    /// Bytes per chunked write (the writer yields between chunks so the parser and
    /// renderer keep up with a large preamble).
    public var chunkSize = 512
    /// Delay between the last text chunk and the submitting CR. A TUI needs a beat to
    /// ingest the paste into its input box before Enter means "submit" — an immediate
    /// CR can land while the paste is still being consumed and submit half a prompt.
    public var submitDelay: TimeInterval = 0.5
    /// How long to poll for evidence the agent actually took the submission.
    public var verifyTimeout: TimeInterval = 5.0
    public var verifyPollInterval: TimeInterval = 0.05

    public init() {}
}

/// The exact prompt-delivery trick (orca-inventory §3), as a pure pipeline over a
/// `TerminalSession`:
///   1. ESC-sanitize — a raw `\e` in the prompt would be parsed as the start of a
///      control sequence by the agent's TUI and corrupt everything after it.
///   2. Bracketed-paste framing, so embedded newlines don't each submit a partial line.
///   3. Chunked writes, yielding between chunks; the closing `\x1b[201~` is emitted
///      even if a chunk write path bails, so the TUI is never left inside a paste.
///   4. Submit `\r` after a settle delay.
///   5. Verify: poll the fused readiness state until the agent *leaves idle* — there is
///      no delivery acknowledgment protocol for typed prompts, so the state machine
///      advancing is the only proof the submission took.
@MainActor
enum PromptInjector {
    /// Replace every raw ESC with the literal text `<ESC>`.
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}", with: "<ESC>")
    }

    /// Type `text` into the session (no submit). Returns bytes written.
    @discardableResult
    static func type(_ text: String, into session: TerminalSession,
                     chunkSize: Int) async -> Int {
        let framed = session.bracketedPasteEnabled
        var written = 0
        if framed {
            session.write(Data([0x1B] + Array("[200~".utf8)))
        }
        defer {
            // Always close the paste frame — a TUI stuck inside an open paste treats
            // every later keystroke (including the submit CR) as pasted text.
            if framed {
                session.write(Data([0x1B] + Array("[201~".utf8)))
            }
        }
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + max(1, chunkSize), bytes.count)
            session.write(Data(bytes[index..<end]))
            written += end - index
            index = end
            await Task.yield()
        }
        return written
    }

    /// Submit with `\r` after the settle delay, then verify the agent left idle within
    /// the timeout. `state` reads the fused readiness verdict (the ReadinessDetector
    /// output, hooks-first). Only call when the agent was idle at submission time —
    /// "left idle" is meaningless otherwise.
    static func submitAndVerify(session: TerminalSession, handle: String,
                                config: SendPipelineConfig,
                                state: @MainActor () -> AgentRuntimeState) async throws {
        try? await Task.sleep(nanoseconds: UInt64(config.submitDelay * 1_000_000_000))
        session.write(Data([0x0D]))

        let deadline = Date().addingTimeInterval(config.verifyTimeout)
        while Date() < deadline {
            if session.processExited {
                throw TerminalServiceError.exited(handle: handle)
            }
            switch state() {
            case .idle:
                break   // not advanced yet — keep polling
            case .awaitingApproval:
                // The submission ran straight into a permission gate; it is parked
                // behind a human decision, not delivered.
                throw TerminalServiceError.promptBlocked(handle: handle)
            default:
                return  // left idle — the working sequence advanced; delivered.
            }
            try? await Task.sleep(nanoseconds: UInt64(config.verifyPollInterval * 1_000_000_000))
        }
        throw TerminalServiceError.promptStalled(handle: handle)
    }
}
